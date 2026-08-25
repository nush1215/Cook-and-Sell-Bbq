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
local Structures = require(Shared.Config.Structures)
local Colors = require(Shared.Colors)

-- Controllers
local PlayerDataController
local UIController
local ShopController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

--
local TIME_LEFT_ATTRIBUTE = "GrillStandShopTimeLeft"
local BUY_DEBOUNCE = 0.3 -- client-side only; the server's _purchasing guard is authoritative

-- The dev product that re-rolls the shop's stock for the whole server (see GrillStandShopManager:RestockShop).
local RESTOCK_PRODUCT_ID = "GrillStandShopRestock"

-- How close to the end of the window the restock button stops being offered. A restock bought with
-- seconds to go is money for a stock the free rollover was about to hand over anyway, so the button
-- goes inactive rather than selling that.
local RESTOCK_MIN_TIME_LEFT = 15

-- The colour the countdown is shown in on the shop's restock title.
local RESTOCK_TIME_COLOR = "#55ff00"

-- The zone out in the world that opens the shop, under workspace.Core.Zones.
local ZONE_NAME = "GrillStandShop"

-- The Golden Grill and the display it's sold off out in the world, under workspace.Displays. It has no
-- shop row of its own -- it isn't restockable, so it's never stocked and can't be bought with currency
-- -- which is why it gets a display and a shop card instead.
local GOLDEN_GRILL_ID = "GoldenGrill"
local GOLDEN_GRILL_DISPLAY = "GoldenGrillDisplay"
local GOLDEN_GRILL_PROMPT_HOLD = 0.3
local GOLDEN_GRILL_PROMPT_DISTANCE = 10

-- The Holder.CategoryButtons child that shows each structure category, in tab order. The button names
-- are what the UI was authored with; the categories are what Config.Structures and the CollectionService
-- tags use, and the two don't read the same -- hence the mapping rather than matching on name.
local CATEGORY_BUTTONS = {
	{ Button = "Grills", Category = "Grillers" },
	{ Button = "StickStand", Category = "StickStands" },
}

-- ButtonChoices pop-in spring (UIScale 0 -> 1)
local POP_DAMPING = 0.6
local POP_FREQUENCY = 4

-- ButtonChoices collapse spring (UIScale 1 -> 0); critically damped so it can't overshoot past 0
local COLLAPSE_DAMPING = 1
local COLLAPSE_FREQUENCY = 6

--
local GrillStandShopController = {
	PurchaseStructureEvent = Network.Event("PurchaseStructure"), -- client -> server (structureId)
	StructurePurchaseResultEvent = Network.Event("StructurePurchaseResult"), -- server -> client (success, structureId)

	-- (structureId) once the server confirms a purchase went through.
	OnStructurePurchased = Signal.new(),

	_replica = nil,
	_buyDebounce = false,

	_rows = {}, -- [structureId] = the cloned Template row for that structure
	_selectedStructureId = nil, -- the structure whose ButtonChoices are currently expanded, or nil
	_selectedCategory = nil, -- the category tab currently showing, a Structures.Category
	_choicesToken = 0, -- bumped on every expand/collapse so a stale spring callback can't hide a re-opened frame
	_restockButton = nil, -- the buy-a-restock button, once the shop UI has one authored
	_goldenGrillPrompt = nil, -- the buy prompt on the Golden Grill's world display, once it's up
	_uiCleaner = Trove.new(),
}

-- The shared rolled stock for this window, { [structureId] = amount }, or an empty table before the shop
-- replica has arrived.
function GrillStandShopController:GetStock(): { [string]: number }
	if not self._replica then
		return {}
	end

	return self._replica.Data.Stock
end

-- Seconds left in the current restock window, read off the ReplicatedStorage attribute the server
-- mirrors each second. Listen for updates with ReplicatedStorage:GetAttributeChangedSignal(...).
function GrillStandShopController:GetTimeLeft(): number
	return ReplicatedStorage:GetAttribute(TIME_LEFT_ATTRIBUTE) or 0
end

-- How many of a structure this player can still buy this window: the shared stock minus their own
-- purchases. Their Bought only counts while it belongs to the current window (matching Seed); a stale
-- window reads as zero bought, so the full stock is available again after a re-roll.
function GrillStandShopController:GetRemaining(structureId: string): number
	local stock = self:GetStock()[structureId] or 0

	if not self._replica then
		return stock
	end

	local grillStandShop = PlayerDataController:GetKey("GrillStandShop")
	if not grillStandShop or grillStandShop.Seed ~= self._replica.Data.Seed then
		return stock
	end

	return stock - (grillStandShop.Bought[structureId] or 0)
end

