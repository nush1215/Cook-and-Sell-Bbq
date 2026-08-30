-- Services
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local Colors = require(Shared.Colors)
local Products = require(Shared.Config.Products)
local Gamepasses = require(Shared.Config.Gamepasses)
local Ingredients = require(Shared.Config.Ingredients)
local Sticks = require(Shared.Config.Sticks)
local Crates = require(Shared.Config.Crates)
local StarterPackConfig = require(Shared.Config.StarterPack)
local BuxPacks = require(Shared.Config.BuxPacks)

-- Controllers
local PlayerDataController
local SelectPlayerController
local PolicyController
local ConfettiController
local SoundController
local UIController
local HudController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- How dark the world behind the shop goes, and how long it takes to get there.
local DIM_TRANSPARENCY = 0.2
local DIM_TWEEN = TweenInfo.new(0.2)

-- How long the shop takes to scroll down to the Bux packs when the currency button opens it.
local BUX_SCROLL_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Sine)

--
local ShopController = {
	--
	RequestProductPurchase = Network.Event("RequestProductPurchase"),
	RequestGamepassPurchase = Network.Event("RequestGamepassPurchase"),

	--
	Prices = {},

	-- Every frame that buys something. Each is named for what it buys and holds a Purchase button, which
	-- is all the price pass needs.
	_purchaseFrames = {},

	-- Whether the open purchase prompt is a gift. Roblox shows one at a time, so a flag covers it; read
	-- and cleared by _setupBuxPurchaseCelebration.
	_promptedGift = false,
}

-- Requests a product purchase from an id
function ShopController:PromptProductPurchaseFromId(id: string, toGift: Player?): (boolean, { any })
	--
	local productInfo = Products.GetProductFromId(id)
	if not productInfo then
		warn(`Product data for id {id} not found.`)
		return
	end

	--
	self._promptedGift = toGift ~= nil
	self.RequestProductPurchase:FireServer({ id, toGift })
	return true, productInfo
end

-- Requests a gamepass purchase from an id
function ShopController:PromptGamepassPurchaseFromId(id: string, toGift: Player?): (boolean, { any })
	--
	local gamepassInfo = Gamepasses.GetGamepassFromId(id)
	if not gamepassInfo then
		warn(`Gamepass data for id {id} not found.`)
		return
	end

	--
	self.RequestGamepassPurchase:FireServer({ id, toGift })
	return true, gamepassInfo
end

-- Gets the product or gamepass data from an id
function ShopController:GetProductFromId(id: string): Gamepasses.Gamepass | Products.Product
	return Products.GetProductFromId(id) or Gamepasses.GetGamepassFromId(id)
end

-- The already-looked-up Robux price, or nil. Never yields, unlike GetPrice, so it's what a button refresh
-- should read -- warm the cache by calling GetPrice from a spawned thread first.
function ShopController:GetCachedPrice(id: string): number?
	return self.Prices[id]
end

-- Gets the price of a product or gamepass. Yields on the first lookup for an id, then reads the cache.
function ShopController:GetPrice(id: string)
	--
	local data = Products.GetProductFromId(id) or Gamepasses.GetGamepassFromId(id)
	if not data then
		return "-"
	end
	local isGamepass = if Products.GetProductFromId(id) then false else true

	--
	if data.CurrencyPrice then
		return data.CurrencyPrice
	end

	--
	if self.Prices[data.Id] then
		return self.Prices[data.Id]
	end

	--
	local success, productInfo = pcall(function()
		return MarketplaceService:GetProductInfo(
			isGamepass and data.PassId or data.ProductId,
			isGamepass and Enum.InfoType.GamePass or Enum.InfoType.Product
		)
	end)

	if not success or not productInfo or productInfo.PriceInRobux == nil then
		return "-"
	end

	local price = productInfo.PriceInRobux
	self.Prices[data.Id] = price

	return price
end

