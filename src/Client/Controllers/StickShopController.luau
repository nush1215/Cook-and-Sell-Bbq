-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Replica = require(Packages.Replica)
local Signal = require(Packages.Signal)
local Spr = require(Packages.Spr)
local Trove = require(Packages.Trove)
local Zone = require(Packages.ZonePlus)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local Sticks = require(Shared.Config.Sticks)
local Colors = require(Shared.Colors)

-- Controllers
local PlayerDataController
local UIController
local ShopController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

--
local TIME_LEFT_ATTRIBUTE = "StickShopTimeLeft"
local BUY_DEBOUNCE = 0.3 -- client-side only; the server's _purchasing guard is authoritative

-- The dev product that re-rolls the shop's stock for the whole server (see StickShopManager:RestockShop).
local RESTOCK_PRODUCT_ID = "StickShopRestock"

-- The button goes inactive this close to the window's end, rather than selling what rollover was about to give
local RESTOCK_MIN_TIME_LEFT = 15

-- The colour the countdown is shown in on the shop's restock title.
local RESTOCK_TIME_COLOR = "#55ff00"

-- The diamond is filtered out of the rows and has no currency price, so this prompt is the only way to one
local DIAMOND_STICK_ID = "DiamondStick"
local DIAMOND_PROMPT_DISTANCE = 10
local DIAMOND_PROMPT_HOLD = 0.3

-- The colours a row's description highlights: capacity, and the boost on what a skewer built on it sells for
local CAPACITY_COLOR = "#55ff00"
local BOOST_COLOR = "#ffd400"

-- ButtonChoices pop-in spring (UIScale 0 -> 1)
local POP_DAMPING = 0.6
local POP_FREQUENCY = 4

-- ButtonChoices collapse spring (UIScale 1 -> 0); critically damped so it can't overshoot past 0
local COLLAPSE_DAMPING = 1
local COLLAPSE_FREQUENCY = 6

--
local StickShopController = {
	PurchaseStickEvent = Network.Event("PurchaseStick"), -- client -> server (stickId)
	StickPurchaseResultEvent = Network.Event("StickPurchaseResult"), -- server -> client (success, stickId)

	-- (stickId) once the server confirms a purchase went through.
	OnStickPurchased = Signal.new(),

	_replica = nil,
	_buyDebounce = false,

	_rows = {}, -- [stickId] = the cloned Template row for that stick
	_selectedStickId = nil, -- the stick whose ButtonChoices are currently expanded, or nil
	_onlySelectableStickId = nil, -- while set, the only row that will open (see SetOnlySelectableStick)
	_choicesToken = 0, -- bumped on every expand/collapse so a stale spring callback can't hide a re-opened frame
	_restockButton = nil, -- the buy-a-restock button, once the shop UI has one authored
	_diamondPrompt = nil, -- the buy prompt on the world's Diamond Stick display, once one is authored
	_uiCleaner = Trove.new(),
}

-- The sticks the shop can sell, in tier order. The display should iterate this rather than GetAllSticks.
function StickShopController:GetRestockableSticks(): { Sticks.Stick }
	return Sticks.GetRestockableSticks()
end

-- The window's shared stock, or empty before the shop replica arrives.
function StickShopController:GetStock(): { [string]: number }
	if not self._replica then
		return {}
	end

	return self._replica.Data.Stock
end

-- Seconds left in the window, off the attribute the server mirrors each second.
function StickShopController:GetTimeLeft(): number
	return ReplicatedStorage:GetAttribute(TIME_LEFT_ATTRIBUTE) or 0
end

-- How many of a stick they can still buy: shared stock less their own purchases for this window.
function StickShopController:GetRemaining(stickId: string): number
	local stock = self:GetStock()[stickId] or 0

	if not self._replica then
		return stock
	end

	local stickShop = PlayerDataController:GetKey("StickShop")
	if not stickShop or stickShop.Seed ~= self._replica.Data.Seed then
		return stock
	end

	return stock - (stickShop.Bought[stickId] or 0)
end

