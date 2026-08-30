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

-- The button goes inactive this close to the window's end, rather than selling a stock the free rollover
-- was about to hand over anyway.
local RESTOCK_MIN_TIME_LEFT = 15

-- The colour the countdown is shown in on the shop's restock title.
local RESTOCK_TIME_COLOR = "#55ff00"

-- The zone out in the world that opens the shop, under workspace.Core.Zones.
local ZONE_NAME = "GrillStandShop"

-- Sold off a display under workspace.Displays rather than a shop row: it isn't restockable, so it's never
-- stocked and can't be bought with currency.
local GOLDEN_GRILL_ID = "GoldenGrill"
local GOLDEN_GRILL_DISPLAY = "GoldenGrillDisplay"
local GOLDEN_GRILL_PROMPT_HOLD = 0.3
local GOLDEN_GRILL_PROMPT_DISTANCE = 10

-- Each category's Holder.CategoryButtons child, in tab order. A mapping rather than a name match, since
-- the authored button names and the Config.Structures categories don't read the same.
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
	_locked = false, -- while set, walking into the zone doesn't open the shop
	_uiCleaner = Trove.new(),
}

-- Holds the shop shut, zone and all. Set by the tutorial, whose store trip walks the player past this
-- zone -- popping open would cover the banner and sell them a second griller before they've placed one.
-- @param locked: true to hold it shut, false to hand it back
function GrillStandShopController:SetLocked(locked: boolean)
	self._locked = locked

	-- Closes anything already open, so the hold covers the shop as it stands rather than only later walk-ins.
	if locked and self.UI then
		UIController:CloseFrame(self.UI.Holder)
	end
end

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

-- How many the player can still buy this window: shared stock minus their own purchases. Bought only
-- counts while its Seed matches the current window, so a re-roll makes the full stock available again.
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

-- Requests a purchase. The server validates stock, currency and the grant; feedback arrives over
-- StructurePurchaseResultEvent and the replica's Bought updating.
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

-- The structure whose row is expanded, or nil. The buy buttons act on it, so anything asking what a press
-- would buy reads it here.
function GrillStandShopController:GetSelectedStructureId(): string?
	return self._selectedStructureId
end

-- Syncs the shared ButtonChoices buttons to the selected structure. Robux is only offered once it has a
-- real dev product, and currency-buy is disabled when this window's stock is gone.
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

-- Writes the Golden Grill's price onto its display prompt. The prompt goes up before the lookup lands, so
-- this runs again once _cacheRobuxPrices has it -- "-" until then, like every other Robux label.
function GrillStandShopController:_refreshGoldenGrillPrompt()
	if not self._goldenGrillPrompt then
		return
	end

	self._goldenGrillPrompt.ObjectText = `{GuiUtil.ROBUX_ICON}{ShopController:GetCachedPrice(GOLDEN_GRILL_ID) or "-"}`
end

-- Puts the buy prompt on the Golden Grill's world display. Straight to the dev product -- no stock and no
-- currency price behind it, so none of the shop's row gating applies.
function GrillStandShopController:_setupGoldenGrillDisplay()
	-- Authored in the place file, so looked up rather than indexed. A missing one leaves the Golden Grill
	-- buyable only from the shop card.
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

-- Collapses the open ButtonChoices frame, hiding it only once its UIScale spring lands so it shrinks away
-- instead of blinking out. `instant` skips that where nothing is on screen to watch it.
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

-- Expands the shared ButtonChoices frame under the pressed structure -- its LayoutOrder is that row's odd
-- order + 1, so the list lands it directly below. Pressing the same structure again collapses it.
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

-- Switches category tabs. Every row is built once into one scrolling frame and shown or hidden from here,
-- since the layout skips invisible children -- so a switch costs nothing and the odd/even LayoutOrder gap
-- survives it. Any open selection is dropped first, or the buy buttons would act on a hidden row.
function GrillStandShopController:_selectCategory(category: string)
	-- A no-op rather than a re-run: the rows wouldn't change, and the clear below would shut an open row's
	-- buy buttons for no visible reason.
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

-- Binds each category tab to what it shows. Looked up rather than indexed, so a button missing from the
-- place file can't take the rest of the tabs down with it.
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

-- Clones one row per restockable structure into the single scrolling frame (_selectCategory decides which
-- show) and binds the shared buy buttons. Rows take odd LayoutOrders so ButtonChoices slots into the even
-- gap below the selected one. Stock text is filled by _refreshRows.
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

		-- Straight from the config rather than composed like the stick shop's -- a structure has no
		-- capacity or boost figure to build a line from. RichText is on, so authored <font> tags render.
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

-- Decides whether the buy-a-restock button is offered. No price is written -- the button carries its own
-- art and has no label to put one in.
function GrillStandShopController:_refreshRestockButton()
	local button = self._restockButton
	if not button then
		return
	end

	button.Active = self:GetTimeLeft() > RESTOCK_MIN_TIME_LEFT
end

-- Writes the window's time left into the shop title, colouring just the countdown. Minutes are always
-- shown, so the final stretch reads "0m 9s" rather than dropping the unit.
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

	-- A successful attempt is announced, so anything waiting on the structure landing has a signal rather
	-- than polling the player's data.
	self.StructurePurchaseResultEvent:OnClientEvent(function(success: boolean, structureId: string)
		if success then
			self.OnStructurePurchased:Fire(structureId)
		end
	end)

	-- Looked up rather than waited on: waiting forever on a zone that was never authored would silently
	-- strand the rest of this function.
	local zonePart = workspace:WaitForChild("Core"):WaitForChild("Zones"):FindFirstChild(ZONE_NAME)
	if zonePart then
		local zone = Zone.new(zonePart)
		zone.localPlayerEntered:Connect(function()
			if self._locked then
				return
			end

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
