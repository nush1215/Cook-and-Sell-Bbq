-- Services
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local Colors = require(Shared.Colors)
local Products = require(Shared.Config.Products)
local Gamepasses = require(Shared.Config.Gamepasses)
local Ingredients = require(Shared.Config.Ingredients)
local Sticks = require(Shared.Config.Sticks)
local StarterPack = require(Shared.Config.StarterPack)
local BuxPacks = require(Shared.Config.BuxPacks)

--
local PlayerDataManager
local NotificationManager
local CurrencyManager
local IngredientManager
local StickManager

--
local ShopManager = {
	RequestProductPurchase = Network.Event("RequestProductPurchase"),
	RequestGamepassPurchase = Network.Event("RequestGamepassPurchase"),

	PlayerPurchased = Signal.new(),

	-- (buyer, itemId, robuxAmount) once a Robux purchase has cleared, whoever it was granted to.
	OnRobuxPurchase = Signal.new(),
	-- (player, itemId, itemType, isGift) when a purchase prompt is opened. itemType is "Product" or "Gamepass".
	OnPurchasePromptShown = Signal.new(),
	-- (player, productId) when a product prompt is closed without buying.
	OnPurchaseCancelled = Signal.new(),
	-- (buyer, itemId, itemType) when a gift lands on someone other than the buyer.
	OnGiftDelivered = Signal.new(),
	-- (player, shortfall) when a short-on-currency player is steered to a currency product.
	OnCurrencyUpsellShown = Signal.new(),

	_toGiftPlayer = {},
}

--
local MAX_GAMEPASS_VERIFY_RETRIES = 3
local GAMEPASS_VERIFY_RETRY_DELAY = 0.5
local MAX_PURCHASE_LOGS = 100

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

local function setupGiftTracking(player: Player, itemId: string, recipient: Player?)
	if not recipient then
		return
	end

	if not ShopManager._toGiftPlayer[player] then
		ShopManager._toGiftPlayer[player] = {}
	end

	ShopManager._toGiftPlayer[player][itemId] = recipient
end

local function clearGiftTracking(player: Player, itemId: string?)
	if not ShopManager._toGiftPlayer[player] then
		return
	end

	if itemId then
		ShopManager._toGiftPlayer[player][itemId] = nil
	else
		ShopManager._toGiftPlayer[player] = nil
	end
end

local function insertPurchaseLog(player: Player, logData: { [string]: any })
	PlayerDataManager:InsertCappedPlayerDataKey(player, "PurchaseLogs", logData, MAX_PURCHASE_LOGS)
end

local function checkOwnsGamepass(player: Player, gamepassData: Gamepasses.Gamepass): (boolean, boolean)
	local success, playerOwns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamepassData.PassId)
	end)

	return success, playerOwns == true
end

local function applyGamepass(player: Player, gamepassData: Gamepasses.Gamepass, runPurchaseCallback: boolean)
	player:AddTag(gamepassData.Id)

	if runPurchaseCallback and gamepassData.OnPurchaseCallback then
		task.spawn(function()
			pcall(gamepassData.OnPurchaseCallback, player)
		end)
	end

	if gamepassData.OnInitializeCallback then
		task.spawn(function()
			pcall(gamepassData.OnInitializeCallback, player)
		end)
	end
end

-- Resolves who should receive a gift gamepass. Falls back to the buyer if the
-- intended recipient cannot receive it (no data, already gifted, or already owns).
-- Returns the target player along with their data, and whether a gift was
-- actually delivered to a different player.
local function resolveGiftGamepassTarget(
	buyer: Player,
	intendedRecipient: Player?,
	gamepassData: Gamepasses.Gamepass
): (Player, any, boolean)
	local isGiftAttempt = intendedRecipient ~= nil and intendedRecipient ~= buyer and validatePlayer(intendedRecipient)

	if isGiftAttempt then
		local hasData, recipientData = PlayerDataManager:GetPlayerData(intendedRecipient):await()
		if hasData then
			local alreadyGifted = table.find(recipientData.GiftedGamepasses, gamepassData.Id) ~= nil
			local ownsSuccess, ownsGamepass = checkOwnsGamepass(intendedRecipient, gamepassData)
			local recipientCanReceive = not alreadyGifted and not (ownsSuccess and ownsGamepass)

			if recipientCanReceive then
				return intendedRecipient :: Player, recipientData, true
			end
		end
	end

	local hasData, buyerData = PlayerDataManager:GetPlayerData(buyer):await()
	if not hasData then
		return buyer, nil, false
	end

	return buyer, buyerData, false