-- Requests one of `stickId`; the server validates and answers over StickPurchaseResultEvent.
function StickShopController:Buy(stickId: string)
	if self._buyDebounce then
		return
	end

	self._buyDebounce = true
	task.delay(BUY_DEBOUNCE, function()
		self._buyDebounce = false
	end)

	self.PurchaseStickEvent:FireServer(stickId)
end

-- Shuts the shop as Exit does. Public because the tutorial closes it before asking for the top bar behind it.
function StickShopController:Close()
	UIController:CloseFrame(self.UI.Holder)
end

-- The stick whose row is expanded, or nil. The buy buttons act on it.
function StickShopController:GetSelectedStickId(): string?
	return self._selectedStickId
end

-- Paints the shared buy buttons for the selected stick. Currency-buy stays pressable, so the server can say why.
function StickShopController:_refreshSelectionButtons()
	local stickId = self._selectedStickId
	if not stickId then
		return
	end

	local stick = Sticks.GetStickFromId(stickId)
	local buttonChoices = self._buttonChoices

	buttonChoices.CurrencyPurchase.Title.Text = `${GuiUtil.ConvertNumberWithSuffix(stick.Price)}`

	local hasProduct = stick.RobuxProductId ~= nil and stick.RobuxProductId ~= 0
	buttonChoices.RobuxPurchase.Visible = hasProduct

	if hasProduct then
		-- "-" until the MarketplaceService lookup lands, matching ShopController:GetPrice
		buttonChoices.RobuxPurchase.Title.Text = `{GuiUtil.ROBUX_ICON}{ShopController:GetCachedPrice(stickId) or "-"}`
	end
end

-- Warms the price cache, since GetPrice yields on its first lookup and the buttons are painted on a press.
function StickShopController:_cacheRobuxPrices()
	for _, stick in Sticks.GetAllSticks() do
		if not stick.RobuxProductId or stick.RobuxProductId == 0 then
			continue
		end

		ShopController:GetPrice(stick.Id)
	end

	ShopController:GetPrice(RESTOCK_PRODUCT_ID)

	self:_refreshSelectionButtons()
	self:_refreshRestockButton()
	self:_refreshDiamondPrompt()
end

-- Collapses the open ButtonChoices, hiding it only once the spring lands. `instant` skips that off screen.
function StickShopController:_clearSelection(instant: boolean?)
	if not self._selectedStickId then
		return
	end

	self._selectedStickId = nil
	self._choicesToken += 1

	local buttonChoices = self._buttonChoices
	local uiScale = self._choicesScale

	if instant then
		Spr.stop(uiScale)
		uiScale.Scale = 0
		buttonChoices.Visible = false
		return
	end

	local token = self._choicesToken
	Spr.target(uiScale, COLLAPSE_DAMPING, COLLAPSE_FREQUENCY, { Scale = 0 })
	Spr.completed(uiScale, function()
		-- Another stick may have been picked while this collapse was still springing
		if self._choicesToken == token then
			buttonChoices.Visible = false
		end
	end)
end

-- Expands ButtonChoices under the pressed stick, rows taking odd LayoutOrders so it slots into the even gap.
function StickShopController:_selectStick(stickId: string)
	-- Every row press comes through here, so a hold is a matter of turning others away at the door
	if self._onlySelectableStickId and stickId ~= self._onlySelectableStickId then
		return
	end

	if self._selectedStickId == stickId then
		self:_clearSelection()
		return
	end

	local buttonChoices = self._buttonChoices
	local uiScale = self._choicesScale

	self._selectedStickId = stickId
	self._choicesToken += 1

	buttonChoices.LayoutOrder = self._rows[stickId].LayoutOrder + 1

	-- Drop any in-flight collapse so the pop always starts from 0 under the newly picked stick
	Spr.stop(uiScale)
	uiScale.Scale = 0
	buttonChoices.Visible = true
	Spr.target(uiScale, POP_DAMPING, POP_FREQUENCY, { Scale = 1 })

	self:_refreshSelectionButtons()
end

-- Holds the shop to one stick for the tutorial, so no other row can expand under the spotlighted one.
function StickShopController:SetOnlySelectableStick(stickId: string?)
	self._onlySelectableStickId = stickId

	-- Collapsed so the hold covers the shop as it stands. Sprung, since it's open and being looked at
	if stickId and self._selectedStickId and self._selectedStickId ~= stickId then
		self:_clearSelection()
	end
