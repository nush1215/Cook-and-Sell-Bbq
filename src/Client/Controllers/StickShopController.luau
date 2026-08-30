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

-- How close to the end of the window the restock button stops being offered. A restock bought with
-- seconds to go is money for a stock the free rollover was about to hand over anyway, so the button
-- goes inactive rather than selling that.
local RESTOCK_MIN_TIME_LEFT = 15

-- The colour the countdown is shown in on the shop's restock title.
local RESTOCK_TIME_COLOR = "#55ff00"

-- The stick the display out in the world sells, and the prompt that sells it. The diamond is filtered
-- out of the shop's rows (Restockable = false) and has no currency price at all, so this prompt going
-- straight to its dev product is the only way anyone gets one.
local DIAMOND_STICK_ID = "DiamondStick"
local DIAMOND_PROMPT_DISTANCE = 10
local DIAMOND_PROMPT_HOLD = 0.3

-- The colours a row's description highlights: how many ingredients the stick holds, and the boost it
-- puts on what a skewer built on it sells for.
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

-- The sticks the shop can sell, in tier order (diamond and any non-restockable stick filtered out).
-- The display should iterate this rather than GetAllSticks.
function StickShopController:GetRestockableSticks(): { Sticks.Stick }
	return Sticks.GetRestockableSticks()
end

-- The shared rolled stock for this window, { [stickId] = amount }, or an empty table before the shop
-- replica has arrived.
function StickShopController:GetStock(): { [string]: number }
	if not self._replica then
		return {}
	end

	return self._replica.Data.Stock
end

-- Seconds left in the current restock window, read off the ReplicatedStorage attribute the server
-- mirrors each second. Listen for updates with ReplicatedStorage:GetAttributeChangedSignal(...).
function StickShopController:GetTimeLeft(): number
	return ReplicatedStorage:GetAttribute(TIME_LEFT_ATTRIBUTE) or 0
end

-- How many of a stick this player can still buy this window: the shared stock minus their own
-- purchases. Their Bought only counts while it belongs to the current window (matching Seed); a stale
-- window reads as zero bought, so the full stock is available again after a re-roll.
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

-- Requests a purchase of one of the given stick. The server validates stock, currency and the grant;
-- feedback comes back over StickPurchaseResultEvent and the player-data replica (Bought) updating.
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

-- Returns the stick whose row is currently expanded, or nil if nothing is selected. The buy buttons act
-- on whichever stick this is, so anything that wants to know what a press would buy reads it from here.
function StickShopController:GetSelectedStickId(): string?
	return self._selectedStickId
end

-- Syncs the shared ButtonChoices buy buttons to the currently selected stick: both show that stick's
-- price, and Robux is only offered once the stick has a real dev product.
--
-- Currency-buy is deliberately left pressable even with no stock left and no cash to pay with -- the
-- server rejects it and says why. A dead button just swallows the press with nothing to read.
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
		-- "-" until the MarketplaceService lookup lands (or if it failed), matching ShopController:GetPrice.
		buttonChoices.RobuxPurchase.Title.Text = `{GuiUtil.ROBUX_ICON}{ShopController:GetCachedPrice(stickId) or "-"}`
	end
end

-- Warms ShopController's price cache for each Robux-purchasable stick and the restock, since GetPrice
-- yields on its first MarketplaceService call for an id and the buttons are painted on a press.
-- Refreshes the buttons afterwards in case a stick was already selected while the lookups were in flight.
-- Every stick is walked rather than only the shop's rows: the diamond has no row but is sold off its
-- world display, whose prompt reads out of this same cache.
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

-- Collapses the open ButtonChoices frame, springing its UIScale back down to 0 and only hiding it once
-- the spring lands so it shrinks away instead of blinking out. `instant` skips the animation for cases
-- where the frame isn't on screen to watch it anyway (the whole shop closing).
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
		-- Another stick may have been picked while this collapse was still springing.
		if self._choicesToken == token then
			buttonChoices.Visible = false
		end
	end)
end

-- Expands the shared ButtonChoices frame under the pressed stick (its LayoutOrder is that row's odd
-- order + 1, so the list lands it directly below), popping its UIScale from 0 to 1. Pressing the same
-- stick again collapses it.
function StickShopController:_selectStick(stickId: string)
	-- Every row press comes through here, so holding the shop to one stick is a matter of turning the
	-- others away at the door rather than unbinding a dozen buttons and putting them back afterwards.
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

	-- Drop any in-flight collapse so the pop always starts from 0 under the newly picked stick.
	Spr.stop(uiScale)
	uiScale.Scale = 0
	buttonChoices.Visible = true
	Spr.target(uiScale, POP_DAMPING, POP_FREQUENCY, { Scale = 1 })

	self:_refreshSelectionButtons()