-- Requests a purchase of one of the given structure. The server validates stock, currency and the grant;
-- feedback comes back over StructurePurchaseResultEvent and the player-data replica (Bought) updating.
function GrillStandShopController:Buy(structureId: string)
	if self._buyDebounce then
		return
	end

	self._buyDebounce = true
	task.delay(BUY_DEBOUNCE, function()
		self._buyDebounce = false
	end)

	self.PurchaseStructureEvent:FireServer(structureId)
end

-- Returns the structure whose row is currently expanded, or nil if nothing is selected. The buy buttons
-- act on whichever structure this is, so anything that wants to know what a press would buy reads it here.
function GrillStandShopController:GetSelectedStructureId(): string?
	return self._selectedStructureId
end

-- Syncs the shared ButtonChoices buy buttons to the currently selected structure: both show that
-- structure's price, Robux is only offered once it has a real dev product, and currency-buy is disabled
-- when this window's stock is gone.
function GrillStandShopController:_refreshSelectionButtons()
	local structureId = self._selectedStructureId
	if not structureId then
		return
	end

	local structure = Structures.GetStructureFromId(structureId)
	local buttonChoices = self._buttonChoices

	buttonChoices.CurrencyPurchase.Active = self:GetRemaining(structureId) > 0
	buttonChoices.CurrencyPurchase.Title.Text = `${GuiUtil.ConvertNumberWithSuffix(structure.Cost)}`

	local hasProduct = structure.RobuxProductId ~= nil and structure.RobuxProductId ~= 0
	buttonChoices.RobuxPurchase.Visible = hasProduct

	if hasProduct then
		-- "-" until the MarketplaceService lookup lands (or if it failed), matching ShopController:GetPrice.
		buttonChoices.RobuxPurchase.Title.Text =
			`{GuiUtil.ROBUX_ICON}{ShopController:GetCachedPrice(structureId) or "-"}`
	end
end

-- Writes the Golden Grill's Robux price onto its display prompt. The prompt goes up before the price
-- lookup has landed, so this runs again once _cacheRobuxPrices has it -- "-" until then, matching every
-- other Robux label in the game.
function GrillStandShopController:_refreshGoldenGrillPrompt()
	if not self._goldenGrillPrompt then
		return
	end

	self._goldenGrillPrompt.ObjectText = `{GuiUtil.ROBUX_ICON}{ShopController:GetCachedPrice(GOLDEN_GRILL_ID) or "-"}`
end

-- Puts the buy prompt on the Golden Grill display standing out in the world. Straight to the dev
-- product: there's no stock and no currency price behind it, so nothing here has to be gated the way
-- the shop's own rows are.
function GrillStandShopController:_setupGoldenGrillDisplay()
	-- The display lives in the place file, not this repo, so looked up rather than indexed -- a missing
	-- one leaves the Golden Grill buyable only from the shop card, which is worth saying out loud.
	local displays = workspace:FindFirstChild("Displays")
	local display = displays and displays:FindFirstChild(GOLDEN_GRILL_DISPLAY)
	local promptAttachment = display and display:FindFirstChild("PromptAttachment")

	if not promptAttachment then
		warn(`No Displays.{GOLDEN_GRILL_DISPLAY}.PromptAttachment in the place file, the Golden Grill has no display`)
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = "Purchase Golden Grill"
	prompt.HoldDuration = GOLDEN_GRILL_PROMPT_HOLD
	prompt.MaxActivationDistance = GOLDEN_GRILL_PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = promptAttachment

	self._uiCleaner:Connect(prompt.Triggered, function()
		ShopController:PromptProductPurchaseFromId(GOLDEN_GRILL_ID)
	end)

	self._goldenGrillPrompt = prompt
	self:_refreshGoldenGrillPrompt()
end

-- Warms ShopController's price cache for each Robux-purchasable structure and the restock, since
-- GetPrice yields on its first MarketplaceService call for an id and the buttons are painted on a press.
-- Refreshes the buttons afterwards in case a structure was already selected while the lookups were in
-- flight.
--
-- Every structure is walked rather than only the restockable ones: the Golden Grill has no shop row and
-- can't be bought with currency at all, which is exactly why it needs its price on a display prompt.
function GrillStandShopController:_cacheRobuxPrices()
	for _, structure in Structures.Data do
		if not structure.RobuxProductId or structure.RobuxProductId == 0 then
			continue
		end

		ShopController:GetPrice(structure.Id)
	end

	ShopController:GetPrice(RESTOCK_PRODUCT_ID)

	self:_refreshSelectionButtons()
	self:_refreshRestockButton()
	self:_refreshGoldenGrillPrompt()
end

-- Collapses the open ButtonChoices frame, springing its UIScale back down to 0 and only hiding it once
-- the spring lands so it shrinks away instead of blinking out. `instant` skips the animation for cases
-- where the frame isn't on screen to watch it anyway (the whole shop closing).
function GrillStandShopController:_clearSelection(instant: boolean?)
	if not self._selectedStructureId then
		return
	end

	self._selectedStructureId = nil
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
		-- Another structure may have been picked while this collapse was still springing.
		if self._choicesToken == token then
			buttonChoices.Visible = false
		end
	end)