end

-- Builds one row per restockable stick in tier order and binds the shared buy buttons. Stock is _refreshRows'.
function StickShopController:_buildRows()
	local scrollingFrame = self.UI.Holder.Container.ScrollingFrame
	local template = scrollingFrame.Template
	template.Parent = nil

	-- Looked up rather than indexed -- the button is still to be authored, and a hard index would throw
	self._restockButton = self.UI.Holder:FindFirstChild("Restock")
	if self._restockButton then
		self._uiCleaner:Add(UIController:BindButtonClick(self._restockButton, function()
			ShopController:PromptProductPurchaseFromId(RESTOCK_PRODUCT_ID)
		end, true).Disconnect)
	else
		warn("Stick shop has no Restock button, so the restock product can't be bought")
	end

	self._buttonChoices = scrollingFrame.ButtonChoices
	self._buttonChoices.Visible = false

	local uiScale = self._buttonChoices:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = self._buttonChoices
	end
	uiScale.Scale = 0
	self._choicesScale = uiScale

	self._uiCleaner:Add(UIController:BindButtonClick(self._buttonChoices.CurrencyPurchase, function()
		if self._selectedStickId then
			self:Buy(self._selectedStickId)
		end
	end, true).Disconnect)

	self._uiCleaner:Add(UIController:BindButtonClick(self._buttonChoices.RobuxPurchase, function()
		local stickId = self._selectedStickId
		if not stickId then
			return
		end

		local stick = Sticks.GetStickFromId(stickId)
		if stick.RobuxProductId and stick.RobuxProductId ~= 0 then
			ShopController:PromptProductPurchaseFromId(stickId)
		end
	end, true).Disconnect)

	for order, stick in Sticks.GetRestockableSticks() do
		local row = template:Clone()
		row.Name = stick.Id
		row.LayoutOrder = order * 2 - 1

		row.Icon.Image = stick.Icon
		row.Rays.ImageColor3 = stick.TextColor

		row.Rarity.Text = stick.Rarity
		row.Rarity.TextColor3 = Colors[stick.Rarity].TextColor
		local rarityStroke = row.Rarity:FindFirstChildWhichIsA("UIStroke")
		if rarityStroke then
			rarityStroke.Color = Colors[stick.Rarity].StrokeColor
		end

		row.Details.StickName.Text = `{stick.Name} Stick`
		row.Details.StickName.TextColor3 = stick.TextColor
		local nameStroke = row.Details.StickName:FindFirstChildWhichIsA("UIStroke")
		if nameStroke then
			nameStroke.Color = stick.StrokeColor
		end

		row.Details.Price.Text = `${GuiUtil.ConvertNumberWithSuffix(stick.Price)}`

		-- Dropped rather than written as "+0%", so a plain stick reads as plain instead of advertising nothing
		local ingredientWord = stick.Capacity == 1 and "Ingredient" or "Ingredients"
		local description = `Holds <font color="{CAPACITY_COLOR}">{stick.Capacity} {ingredientWord}</font>`
		if stick.ValueBoost > 0 then
			description ..= ` & <font color="{BOOST_COLOR}">+{stick.ValueBoost}%</font> Value`
		end

		row.Description.RichText = true
		row.Description.Text = description

		self._uiCleaner:Add(UIController:BindButtonClick(row.Button, function()
			self:_selectStick(stick.Id)
		end, true).Disconnect)

		self._rows[stick.Id] = row
		row.Visible = true
		row.Parent = scrollingFrame
	end
end

-- Decides whether the restock button is offered. No price -- the button carries its own art.
function StickShopController:_refreshRestockButton()
	local button = self._restockButton
	if not button then
		return
	end

	button.Active = self:GetTimeLeft() > RESTOCK_MIN_TIME_LEFT
end

-- Writes the window's time left into the title. Minutes always shown, so the last stretch reads "0m 9s".
function StickShopController:_refreshRestockTitle()
	local timeLeft = self:GetTimeLeft()
	local minutes = math.floor(timeLeft / 60)
	local seconds = math.floor(timeLeft % 60)

	self.UI.Holder.RestockTitle.Text =
		`Stick Shop Restocks in: <font color="{RESTOCK_TIME_COLOR}">{minutes}m {seconds}s</font>`