end

-- Holds the shop to a single stick: that row still opens and buys as normal, every other row stops
-- responding to being pressed. Nil puts the whole shop back.
--
-- Set by the tutorial, which is walking the player through buying one particular stick and spotlighting
-- the row for it -- another row expanding underneath that would put its buy button where the lit one was
-- and leave the player buying something the beat isn't waiting for.
-- @param stickId: The only stick that may be opened, or nil to lift the restriction
function StickShopController:SetOnlySelectableStick(stickId: string?)
	self._onlySelectableStickId = stickId

	-- Anything already expanded when the hold goes on is collapsed, so the restriction covers the shop as
	-- it stands rather than only the presses that come after it. Springs shut rather than snapping: the
	-- shop is open and being looked at when this is set, which is the case the instant path isn't for.
	if stickId and self._selectedStickId and self._selectedStickId ~= stickId then
		self:_clearSelection()
	end
end

-- Clones one row per restockable stick from the detached Template, in tier order, and binds the shared
-- buy buttons (which act on whichever stick is selected). Rows take odd LayoutOrders so ButtonChoices
-- can slot into the even gap right below the selected one. Stock text is filled by _refreshRows.
function StickShopController:_buildRows()
	local scrollingFrame = self.UI.Holder.Container.ScrollingFrame
	local template = scrollingFrame.Template
	template.Parent = nil

	-- Looked up rather than indexed: the button is still to be authored into the shop UI, and a hard
	-- index would throw here and take the rest of the shop's rows down with it.
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

		-- The boost clause is dropped rather than written as "+0%" on the tiers that don't have one, so a
		-- plain stick reads as plain instead of advertising nothing.
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

-- Paints the buy-a-restock button: whether it's offered at all. Nothing to do until the button has
-- been authored into the shop UI (see _buildRows). The price isn't written anywhere -- the button
-- carries its own art and has no label to put one in.
function StickShopController:_refreshRestockButton()
	local button = self._restockButton
	if not button then
		return
	end

	button.Active = self:GetTimeLeft() > RESTOCK_MIN_TIME_LEFT
end

-- Writes the time left in the current restock window into the shop's title, colouring just the
-- countdown. Minutes are always shown, so the final stretch reads "0m 9s" rather than dropping the unit.
function StickShopController:_refreshRestockTitle()
	local timeLeft = self:GetTimeLeft()
	local minutes = math.floor(timeLeft / 60)
	local seconds = math.floor(timeLeft % 60)

	self.UI.Holder.RestockTitle.Text =
		`Stick Shop Restocks in: <font color="{RESTOCK_TIME_COLOR}">{minutes}m {seconds}s</font>`
end

-- Writes the diamond's Robux price onto its display prompt. The prompt goes up before the price lookup
-- has landed, so this runs again once _cacheRobuxPrices has it -- "-" until then, matching every other
-- Robux label in the game.
function StickShopController:_refreshDiamondPrompt()
	if not self._diamondPrompt then
		return
	end

	self._diamondPrompt.ObjectText = `{GuiUtil.ROBUX_ICON}{ShopController:GetCachedPrice(DIAMOND_STICK_ID) or "-"}`
end

-- Puts the buy prompt on the Diamond Stick display standing out in the world. Straight to the dev
-- product: there's no stock, no window and no currency price behind it, so nothing here has to be
-- gated the way the shop's own rows are.
function StickShopController:_setupDiamondDisplay()
	-- The display lives in the place file, not this repo, so looked up rather than indexed -- a missing
	-- one leaves the diamond unsellable, which is worth saying out loud.
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

-- Re-reads each row's remaining stock. Runs on the shop restock (replica change) and on this player's
-- own purchases (StickShop data change).
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

	-- The server answers every purchase attempt; a successful one is announced so anything waiting on
	-- the stick actually landing has a signal to wait on rather than polling the player's data.
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
		UIController:CloseFrame(self.UI.Holder)
	end)

	UIController:BindButtonClick(self.UI.Holder.Exit, function()
		UIController:CloseFrame(self.UI.Holder)
	end, true)

	-- Collapse the choices with the shop itself, so re-opening never starts on a leftover selection.
	-- Hooked to the signal rather than each close site since another frame opening also closes this one.
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