end

-- Adds the gamepass to the target's GiftedGamepasses list (if not already there)
-- and applies the gamepass tag/callbacks. Returns true if a new gift entry was inserted.
local function grantGiftedGamepass(target: Player, targetData: any, gamepassData: Gamepasses.Gamepass): boolean
	local alreadyGifted = table.find(targetData.GiftedGamepasses, gamepassData.Id) ~= nil

	if not alreadyGifted then
		PlayerDataManager:InsertPlayerDataKey(target, "GiftedGamepasses", gamepassData.Id)
	end

	applyGamepass(target, gamepassData, not alreadyGifted)
	return not alreadyGifted
end

local function notifyGiftedGamepassDelivered(buyer: Player, recipient: Player, gamepassData: Gamepasses.Gamepass)
	NotificationManager:NotifyNormal(buyer, {
		Text = `Successfully Gifted <font color="#ffd400">{gamepassData.Name}</font> to <font color="#ffd400">{recipient.Name}</font>!`,
		Sound = "RobuxPurchase",
	})

	NotificationManager:NotifyNormal(recipient, {
		Text = `<font color="#ffd400">{buyer.Name}</font> has Gifted you <font color="#ff7272">{gamepassData.Name}</font>!`,
	})
end

local function notifyGamepassSelfPurchase(buyer: Player, gamepassData: Gamepasses.Gamepass, wasGiftFallback: boolean)
	local message = if wasGiftFallback
		then `Gift could not be delivered, so <font color="#ffd400">{gamepassData.Name}</font> was added to your account.`
		else `Successfully purchased <font color="#ffd400">{gamepassData.Name}</font>`

	NotificationManager:NotifyNormal(buyer, {
		Text = message,
		Sound = "RobuxPurchase",
	})
end

local function notifyGiftedProductDelivered(buyer: Player, recipient: Player, productData: Products.Product)
	NotificationManager:NotifyNormal(buyer, {
		Text = `Successfully gifted <font color="#ffd400">{productData.Name}</font> to <font color="#ffd400">{recipient.Name}</font>!`,
		Sound = "RobuxPurchase",
	})

	NotificationManager:NotifyNormal(recipient, {
		Text = `<font color="#ffd400">{buyer.Name}</font> has gifted you <font color="#ff7272">{productData.Name}</font>!`,
	})
end

local function notifyProductSelfPurchase(buyer: Player, productData: Products.Product, wasGiftFallback: boolean)
	local message = if wasGiftFallback
		then `Gift could not be delivered, so <font color="#ffd400">{productData.Name}</font> was added to your account.`
		else `Successfully Purchased <font color="#ffd400">{productData.Name}</font>`

	NotificationManager:NotifyNormal(buyer, {
		Text = message,
		Sound = "RobuxPurchase",
	})
end

-- Attempts to prompt a product purchase for the player
-- @param player The player attempting the purchase
-- @param id The product ID
-- @param toGift Optional player to gift the product to
function ShopManager:AttemptProductPurchase(player: Player, id: string, toGift: Player?)
	if not validatePlayer(player) then
		warn(`Cannot attempt product purchase for invalid player: {player}`)
		return
	end

	local productData = Products.GetProductFromId(id)
	if not productData then
		warn(`Product with ID '{id}' not found`)
		return
	end

	local isGift = toGift ~= nil and toGift ~= player
	if isGift and not validatePlayer(toGift) then
		warn(`Cannot gift product '{id}' to invalid player`)
		return
	end

	-- When gifting, validate against the recipient's data so a buyer who already
	-- owns a PurchaseOnce product can still gift it, and so we don't charge them
	-- when the recipient already owns it.
	local ownerToCheck = if isGift then toGift :: Player else player

	PlayerDataManager:GetPlayerData(ownerToCheck)
		:andThen(function(ownerData)
			if productData.PurchaseOnce and table.find(ownerData.PurchasedOnceProducts or {}, id) then
				local message = if isGift
					then `<font color="#ffd400">{(toGift :: Player).Name}</font> already has <font color="#ffd400">{productData.Name}</font>!`
					else `You have already purchased <font color="#ffd400">{productData.Name}</font>!`

				NotificationManager:NotifyNormal(player, { Text = message })
				return
			end

			if isGift then
				setupGiftTracking(player, id, toGift)
			end

			if productData.ProductId then
				MarketplaceService:PromptProductPurchase(player, productData.ProductId)
				self.OnPurchasePromptShown:Fire(player, id, "Product", isGift)
			end
		end)
		:catch(function(error)
			warn(`Failed to attempt product purchase for {player.Name}: {error}`)
		end)