end

-- Writes the diamond's price onto its display prompt, re-run once _cacheRobuxPrices has it.
function StickShopController:_refreshDiamondPrompt()
	if not self._diamondPrompt then
		return
	end

	self._diamondPrompt.ObjectText = `{GuiUtil.ROBUX_ICON}{ShopController:GetCachedPrice(DIAMOND_STICK_ID) or "-"}`
end

-- Puts the buy prompt on the diamond's world display, straight to the dev product with no gating.
function StickShopController:_setupDiamondDisplay()
	-- Looked up rather than indexed -- a missing one leaves the diamond unsellable, which is worth saying
	local displays = workspace:FindFirstChild("Displays")
	local display = displays and displays:FindFirstChild("DiamondStickDisplay")
	local promptAttachment = display and display:FindFirstChild("PromptAttachment")

	if not promptAttachment then
		warn("No Displays.DiamondStickDisplay.PromptAttachment in the place file, the Diamond Stick can't be bought")
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = "Purchase Diamond Stick"
	prompt.HoldDuration = DIAMOND_PROMPT_HOLD
	prompt.MaxActivationDistance = DIAMOND_PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = promptAttachment

	self._uiCleaner:Connect(prompt.Triggered, function()
		ShopController:PromptProductPurchaseFromId(DIAMOND_STICK_ID)
	end)

	self._diamondPrompt = prompt
	self:_refreshDiamondPrompt()
end

-- Re-reads each row's stock, on a restock and on this player's own purchases.
function StickShopController:_refreshRows()
	if not next(self._rows) then
		return
	end

	for stickId, row in self._rows do
		row.Details.Stock.Text = `x{self:GetRemaining(stickId)} Stock`
	end
end

function StickShopController:OnInit()
	PlayerDataController = require(script.Parent.PlayerDataController)
	UIController = require(script.Parent.UIController)
	ShopController = require(script.Parent.ShopController)

	self.UI = PlayerGui:WaitForChild("StickShopUI")

	Replica.OnNew("StickShop", function(replica)
		self._replica = replica
		replica:OnChange(function()
			self:_refreshRows()
		end)
		self:_refreshRows()
	end)
end

function StickShopController:OnStart()
	self.UI.Holder.Visible = false

	self:_buildRows()
	self:_setupDiamondDisplay()

	-- Countdown title: the server mirrors the seconds left onto the attribute once a second.
	self.UI.Holder.RestockTitle.RichText = true
	self:_refreshRestockTitle()
	self:_refreshRestockButton()
	ReplicatedStorage:GetAttributeChangedSignal(TIME_LEFT_ATTRIBUTE):Connect(function()
		self:_refreshRestockTitle()
		self:_refreshRestockButton()
	end)

	task.spawn(function()
		self:_cacheRobuxPrices()
	end)

	-- A successful attempt is announced, so anything waiting on the stick has a signal rather than a poll
	self.StickPurchaseResultEvent:OnClientEvent(function(success: boolean, stickId: string)
		if success then
			self.OnStickPurchased:Fire(stickId)
		end
	end)

	-- Open when the local player walks into the shop zone, close when they leave (or hit Exit).
	local zone = Zone.new(workspace:WaitForChild("Core"):WaitForChild("Zones"):WaitForChild("StickShop"))
	zone.localPlayerEntered:Connect(function()
		UIController:OpenFrame(self.UI.Holder)
	end)
	zone.localPlayerExited:Connect(function()
		self:Close()
	end)

	UIController:BindButtonClick(self.UI.Holder.Exit, function()
		self:Close()
	end, true)

	-- Hooked to the signal rather than each close site, since another frame opening also closes this one
	UIController.OnFrameClosed:Connect(function(frame)
		if frame == self.UI.Holder then
			self:_clearSelection(true)
		end
	end)

	-- First stock read + keep the rows live. Deferred: GetRemaining awaits the player-data replica.
	task.spawn(function()
		self:_refreshRows()

		PlayerDataController:ListenForChange("StickShop", function()
			self:_refreshRows()
		end)
	end)
end

return StickShopController
