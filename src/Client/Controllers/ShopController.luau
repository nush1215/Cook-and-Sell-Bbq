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
	RequestProductPurchase = Network.Event("RequestProductPurchase"),
	RequestGamepassPurchase = Network.Event("RequestGamepassPurchase"),

	Prices = {},

	-- Every frame that buys something, named for what it buys and holding a Purchase button
	_purchaseFrames = {},

	-- Whether the open prompt is a gift. Roblox shows one at a time, so a flag covers it
	_promptedGift = false,
}

-- Requests a product purchase from an id
function ShopController:PromptProductPurchaseFromId(id: string, toGift: Player?): (boolean, { any })
	local productInfo = Products.GetProductFromId(id)
	if not productInfo then
		warn(`Product data for id {id} not found.`)
		return
	end

	self._promptedGift = toGift ~= nil
	self.RequestProductPurchase:FireServer({ id, toGift })
	return true, productInfo
end

-- Requests a gamepass purchase from an id
function ShopController:PromptGamepassPurchaseFromId(id: string, toGift: Player?): (boolean, { any })
	local gamepassInfo = Gamepasses.GetGamepassFromId(id)
	if not gamepassInfo then
		warn(`Gamepass data for id {id} not found.`)
		return
	end

	self.RequestGamepassPurchase:FireServer({ id, toGift })
	return true, gamepassInfo
end

-- Gets the product or gamepass data from an id
function ShopController:GetProductFromId(id: string): Gamepasses.Gamepass | Products.Product
	return Products.GetProductFromId(id) or Gamepasses.GetGamepassFromId(id)
end

-- The cached Robux price, or nil. Never yields, so it's what a button refresh should read.
function ShopController:GetCachedPrice(id: string): number?
	return self.Prices[id]
end

-- Gets the price of a product or gamepass. Yields on the first lookup for an id, then reads the cache.
function ShopController:GetPrice(id: string)
	local data = Products.GetProductFromId(id) or Gamepasses.GetGamepassFromId(id)
	if not data then
		return "-"
	end
	local isGamepass = if Products.GetProductFromId(id) then false else true

	if data.CurrencyPrice then
		return data.CurrencyPrice
	end

	if self.Prices[data.Id] then
		return self.Prices[data.Id]
	end

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

-- What one sellable thing looks like on a card, branching over the crate and starter-pack rosters. Color is the thing itself; TextColor/StrokeColor are its rarity.
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

-- Fills one crate's card. Preview slots are numbered in config order, so the rarest land on the special ones.
function ShopController:_setupCrateCard(crate: Crates.Crate, card: Frame)
	local slotIndex = 0

	for _, group in crate.Contents do
		for _, reward in group.Rewards do
			slotIndex += 1

			-- Too few slots shows the first few, rather than erroring and leaving the rest of the shop unbuilt
			local slot = card.Container:FindFirstChild(tostring(slotIndex))
			local display = slot and resolveRewardDisplay(reward)
			if not display then
				continue
			end

			slot.Icon.Image = display.Icon
			slot.IngredientName.Text = display.Name
			slot.Value.Text = `${GuiUtil.ConvertNumberWithSuffix(display.Price)}`
			slot.Rays.ImageColor3 = display.Color

			-- The odds carry the rarity colour -- a crate slot has no rarity word, so the number must say how good it is
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

-- Binds a crate's bundle frames, each named for the product it buys, so adding one is authoring a frame.
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

-- Binds a Gift button: pick somebody, then buy the product for them. Gifting rides the same product id with a recipient attached, and the shop is hidden rather than closed for the pick.
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

-- Binds the Gamepass cards by name. Both configs are searched -- a perk reads as a pass however it's sold.
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

-- Fills the Bux cards by pack name, so the printed and granted amounts can't drift. Found recursively.
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

-- Fills the starter pack's card. Not behind the random-items policy -- everything in it is a fixed item.
function ShopController:_setupStarterPackCard(card: Frame)
	for index, entry in StarterPackConfig.Contents do
		local slot = card.Container:FindFirstChild(tostring(index))
		local display = slot and resolveRewardDisplay(entry)
		if not display then
			continue
		end

		slot.Icon.Image = display.Icon
		slot.Rays.ImageColor3 = display.Color

		-- Only the name is coloured, matching the rays behind the icon, so both halves read as one item
		slot.Title.RichText = true
		slot.Title.Text = `x{entry.Amount} {GuiUtil.Colorize(display.Name, display.Color)}`

		-- The odds button is for entries that roll for their contents. Nothing in this pack does
		slot.Odds.Visible = false
	end

	UIController:BindButtonClick(card.Purchase, function()
		self:PromptProductPurchaseFromId(StarterPackConfig.Id)
	end, true)

	self:_bindGiftButton(card.Gift, StarterPackConfig.Id)