end

-- Attempts to prompt a gamepass purchase for the player
-- @param player The player attempting the purchase
-- @param id The gamepass ID
-- @param toGift Optional player to gift the gamepass to
function ShopManager:AttemptGamepassPurchase(player: Player, id: string, toGift: Player?)
	if not validatePlayer(player) then
		warn(`Cannot attempt gamepass purchase for invalid player: {player}`)
		return
	end

	local gamepassData = Gamepasses.GetGamepassFromId(id)
	if not gamepassData then
		warn(`Gamepass with ID '{id}' not found`)
		return
	end

	if not toGift or toGift == player then
		MarketplaceService:PromptGamePassPurchase(player, gamepassData.PassId)
		self.OnPurchasePromptShown:Fire(player, id, "Gamepass", false)
		return
	end

	if not validatePlayer(toGift) then
		warn(`Cannot gift gamepass '{id}' to invalid player`)
		return
	end

	if not gamepassData.GiftProductId then
		warn(`Gamepass with ID '{id}' does not have a GiftProductId`)
		return
	end

	task.spawn(function()
		local hasData, recipientData = PlayerDataManager:GetPlayerData(toGift):await()
		if not hasData then
			warn(`Failed to get data before gifting gamepass '{id}' to {toGift.Name}`)
			return
		end

		if table.find(recipientData.GiftedGamepasses, id) then
			NotificationManager:NotifyNormal(player, {
				Text = `<font color="#ffd400">{toGift.Name}</font> already has <font color="#ffd400">{gamepassData.Name}</font>!`,
			})
			return
		end

		local ownsSuccess, ownsGamepass = checkOwnsGamepass(toGift, gamepassData)
		if not ownsSuccess then
			warn(`Failed to verify gamepass '{id}' ownership for {toGift.Name}`)
			return
		end

		if ownsGamepass then
			NotificationManager:NotifyNormal(player, {
				Text = `<font color="#ffd400">{toGift.Name}</font> already owns <font color="#ffd400">{gamepassData.Name}</font>!`,
			})
			return
		end

		if not validatePlayer(player) or not validatePlayer(toGift) then
			return
		end

		setupGiftTracking(player, id, toGift)
		MarketplaceService:PromptProductPurchase(player, gamepassData.GiftProductId)
		self.OnPurchasePromptShown:Fire(player, id, "Gamepass", true)
	end)
end

-- Hands over everything in the starter pack and says what was in it in one line, the way opening a
-- crate does -- the receipt's own "Successfully Purchased" toast names the pack but not its contents.
-- Called from the pack product's callback, so it runs against whoever the purchase resolved to, which
-- is the recipient when it was a gift.
-- @param player The player to give the pack to
function ShopManager:GrantStarterPack(player: Player)
	local names = {}

	for _, entry in StarterPack.Contents do
		if entry.Type == "Stick" then
			local stick = Sticks.GetStickFromId(entry.Id)
			StickManager:GrantStick(player, entry.Id, entry.Amount)
			table.insert(names, GuiUtil.Colorize(`x{entry.Amount} {stick.Name} Stick`, stick.TextColor))
		else
			local ingredient = Ingredients.GetIngredientFromId(entry.Id)
			IngredientManager:GrantIngredient(player, entry.Id, entry.Amount)
			table.insert(names, GuiUtil.Colorize(`x{entry.Amount} {ingredient.Name}`, ingredient.Color))
		end
	end

	NotificationManager:NotifyNormal(player, {
		Text = `Your <font color="#ffd400">{StarterPack.Name}</font> had {table.concat(names, ", ")}`,
		Duration = 5,
		Sound = "CollectedReward",
		Effect = "Success",
	})