--[[
	What one sellable thing looks like on a shop card. Crates and the starter pack draw from the same two
	rosters, which spell the same facts differently, so the branch lives here rather than per card.

	Two colours, matching the stick shop: Color is the thing itself (a copper stick's orange) and backs
	the icon's rays, while TextColor/StrokeColor are its rarity and are what the odds take.
	@param item Anything carrying an Id and the Type saying which roster it's from
	@return Its display fields, or nil if the config no longer has it
]]
local function resolveRewardDisplay(item: { Id: string, Type: Crates.RewardType })
	if item.Type == "Ingredient" then
		local ingredient = Ingredients.GetIngredientFromId(item.Id)
		if not ingredient then
			return nil
		end

		return {
			Name = ingredient.Name,
			Icon = ingredient.Icon,
			Price = ingredient.Price,
			Color = ingredient.Color,
			TextColor = ingredient.Tier.TextColor,
			StrokeColor = ingredient.Tier.StrokeColor,
		}
	end

	local stick = Sticks.GetStickFromId(item.Id)
	if not stick then
		return nil
	end

	return {
		Name = `{stick.Name} Stick`,
		Icon = stick.Icon,
		Price = stick.Price,
		Color = stick.TextColor,
		TextColor = Colors[stick.Rarity].TextColor,
		StrokeColor = Colors[stick.Rarity].StrokeColor,
	}
end

-- Fills one crate's card: the contents preview and the bundle buttons. Preview slots are authored one per
-- reward and numbered in config order, so the rarest entries land on the slots that get extra treatment.
-- @param crate The crate this card sells
-- @param card The card frame, found by the crate's own Id
function ShopController:_setupCrateCard(crate: Crates.Crate, card: Frame)
	local slotIndex = 0

	for _, group in crate.Contents do
		for _, reward in group.Rewards do
			slotIndex += 1

			-- Too few authored slots just shows the first few, rather than erroring partway through and
			-- leaving the rest of the shop unbuilt.
			local slot = card.Container:FindFirstChild(tostring(slotIndex))
			local display = slot and resolveRewardDisplay(reward)
			if not display then
				continue
			end

			slot.Icon.Image = display.Icon
			slot.IngredientName.Text = display.Name
			slot.Value.Text = `${GuiUtil.ConvertNumberWithSuffix(display.Price)}`
			slot.Rays.ImageColor3 = display.Color

			-- The odds carry the rarity colour, as the Index colours its Rarity label -- a crate slot has
			-- no rarity word, so the number has to say how good this is.
			slot.Chance.Text = `{reward.Chance}%`
			slot.Chance.TextColor3 = display.TextColor

			local stroke = slot.Chance:FindFirstChildWhichIsA("UIStroke")
			if stroke then
				stroke.Color = display.StrokeColor
			end
		end
	end

	self:_bindCrateBundles(crate, card.Buttons)
end

-- Binds one crate's bundle frames: buy for yourself, or gift. Each frame is named for the product it buys
-- (see Crates.GetProductStringId), so adding a bundle is a matter of authoring one more frame.
-- @param crate The crate whose bundles these buy, named only so a mis-named frame can say whose it is
-- @param container The card's Buttons frame
function ShopController:_bindCrateBundles(crate: Crates.Crate, container: Instance)
	for _, bundle in container:GetChildren() do
		if not bundle:IsA("GuiObject") then
			continue
		end

		if not Products.GetProductFromId(bundle.Name) then
			warn(`Crate {crate.Id} has a bundle frame named {bundle.Name}, which isn't a product`)
			continue
		end

		if not bundle.Purchase:FindFirstChild("Title") then
			warn(`Crate {crate.Id}'s {bundle.Name} button has no Title label, so it can't show a price`)
		end

		UIController:BindButtonClick(bundle.Purchase, function()
			self:PromptProductPurchaseFromId(bundle.Name)
		end, true)

		self:_bindGiftButton(bundle.Gift, bundle.Name)

		table.insert(self._purchaseFrames, bundle)
	end
end

--[[
	Binds a Gift button: pick somebody, then buy the product for them.

	Gifting rides the same product with a recipient attached rather than a separate ...Gift dev product --
	ShopManager remembers who was picked and hands the recipient to the callback, so one id covers both.

	The shop is *hidden* rather than closed for the pick: the picker opens as an independent frame, and
	closing this one would drop it out of UIController's bookkeeping with nothing to come back to. Exactly
	one of the picker's callbacks runs, so both put the shop back.
	@param button The Gift button
	@param productId The product to buy for whoever gets picked
]]
function ShopController:_bindGiftButton(button: GuiButton, productId: string)
	local holder = self.UI.Holder

	UIController:BindButtonClick(button, function()
		holder.Visible = false

		SelectPlayerController:StartSelectPlayer(function(player: Player)
			holder.Visible = true
			self:PromptProductPurchaseFromId(productId, player)
		end, function()
			holder.Visible = true
		end)
	end, true)
end

-- Binds the Gamepass category's cards, each named for what it sells, so wiring one is a matter of
-- authoring it under the right name. Both configs are searched despite the category's name: a permanent
-- perk reads as a pass whether it's sold as one or not, and the Golden Grill is a dev product on this shelf.
-- @param container The Gamepass category frame
function ShopController:_setupGamepasses(container: Instance)
	for _, card in container:GetChildren() do
		if not card:IsA("GuiObject") then
			continue
		end

		local product = Products.GetProductFromId(card.Name)
		local gamepass = if product then nil else Gamepasses.GetGamepassFromId(card.Name)

		if not product and not gamepass then
			--warn(`Shop has a card named {card.Name} in the Gamepass category, which isn't a product or a gamepass`)
			continue
		end

		if not card.Purchase:FindFirstChild("Title") then
			warn(`The {card.Name} card has no Title label, so it can't show a price`)
		end

		UIController:BindButtonClick(card.Purchase, function()
			if product then
				self:PromptProductPurchaseFromId(card.Name)
			else
				self:PromptGamepassPurchaseFromId(card.Name)
			end
		end, true)

		table.insert(self._purchaseFrames, card)
	end
end

-- Fills the Bux packs' cards and binds their buttons. Each card is named for its pack, so the amount
-- printed and the amount the server hands over come off one config entry and can't drift apart. Found
-- recursively, since the category splits the cards across a Top and a Bottom row for layout.
-- @param container The Bux category frame
function ShopController:_setupBuxPacks(container: Instance)
	for _, pack in BuxPacks.GetAllBuxPacks() do
		local card = container:FindFirstChild(pack.Id, true)
		if not card then
			warn(`Shop has no card for the {pack.Id} Bux pack, so it can't be sold`)
			continue
		end

		if not card.Purchase:FindFirstChild("Title") then
			warn(`The {pack.Id} card has no Title label, so it can't show a price`)
		end

		card.Amount.Text = `${GuiUtil.ConvertNumberWithSuffix(pack.Amount)}`

		UIController:BindButtonClick(card.Purchase, function()
			self:PromptProductPurchaseFromId(pack.Id)
		end, true)

		self:_bindGiftButton(card.Gift, pack.Id)

		table.insert(self._purchaseFrames, card)
	end
end

-- Fills the starter pack's card and binds its two buttons. Not behind the paid-random-items policy, since
-- everything in the pack is a fixed named item. Whether the card shows at all is _runStarterPackOffer's.
-- @param card The StarterPack card frame
function ShopController:_setupStarterPackCard(card: Frame)
	for index, entry in StarterPackConfig.Contents do
		local slot = card.Container:FindFirstChild(tostring(index))
		local display = slot and resolveRewardDisplay(entry)
		if not display then
			continue
		end

		slot.Icon.Image = display.Icon
		slot.Rays.ImageColor3 = display.Color

		-- Only the name is coloured, not the "x3", so the thing being counted carries the colour -- the
		-- same one the rays behind the icon take, so both halves of the slot read as one item.
		slot.Title.RichText = true
		slot.Title.Text = `x{entry.Amount} {GuiUtil.Colorize(display.Name, display.Color)}`

		-- The odds button is for entries that roll for their contents. Nothing in this pack does.
		slot.Odds.Visible = false
	end

	UIController:BindButtonClick(card.Purchase, function()
		self:PromptProductPurchaseFromId(StarterPackConfig.Id)
	end, true)

	self:_bindGiftButton(card.Gift, StarterPackConfig.Id)
end

-- Binds the starter pack's HUD button and paints its price, handing the frame back so the offer's
-- countdown can drive it alongside the card. It buys outright rather than opening the shop -- the card is
-- still reachable from the Shop button for the contents and the Gift.
-- @return The button's frame, or nil if HudUI has no StarterPack button
function ShopController:_setupStarterPackHudButton(): GuiObject?
	local hudButton = HudController:BindHudButton("StarterPack", function()
		self:PromptProductPurchaseFromId(StarterPackConfig.Id)
	end)

	if not hudButton then
		warn("HudUI has no StarterPack button, so the offer is only reachable from the shop")
		return nil
	end

	-- BindHudButton hands back the wrapper, not the GuiButton, and the labels hang off the wrapper -- so
	-- this is what both the price and the countdown are written to.
	local hudFrame = hudButton.Button
	hudFrame.Visible = false
	hudFrame.Price.Text = `{GuiUtil.ROBUX_ICON}-`

	-- Spawned because GetPrice yields on its first lookup, reading "-" until it lands like the buy buttons.
	task.spawn(function()
		self:GetPrice(StarterPackConfig.Id)
		hudFrame.Price.Text = `{GuiUtil.ROBUX_ICON}{self:GetCachedPrice(StarterPackConfig.Id) or "-"}`
	end)

	return hudFrame
end

-- Runs the starter pack's countdown, pulling the card and the HUD button once it runs out.
-- StarterPackStart is an absolute expiry stamped on first join, so this reads a deadline rather than
-- counting one down, and it survives a rejoin. Both are driven from here, so their clocks can't disagree.
--
-- Buying deliberately does NOT pull the card: PurchaseOnce is validated against the recipient when
-- gifting, so an owner can still gift it and needs the Gift button. The HUD button only ever buys for
-- the presser, so that one does come down.
-- @param card The StarterPack card frame
-- @param hudFrame The StarterPack HUD button's frame, if HudUI has one
function ShopController:_runStarterPackOffer(card: Frame, hudFrame: GuiObject?)
	-- Held rather than re-read each tick, so the button goes the moment the purchase lands.
	local owned = false

	if hudFrame then
		-- Spawned because both wait on the replica, and the countdown shouldn't be held up behind them.
		task.spawn(function()
			owned = table.find(PlayerDataController:GetKey("PurchasedOnceProducts"), StarterPackConfig.Id) ~= nil

			if owned then
				hudFrame.Visible = false
			end

			PlayerDataController:ListenForChange("PurchasedOnceProducts", function(products: { string })
				owned = table.find(products, StarterPackConfig.Id) ~= nil

				if owned then
					hudFrame.Visible = false
				end
			end)
		end)
	end

	while true do
		local expiresAt = PlayerDataController:GetKey("StarterPackStart")

		-- Data hasn't replicated, or the server hasn't stamped the expiry yet -- it writes that
		-- asynchronously and the key sits at 0 meanwhile. A 0 read as a deadline is an offer that expired
		-- in 1970, so it's waited out rather than taken at face value. Both stay hidden until then.
		if not expiresAt or expiresAt <= 0 then
			task.wait(1)
			continue
		end

		local timeLeft = expiresAt - os.time()
		if timeLeft <= 0 then
			card.Visible = false

			if hudFrame then
				hudFrame.Visible = false
			end

			return
		end

		local formattedTime = GuiUtil.ConvertSecondsToHHMMSS(timeLeft)

		card.Countdown.Text = formattedTime
		card.Visible = true

		if hudFrame then
			hudFrame.Countdown.Text = formattedTime
			hudFrame.Visible = not owned
		end

		task.wait(1)
	end
end

-- Paints every crate bundle's buy button with its Robux price, or "-" while the lookup is in flight. A
-- button with no Title is skipped silently -- _bindCrateBundles already warned once, and this runs often.
function ShopController:_refreshPurchasePrices()
	for _, frame in self._purchaseFrames do
		local title = frame.Purchase:FindFirstChild("Title")
		if not title then
			continue
		end

		title.Text = `{GuiUtil.ROBUX_ICON}{self:GetCachedPrice(frame.Name) or "-"}`
	end
end

-- Warms the price cache for every bundle, then paints the buttons. Spawned rather than run while the cards
-- are built, since GetPrice yields on its first MarketplaceService call per id.
function ShopController:_cachePrices()
	for _, frame in self._purchaseFrames do
		self:GetPrice(frame.Name)
	end

	self:_refreshPurchasePrices()
end

-- Fades the full-screen dim in and out with the panel. Hooked to UIController's signals rather than the
-- open/close call sites, since another frame opening also closes this one -- and that path would leave
-- the dim up over whatever replaced the shop.
function ShopController:_setupDim()
	local holder = self.UI.Holder
	local dim = self.UI:FindFirstChild("Dim")

	if not dim then
		warn("ShopUI has no Dim frame, so the shop opens without dimming the world behind it")
		return
	end

	dim.BackgroundTransparency = 1

	UIController.OnFrameOpened:Connect(function(frame)
		if frame == holder then
			TweenService:Create(dim, DIM_TWEEN, { BackgroundTransparency = DIM_TRANSPARENCY }):Play()
		end
	end)

	UIController.OnFrameClosed:Connect(function(frame)
		if frame == holder then
			TweenService:Create(dim, DIM_TWEEN, { BackgroundTransparency = 1 }):Play()
		end
	end)
end

-- Confetti and a sound once a Bux purchase goes through: otherwise the only tell is the amount ticking up
-- in the corner, which is easy to miss with a purchase prompt still on screen.
function ShopController:_setupBuxPurchaseCelebration()
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(_, productId: number, wasPurchased: boolean)
		-- Cleared before the early-outs: a cancelled gift leaving the flag set would mute the next
		-- celebration.
		local wasGift = self._promptedGift
		self._promptedGift = false

		-- Self-purchases only. Gifting rides the same product id (see _bindGiftButton), so without this
		-- the buyer would get confetti for Bux that went to somebody else.
		if not wasPurchased or wasGift then
			return
		end

		local productData = Products.GetProductFromProductId(productId)
		if not productData or productData.Type ~= "Currency" then
			return
		end

		ConfettiController:FireConfettiRain({
			Images = {
				"rbxassetid://105333895679693",
			},

			Colors = {
				Color3.fromRGB(255, 255, 255),
			},

			Scale = 2,
			Gravity = 0.6,
			Duration = 1.5,
			Spin = false,
		})

		SoundController:PlaySound("BuxPurchased")
	end)