end

-- Binds the starter pack's HUD button and returns its frame for the countdown. It buys outright.
function ShopController:_setupStarterPackHudButton(): GuiObject?
	local hudButton = HudController:BindHudButton("StarterPack", function()
		self:PromptProductPurchaseFromId(StarterPackConfig.Id)
	end)

	if not hudButton then
		warn("HudUI has no StarterPack button, so the offer is only reachable from the shop")
		return nil
	end

	-- BindHudButton returns the wrapper, which is where the labels hang, so both are written to it
	local hudFrame = hudButton.Button
	hudFrame.Visible = false
	hudFrame.Price.Text = `{GuiUtil.ROBUX_ICON}-`

	-- Spawned because GetPrice yields on its first lookup, reading "-" until it lands
	task.spawn(function()
		self:GetPrice(StarterPackConfig.Id)
		hudFrame.Price.Text = `{GuiUtil.ROBUX_ICON}{self:GetCachedPrice(StarterPackConfig.Id) or "-"}`
	end)

	return hudFrame
end

-- Runs the starter pack's countdown off an absolute expiry. Buying pulls the HUD button but not the card, which can still gift.
function ShopController:_runStarterPackOffer(card: Frame, hudFrame: GuiObject?)
	-- Held rather than re-read each tick, so the button goes the moment the purchase lands
	local owned = false

	if hudFrame then
		-- Spawned because both wait on the replica, and the countdown shouldn't be held up behind them
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

		-- An unstamped 0 read as a deadline is an offer that expired in 1970, so it's waited out
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

-- Paints every bundle button with its price. A button with no Title is skipped -- already warned once.
function ShopController:_refreshPurchasePrices()
	for _, frame in self._purchaseFrames do
		local title = frame.Purchase:FindFirstChild("Title")
		if not title then
			continue
		end

		title.Text = `{GuiUtil.ROBUX_ICON}{self:GetCachedPrice(frame.Name) or "-"}`
	end
end

-- Warms the price cache for every bundle, then paints the buttons. Spawned, since GetPrice yields.
function ShopController:_cachePrices()
	for _, frame in self._purchaseFrames do
		self:GetPrice(frame.Name)
	end

	self:_refreshPurchasePrices()
end

-- Fades the dim with the panel, hooked to UIController's signals since another frame opening also closes this.
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

-- Confetti and a sound on a Bux purchase, the amount ticking up being easy to miss.
function ShopController:_setupBuxPurchaseCelebration()
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(_, productId: number, wasPurchased: boolean)
		-- Cleared before the early-outs, or a cancelled gift would mute the next celebration
		local wasGift = self._promptedGift
		self._promptedGift = false

		-- Self-purchases only -- gifting rides the same product id, so the buyer would get confetti for someone else
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

	-- Nothing else opens this panel, so a missing button isn't a dead press but an unreachable shop
	local shopButton = HudController:BindHudButton("Shop", function()
		UIController:OpenFrame(holder)
	end)

	if not shopButton then
		warn("HudUI has no Shop button, so the shop panel can't be opened")
	end

	-- Recursive, since the exit sits in different places per panel. Warned rather than indexed
	local exit = holder:FindFirstChild("Exit", true)
	if exit then
		UIController:BindButtonClick(exit, function()
			UIController:CloseFrame(holder)
		end, true)
	else
		warn("Shop has no Exit button, so it can only be closed by opening another frame")
	end

	-- Matched on the crate's Id, so authoring a card sells it. One with no card is skipped silently
	local scrollingFrame = holder.Container.ScrollingFrame

	for _, crate in Crates.GetAllCrates() do
		local card = scrollingFrame:FindFirstChild(crate.Id)
		if not card then
			continue
		end

		-- Hidden until the policy allows it, rather than shown and pulled, which would leave a window to buy
		card.Visible = false

		task.spawn(function()
			card.Visible = PolicyController:CanPurchaseRandomItems()
		end)

		self:_setupCrateCard(crate, card)
	end

	-- One product, so the card is the buy frame. Both it and the HUD button sit inside the product check
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

		-- Measured on the press, since cards above the Bux row come and go. CanvasPosition is added back
		local moreButton = HudController:BindHudButton("More", function()
			UIController:OpenFrame(holder)

			-- OpenFrame toggles, so a press with the shop already up closes it. Nothing to scroll then
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