end

-- Hands over a Bux pack's Bux and counts them up in a toast, since the receipt's own "Successfully
-- Purchased" line names the pack but never says how much it was worth. Called from the pack product's
-- callback, so it runs against whoever the purchase resolved to, which is the recipient when gifted.
--
-- Boosts are deliberately skipped: the card advertises a fixed number and that's what has to land, or
-- an x2 Bux owner would quietly get double what they paid for.
-- @param player The player to give the Bux to
-- @param packId The pack that was bought
function ShopManager:GrantBuxPack(player: Player, packId: string)
	local pack = BuxPacks.GetBuxPackFromId(packId)

	CurrencyManager:IncrementCurrency(player, pack.Amount, "BuxPack", true)

	-- {value} is NotificationManager's own placeholder for the Count below, so it has to reach the
	-- client as-is rather than being interpolated here -- which is why this isn't an interpolated string.
	NotificationManager:NotifyNormal(player, {
		Text = "You received {value} Bux",
		Duration = 5,
		Sound = "CollectedReward",
		Effect = "Success",
		Count = {
			Value = pack.Amount,
			Format = "Price",
			Color = Colors.Currency,
		},
	})
end

-- Prompts a currency purchase to the player for the amount needed
-- @param player The player to prompt
-- @param currencyNeeded The amount of currency needed
function ShopManager:PromptCurrencyPurchase(player: Player, currencyNeeded: number)
	if not validatePlayer(player) then
		warn(`Cannot prompt currency purchase for invalid player: {player}`)
		return
	end

	if currencyNeeded <= 0 then
		warn(`Invalid currency amount: {currencyNeeded}`)
		return
	end

	local currencyProducts = Products.GetProductsByType("Currency")
	table.sort(currencyProducts, function(a, b)
		return (a.Value or 0) < (b.Value or 0)
	end)

	self.OnCurrencyUpsellShown:Fire(player, currencyNeeded)

	for _, product in currencyProducts do
		if product.Value and product.Value >= currencyNeeded then
			self:AttemptProductPurchase(player, product.Id)
			return
		end
	end

	if #currencyProducts > 0 then
		local largestProduct = currencyProducts[#currencyProducts]
		self:AttemptProductPurchase(player, largestProduct.Id)
	else
		warn(`No currency products available for {player.Name}`)
	end
end

-- Handles gamepass purchase completion
-- @param player The player who purchased
-- @param gamepassId The gamepass ID from Roblox
-- @param isPurchased Whether the purchase was successful
function ShopManager:_onPurchaseGamepass(player: Player, gamepassId: number, isPurchased: boolean)
	if not isPurchased then
		return
	end

	if not validatePlayer(player) then
		return
	end

	local gamepassData = Gamepasses.GetGamepassFromPassId(gamepassId)
	if not gamepassData then
		warn(`Gamepass with PassId '{gamepassId}' not found`)
		return
	end

	applyGamepass(player, gamepassData, true)
	self.PlayerPurchased:Fire(player, gamepassData.Id)

	-- A gamepass prompt carries no receipt, so the price is looked up rather than read off one.
	task.spawn(function()
		local success, info = pcall(function()
			return MarketplaceService:GetProductInfo(gamepassData.PassId, Enum.InfoType.GamePass)
		end)
		self.OnRobuxPurchase:Fire(player, gamepassData.Id, (success and info and info.PriceInRobux) or 0)
	end)

	NotificationManager:NotifyNormal(player, {
		Text = `Successfully Purchased <font color="#ffd400">{gamepassData.Name}</font>`,
		Sound = "RobuxPurchase",
	})
end

-- Handles a receipt for a gamepass that was purchased via its gift product.
function ShopManager:_processGiftGamepassPurchase(
	receiptInfo: any,
	buyer: Player,
	gamepassData: Gamepasses.Gamepass
): Enum.ProductPurchaseDecision
	local intendedRecipient = self._toGiftPlayer[buyer] and self._toGiftPlayer[buyer][gamepassData.Id]
	local attemptedGift = intendedRecipient ~= nil and intendedRecipient ~= buyer

	local target, targetData, didGift = resolveGiftGamepassTarget(buyer, intendedRecipient, gamepassData)

	if not targetData then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	clearGiftTracking(buyer, gamepassData.Id)
	grantGiftedGamepass(target, targetData, gamepassData)

	local purchaseLog: { [string]: any } = {
		Time = os.time(),
		ProductName = gamepassData.Name,
		Id = receiptInfo.ProductId,
		GamepassId = gamepassData.Id,
		IsGamepassGift = true,
	}

	if didGift then
		purchaseLog.IsFromGift = true
		purchaseLog.FromPlayerUserId = buyer.UserId
	elseif attemptedGift then
		purchaseLog.IsGiftFallback = true
	end

	insertPurchaseLog(target, purchaseLog)
	self.PlayerPurchased:Fire(target, gamepassData.Id)
	self.OnRobuxPurchase:Fire(buyer, gamepassData.Id, receiptInfo.CurrencySpent or 0)

	if didGift then
		notifyGiftedGamepassDelivered(buyer, target, gamepassData)
		self.OnGiftDelivered:Fire(buyer, gamepassData.Id, "Gamepass")
	else
		notifyGamepassSelfPurchase(buyer, gamepassData, attemptedGift)
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Handles a receipt for a regular (non-gamepass) product purchase, including
-- product gifting where the recipient receives the product instead of the buyer.
function ShopManager:_processProductPurchase(
	receiptInfo: any,
	buyer: Player,
	productData: Products.Product
): Enum.ProductPurchaseDecision
	local intendedRecipient = self._toGiftPlayer[buyer] and self._toGiftPlayer[buyer][productData.Id]
	local attemptedGift = intendedRecipient ~= nil and intendedRecipient ~= buyer
	local isGift = attemptedGift and validatePlayer(intendedRecipient)

	if intendedRecipient then
		clearGiftTracking(buyer, productData.Id)
	end

	local target = if isGift then intendedRecipient :: Player else buyer

	if isGift then
		notifyGiftedProductDelivered(buyer, target, productData)
		self.OnGiftDelivered:Fire(buyer, productData.Id, "Product")
	else
		notifyProductSelfPurchase(buyer, productData, attemptedGift)
	end

	local purchaseLog: { [string]: any } = {
		Time = os.time(),
		ProductName = productData.Name,
		Id = receiptInfo.ProductId,
	}

	if isGift then
		purchaseLog.IsFromGift = true
		purchaseLog.FromPlayerUserId = buyer.UserId
	elseif attemptedGift then
		purchaseLog.IsGiftFallback = true
	end

	insertPurchaseLog(target, purchaseLog)

	if productData.Callback then
		task.spawn(function()
			pcall(productData.Callback, target, intendedRecipient)
		end)
	end

	if productData.PurchaseOnce then
		PlayerDataManager:InsertPlayerDataKey(target, "PurchasedOnceProducts", productData.Id)
		target:AddTag(productData.Id)
	end

	self.PlayerPurchased:Fire(target, productData.Id)
	self.OnRobuxPurchase:Fire(buyer, productData.Id, receiptInfo.CurrencySpent or 0)

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Processes a product receipt from Roblox by dispatching to the appropriate handler
-- based on whether the ProductId belongs to a regular product or a gift-gamepass product.
-- @param receiptInfo The receipt information from Roblox
-- @returns ProductPurchaseDecision
function ShopManager:_processReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player or not validatePlayer(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local productData = Products.GetProductFromProductId(receiptInfo.ProductId)
	if productData then
		return self:_processProductPurchase(receiptInfo, player, productData)
	end

	local giftGamepassData = Gamepasses.GetGamepassFromGiftProductId(receiptInfo.ProductId)
	if giftGamepassData then
		return self:_processGiftGamepassPurchase(receiptInfo, player, giftGamepassData)
	end

	warn(`Product with ProductId '{receiptInfo.ProductId}' not found`)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

-- Verifies and initializes gamepasses for a player
-- @param player The player to verify gamepasses for
function ShopManager:_verifyGamepasses(player: Player)
	if not validatePlayer(player) then
		return
	end

	local allGamepasses = Gamepasses.GetAllGamepasses()

	local function verifyOwns(gamepassData: any, retryCount: number)
		if retryCount > MAX_GAMEPASS_VERIFY_RETRIES then
			warn(
				`Failed to verify gamepass '{gamepassData.Id}' for {player.Name} after {MAX_GAMEPASS_VERIFY_RETRIES} retries`
			)
			return
		end

		if not validatePlayer(player) then
			return
		end

		local success, playerOwns = checkOwnsGamepass(player, gamepassData)
		if not success then
			task.wait(GAMEPASS_VERIFY_RETRY_DELAY)
			return verifyOwns(gamepassData, retryCount + 1)
		end

		if playerOwns then
			applyGamepass(player, gamepassData, false)
		end
	end

	PlayerDataManager:GetPlayerData(player)
		:andThen(function(playerData)
			for _, gamepassData in allGamepasses do
				if table.find(playerData.GiftedGamepasses, gamepassData.Id) then
					applyGamepass(player, gamepassData, false)
				else
					task.spawn(verifyOwns, gamepassData, 0)
				end
			end
		end)
		:catch(function(error)
			warn(`Failed to verify gamepasses for {player.Name}: {error}`)
		end)
end

-- Verifies and applies purchase-once products for a player
-- @param player The player to verify products for
function ShopManager:_verifyPurchaseOnes(player: Player)
	if not validatePlayer(player) then
		return
	end

	PlayerDataManager:GetPlayerDataKey(player, "PurchasedOnceProducts")
		:andThen(function(purchased: { string })
			if not purchased then
				return
			end

			for _, tag in purchased do
				player:AddTag(tag)
			end
		end)
		:catch(function(error)
			warn(`Failed to verify purchase-once products for {player.Name}: {error}`)
		end)
end

-- Initializes the ShopManager
-- Sets up dependencies, event connections, and verifies existing players
function ShopManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	NotificationManager = require(script.Parent.NotificationManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	IngredientManager = require(script.Parent.IngredientManager)
	StickManager = require(script.Parent.StickManager)

	-- Stamps when this player's starter pack offer runs out, once, on their first join. An absolute
	-- time rather than a countdown, so it keeps running while they're offline and rejoining can't
	-- reset it -- and it's what the shop card's countdown reads.
	local function setupStarterPackStart(player: Player)
		PlayerDataManager:GetPlayerDataKey(player, "StarterPackStart"):andThen(function(starterPackStart: number)
			if starterPackStart > 0 then
				return
			end

			PlayerDataManager:SetPlayerDataKey(player, "StarterPackStart", os.time() + StarterPack.DURATION)
		end)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		self:_verifyGamepasses(player)
		self:_verifyPurchaseOnes(player)
		setupStarterPackStart(player)
	end)

	for _, player in Players:GetPlayers() do
		self:_verifyGamepasses(player)
		self:_verifyPurchaseOnes(player)
		setupStarterPackStart(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		clearGiftTracking(player)
	end)

	MarketplaceService.ProcessReceipt = function(...)
		return self:_processReceipt(...)
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(...)
		self:_onPurchaseGamepass(...)
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(playerOrUserId: any, productId: number, wasPurchased: boolean)
			if wasPurchased then
				return
			end

			local promptPlayer = if typeof(playerOrUserId) == "number"
				then Players:GetPlayerByUserId(playerOrUserId)
				else playerOrUserId
			if not validatePlayer(promptPlayer) then
				return
			end

			clearGiftTracking(promptPlayer)

			-- The Roblox id is resolved back to our own so the cancel lines up with the prompt that opened it.
			-- A gift-gamepass prompt is a product prompt too, so it's checked second.
			local productData = Products.GetProductFromProductId(productId)
			local gamepassData = if productData then nil else Gamepasses.GetGamepassFromGiftProductId(productId)
			local itemId = if productData then productData.Id elseif gamepassData then gamepassData.Id else nil
			if itemId then
				self.OnPurchaseCancelled:Fire(promptPlayer, itemId)
			end
		end
	)

	self.RequestProductPurchase:OnServerEvent(function(player: Player, data: { any })
		if not validatePlayer(player) then
			return
		end
		self:AttemptProductPurchase(player, table.unpack(data))
	end)

	self.RequestGamepassPurchase:OnServerEvent(function(player: Player, data: { any })
		if not validatePlayer(player) then
			return
		end
		self:AttemptGamepassPurchase(player, table.unpack(data))
	end)
end

function ShopManager:OnStart() end

return ShopManager