end

function ShopController:_setupUI()
	local holder = self.UI.Holder
	holder.Visible = false

	self:_setupDim()
	self:_setupBuxPurchaseCelebration()

	-- Nothing else opens this panel, so a missing button isn't a dead press -- it's an unreachable shop.
	local shopButton = HudController:BindHudButton("Shop", function()
		UIController:OpenFrame(holder)
	end)

	if not shopButton then
		warn("HudUI has no Shop button, so the shop panel can't be opened")
	end

	-- Recursive because the exit sits under the holder on some panels and under a header on others.
	-- Warned rather than indexed, so a missing one can't take the rest of the shop's setup down.
	local exit = holder:FindFirstChild("Exit", true)
	if exit then
		UIController:BindButtonClick(exit, function()
			UIController:CloseFrame(holder)
		end, true)
	else
		warn("Shop has no Exit button, so it can only be closed by opening another frame")
	end

	-- Matched on the crate's Id, so a crate becomes purchasable by authoring a card named after it. One
	-- with no card is skipped silently -- not every crate is meant to be sold.
	local scrollingFrame = holder.Container.ScrollingFrame

	for _, crate in Crates.GetAllCrates() do
		local card = scrollingFrame:FindFirstChild(crate.Id)
		if not card then
			continue
		end

		-- Crates are paid random items, which some accounts can't be sold. Hidden until the policy fetch
		-- allows it, rather than shown and pulled -- that would leave a window to press buy. Armed before
		-- the card is filled, so a card that throws partway through doesn't stay hidden all session.
		card.Visible = false

		task.spawn(function()
			card.Visible = PolicyController:CanPurchaseRandomItems()
		end)

		self:_setupCrateCard(crate, card)
	end

	-- One product rather than a set of bundles, so the card *is* the buy frame and goes into
	-- _purchaseFrames directly. Both it and the HUD button stay hidden until _runStarterPackOffer finds
	-- the offer still standing, and both sit inside the product check -- with nothing to charge, a HUD
	-- button that can't sell anything is worse than none.
	local starterPackCard = scrollingFrame:FindFirstChild(StarterPackConfig.Id)

	if starterPackCard then
		starterPackCard.Visible = false

		if Products.GetProductFromId(StarterPackConfig.Id) then
			self:_setupStarterPackCard(starterPackCard)
			table.insert(self._purchaseFrames, starterPackCard)

			local starterPackHudFrame = self:_setupStarterPackHudButton()

			task.spawn(function()
				self:_runStarterPackOffer(starterPackCard, starterPackHudFrame)
			end)
		else
			warn("Config.StarterPack has no RobuxProductId set, so the starter pack can't be sold")
		end
	end

	local gamepassCategory = scrollingFrame:FindFirstChild("Gamepass")
	if gamepassCategory then
		self:_setupGamepasses(gamepassCategory)
	end

	local buxCategory = scrollingFrame:FindFirstChild("Bux")
	if buxCategory then
		self:_setupBuxPacks(buxCategory)

		-- A shortcut into the Bux packs rather than a second way to open the shop, so it scrolls there as
		-- the panel comes up. The offset is measured on the press, not at setup: cards above the Bux row
		-- come and go, so a figure taken earlier would scroll to the wrong place. CanvasPosition is added
		-- back because the AbsolutePositions only give the gap from the top of the *visible* window.
		local moreButton = HudController:BindHudButton("More", function()
			UIController:OpenFrame(holder)

			-- OpenFrame toggles, so a press with the shop already up closes it. Nothing to scroll then.
			if not holder.Visible then
				return
			end

			local buxOffset = scrollingFrame.CanvasPosition.Y
				+ buxCategory.AbsolutePosition.Y
				- scrollingFrame.AbsolutePosition.Y

			TweenService:Create(scrollingFrame, BUX_SCROLL_TWEEN, {
				CanvasPosition = Vector2.new(0, buxOffset),
			}):Play()
		end)

		if not moreButton then
			warn(
				"HudUI has no More button on the currency display, so the Bux packs are only reachable from the Shop button"
			)
		end
	end

	self:_refreshPurchasePrices()

	task.spawn(function()
		self:_cachePrices()
	end)
end

function ShopController:OnInit()
	PlayerDataController = require(script.Parent.PlayerDataController)
	SelectPlayerController = require(script.Parent.SelectPlayerController)
	PolicyController = require(script.Parent.PolicyController)
	ConfettiController = require(script.Parent.ConfettiController)
	SoundController = require(script.Parent.SoundController)
	UIController = require(script.Parent.UIController)
	HudController = require(script.Parent.HudController)

	self.UI = PlayerGui:WaitForChild("ShopUI")
end

function ShopController:OnStart()
	task.spawn(ShopController._setupUI, self)
end

return ShopController