end

-- Expands the shared ButtonChoices frame under the pressed structure (its LayoutOrder is that row's odd
-- order + 1, so the list lands it directly below), popping its UIScale from 0 to 1. Pressing the same
-- structure again collapses it.
function GrillStandShopController:_selectStructure(structureId: string)
	if self._selectedStructureId == structureId then
		self:_clearSelection()
		return
	end

	local buttonChoices = self._buttonChoices
	local uiScale = self._choicesScale

	self._selectedStructureId = structureId
	self._choicesToken += 1

	buttonChoices.LayoutOrder = self._rows[structureId].LayoutOrder + 1

	-- Drop any in-flight collapse so the pop always starts from 0 under the newly picked structure.
	Spr.stop(uiScale)
	uiScale.Scale = 0
	buttonChoices.Visible = true
	Spr.target(uiScale, POP_DAMPING, POP_FREQUENCY, { Scale = 1 })

	self:_refreshSelectionButtons()
end

-- Switches the shop to a category tab: every row is built once into the one scrolling frame and shown
-- or hidden from here, since the list layout skips invisible children -- so a tab switch costs nothing
-- and the odd/even LayoutOrder gap ButtonChoices slots into survives it.
-- Any open selection is dropped first: the row it belongs to may be one of the ones about to be hidden,
-- which would leave the buy buttons acting on something the player can't see.
function GrillStandShopController:_selectCategory(category: string)
	-- Pressing the tab that's already showing is a no-op rather than a re-run: the rows wouldn't change,
	-- and the clear below would shut an open row's buy buttons for no reason the player can see.
	if self._selectedCategory == category then
		return
	end

	self:_clearSelection(true)
	self._selectedCategory = category

	for _, structure in Structures.GetRestockableStructures() do
		self._rows[structure.Id].Visible = structure.Category == category
	end

	self.UI.Holder.Container.ScrollingFrame.CanvasPosition = Vector2.zero
end

-- Binds each category tab to the structure category it shows. Looked up rather than indexed: the buttons
-- live in the place file, and a missing one shouldn't take the rest of the tabs down with it.
function GrillStandShopController:_bindCategoryButtons()
	local categoryButtons = self.UI.Holder:FindFirstChild("CategoryButtons")
	if not categoryButtons then
		warn("Grill & Stand shop has no CategoryButtons, so its categories can't be switched")
		return
	end

	for _, entry in CATEGORY_BUTTONS do
		local button = categoryButtons:FindFirstChild(entry.Button)
		if not button then
			warn(`Grill & Stand shop has no {entry.Button} category button, so {entry.Category} can't be opened`)
			continue
		end

		self._uiCleaner:Add(UIController:BindButtonClick(button, function()
			self:_selectCategory(entry.Category)
		end, true).Disconnect)
	end
end

-- Clones one row per restockable structure from the detached Template -- every category into the one
-- scrolling frame, with _selectCategory deciding which are on screen -- and binds the shared buy buttons
-- (which act on whichever structure is selected). Rows take odd LayoutOrders so ButtonChoices can slot
-- into the even gap right below the selected one. Stock text is filled by _refreshRows.
function GrillStandShopController:_buildRows()
	local scrollingFrame = self.UI.Holder.Container.ScrollingFrame
	local template = scrollingFrame.Template
	template.Parent = nil

	-- Looked up rather than indexed, the same as the category buttons above.
	self._restockButton = self.UI.Holder:FindFirstChild("Restock")
	if self._restockButton then
		self._uiCleaner:Add(UIController:BindButtonClick(self._restockButton, function()
			ShopController:PromptProductPurchaseFromId(RESTOCK_PRODUCT_ID)
		end, true).Disconnect)
	else
		warn("Grill & Stand shop has no Restock button, so the restock product can't be bought")
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
		if self._selectedStructureId then
			self:Buy(self._selectedStructureId)
		end
	end, true).Disconnect)

	self._uiCleaner:Add(UIController:BindButtonClick(self._buttonChoices.RobuxPurchase, function()
		local structureId = self._selectedStructureId
		if not structureId then
			return
		end

		local structure = Structures.GetStructureFromId(structureId)
		if structure.RobuxProductId and structure.RobuxProductId ~= 0 then
			ShopController:PromptProductPurchaseFromId(structureId)
		end
	end, true).Disconnect)

	for order, structure in Structures.GetRestockableStructures() do
		local row = template:Clone()
		row.Name = structure.Id
		row.LayoutOrder = order * 2 - 1

		row.Icon.Image = structure.Icon
		row.Rays.ImageColor3 = structure.TextColor

		row.Rarity.Text = structure.Rarity
		row.Rarity.TextColor3 = Colors[structure.Rarity].TextColor
		local rarityStroke = row.Rarity:FindFirstChildWhichIsA("UIStroke")
		if rarityStroke then
			rarityStroke.Color = Colors[structure.Rarity].StrokeColor
		end

		row.Details.StructureName.Text = structure.Name
		row.Details.StructureName.TextColor3 = structure.TextColor
		local nameStroke = row.Details.StructureName:FindFirstChildWhichIsA("UIStroke")
		if nameStroke then
			nameStroke.Color = structure.StrokeColor
		end

		row.Details.Price.Text = `${GuiUtil.ConvertNumberWithSuffix(structure.Cost)}`

		-- Straight from the config rather than composed the way the stick shop builds its descriptions:
		-- a structure has no capacity or boost figure to write a line out of. RichText is on regardless,
		-- so a description authored with <font> tags renders rather than showing its own markup.
		row.Description.RichText = true
		row.Description.Text = structure.Description

		self._uiCleaner:Add(UIController:BindButtonClick(row.Button, function()
			self:_selectStructure(structure.Id)
		end, true).Disconnect)

		self._rows[structure.Id] = row
		row.Parent = scrollingFrame
	end

	-- Opens on the first tab; this is also what sets every row's Visible for the first time.
	self:_selectCategory(CATEGORY_BUTTONS[1].Category)
end

-- Paints the buy-a-restock button: whether it's offered at all. Nothing to do until the button has
-- been authored into the shop UI (see _buildRows). The price isn't written anywhere -- the button
-- carries its own art and has no label to put one in.
function GrillStandShopController:_refreshRestockButton()
	local button = self._restockButton
	if not button then
		return
	end

	button.Active = self:GetTimeLeft() > RESTOCK_MIN_TIME_LEFT
end

-- Writes the time left in the current restock window into the shop's title, colouring just the
-- countdown. Minutes are always shown, so the final stretch reads "0m 9s" rather than dropping the unit.
function GrillStandShopController:_refreshRestockTitle()
	local timeLeft = self:GetTimeLeft()
	local minutes = math.floor(timeLeft / 60)
	local seconds = math.floor(timeLeft % 60)

	self.UI.Holder.RestockTitle.Text =
		`Grill & Stand Shop Restocks in: <font color="{RESTOCK_TIME_COLOR}">{minutes}m {seconds}s</font>`
end

-- Re-reads each row's remaining stock and keeps the open ButtonChoices' buy state in sync. Runs on the
-- shop restock (replica change) and on this player's own purchases (GrillStandShop data change).
function GrillStandShopController:_refreshRows()
	if not next(self._rows) then
		return
	end

	for structureId, row in self._rows do
		row.Details.Stock.Text = `x{self:GetRemaining(structureId)} Stock`
	end

	if self._selectedStructureId then
		self:_refreshSelectionButtons()
	end
end

function GrillStandShopController:OnInit()
	PlayerDataController = require(script.Parent.PlayerDataController)
	UIController = require(script.Parent.UIController)
	ShopController = require(script.Parent.ShopController)

	self.UI = PlayerGui:WaitForChild("GrillStandShopUI")

	Replica.OnNew("GrillStandShop", function(replica)
		self._replica = replica
		replica:OnChange(function()
			self:_refreshRows()
		end)
		self:_refreshRows()
	end)
end

function GrillStandShopController:OnStart()
	self.UI.Holder.Visible = false

	self:_buildRows()
	self:_bindCategoryButtons()
	self:_setupGoldenGrillDisplay()

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
	-- the structure actually landing has a signal to wait on rather than polling the player's data.
	self.StructurePurchaseResultEvent:OnClientEvent(function(success: boolean, structureId: string)
		if success then
			self.OnStructurePurchased:Fire(structureId)
		end
	end)

	-- Open when the local player walks into the shop zone, close when they leave (or hit Exit). Looked
	-- up rather than waited on: the zone lives in the place file, and waiting forever on one that was
	-- never authored would silently strand the rest of this function.
	local zonePart = workspace:WaitForChild("Core"):WaitForChild("Zones"):FindFirstChild(ZONE_NAME)
	if zonePart then
		local zone = Zone.new(zonePart)
		zone.localPlayerEntered:Connect(function()
			UIController:OpenFrame(self.UI.Holder)
		end)
		zone.localPlayerExited:Connect(function()
			UIController:CloseFrame(self.UI.Holder)
		end)
	else
		warn(`No Core.Zones.{ZONE_NAME} in the place file, the Grill & Stand Shop can't be walked into`)
	end

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

		PlayerDataController:ListenForChange("GrillStandShop", function()
			self:_refreshRows()
		end)
	end)
end

return GrillStandShopController
