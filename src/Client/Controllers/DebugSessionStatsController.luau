-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)
local Ingredients = require(Shared.Config.Ingredients)

-- Controllers
local UIController = require(script.Parent.UIController)
local PlayerDataController = require(script.Parent.PlayerDataController)
local IngredientRollingController = require(script.Parent.IngredientRollingController)

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

local PANEL_WIDTH = 300
local ROW_HEIGHT = 22
local BREAKDOWN_HEIGHT = 150

--[[
	A read-out of what the current play session has come to: how long it's run, how many times the lever
	has been pulled, and what came off the stands. Session only -- everything here is in memory and back
	to zero on the next join.

	Cooking and selling are the odd ones out: they're already counted for life in player data, so rather
	than watch for them the session figure is read as how far those totals have moved since the join.

	Opened with `sessionStats` (`ss`) in the command bar. The panel isn't built until then, and every
	repaint bails while it's down, so a client that never opens it pays for four connections and a
	counter each.
]]
local DebugSessionStatsController = {
	_sessionStart = 0,
	_rolls = 0,
	_bought = {}, -- [ingredientId] = how many were bought this session
	_boughtTotal = 0,
	_buxSpent = 0,

	-- Where the lifetime cook/sell counters stood at join, so the session figure is the difference.
	_cookedBaseline = 0,
	_soldBaseline = 0,
	_cooked = 0,
	_sold = 0,

	_open = false,
	_panel = nil,
	_rows = {}, -- the fixed stat lines, [name] = the TextLabel holding its value
	_separator = nil,
	_breakdown = nil,
	_breakdownCleaner = Trove.new(), -- holds each repaint's per-ingredient rows
}

-- One line of the panel: a name on the left, its value on the right. Hands back the value label to
-- write into, and the row itself so a rebuilt list can throw it away.
function DebugSessionStatsController:_addRow(parent: Instance, name: string, layoutOrder: number): (TextLabel, Frame)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.LayoutOrder = layoutOrder
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0.6, 1)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(185, 185, 195)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 14
	label.Text = name
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.BackgroundTransparency = 1
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.fromScale(1, 0)
	value.Size = UDim2.fromScale(0.4, 1)
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.TextColor3 = Color3.fromRGB(255, 255, 255)
	value.Font = Enum.Font.GothamBold
	value.TextSize = 14
	value.Text = "-"
	value.Parent = row

	return value, row
end

-- Builds the panel, on the first toggle rather than at start-up.
function DebugSessionStatsController:_build()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DebugSessionStats"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 10
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = PlayerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -16, 0, 100)
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = screenGui
	self._panel = panel

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel

	local panelPadding = Instance.new("UIPadding")
	panelPadding.PaddingTop = UDim.new(0, 12)
	panelPadding.PaddingBottom = UDim.new(0, 12)
	panelPadding.PaddingLeft = UDim.new(0, 14)
	panelPadding.PaddingRight = UDim.new(0, 14)
	panelPadding.Parent = panel

	local panelLayout = Instance.new("UIListLayout")
	panelLayout.Padding = UDim.new(0, 2)
	panelLayout.SortOrder = Enum.SortOrder.LayoutOrder
	panelLayout.Parent = panel

	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 24)
	header.LayoutOrder = 1
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.TextColor3 = Color3.fromRGB(255, 220, 120)
	header.Font = Enum.Font.GothamBold
	header.TextSize = 17
	header.Text = "SESSION"
	header.Parent = panel

	self._rows.Time = self:_addRow(panel, "Time played", 2)
	self._rows.Rolls = self:_addRow(panel, "Rolls", 3)
	self._rows.Ingredients = self:_addRow(panel, "Ingredients", 4)
	self._rows.Cooked = self:_addRow(panel, "Skewers cooked", 5)
	self._rows.Sold = self:_addRow(panel, "Skewers sold", 6)

	-- A transparent band holding the rule, so the line sits clear of the rows either side of it.
	local separator = Instance.new("Frame")
	separator.BackgroundTransparency = 1
	separator.Size = UDim2.new(1, 0, 0, 11)
	separator.LayoutOrder = 7
	separator.Visible = false
	separator.Parent = panel
	self._separator = separator

	local line = Instance.new("Frame")
	line.AnchorPoint = Vector2.new(0, 0.5)
	line.Position = UDim2.fromScale(0, 0.5)
	line.Size = UDim2.new(1, 0, 0, 1)
	line.BackgroundColor3 = Color3.fromRGB(70, 70, 82)
	line.BorderSizePixel = 0
	line.Parent = separator

	local breakdown = Instance.new("ScrollingFrame")
	breakdown.Name = "Breakdown"
	breakdown.BackgroundTransparency = 1
	breakdown.BorderSizePixel = 0
	breakdown.Size = UDim2.new(1, 0, 0, 0)
	breakdown.LayoutOrder = 8
	breakdown.CanvasSize = UDim2.new()
	breakdown.AutomaticCanvasSize = Enum.AutomaticSize.Y
	breakdown.ScrollBarThickness = 4
	breakdown.Parent = panel
	self._breakdown = breakdown

	local breakdownLayout = Instance.new("UIListLayout")
	breakdownLayout.SortOrder = Enum.SortOrder.LayoutOrder
	breakdownLayout.Parent = breakdown
end

-- The clock line on its own, since it's the one value that moves without anything firing.
function DebugSessionStatsController:_refreshTime()
	self._rows.Time.Text = GuiUtil.ConvertSecondsToHHMMSS(os.clock() - self._sessionStart)
end

-- Repaints every line from the current counters. Cheap enough to redo the breakdown wholesale rather
-- than diff it, and it does nothing at all while the panel is down.
function DebugSessionStatsController:_refresh()
	if not self._open then
		return
	end

	self:_refreshTime()
	self._rows.Rolls.Text = GuiUtil.ConvertNumberWithCommas(self._rolls)
	self._rows.Ingredients.Text = `{self._boughtTotal}  (${GuiUtil.ConvertNumberWithCommas(self._buxSpent)})`
	self._rows.Cooked.Text = GuiUtil.ConvertNumberWithCommas(self._cooked)
	self._rows.Sold.Text = GuiUtil.ConvertNumberWithCommas(self._sold)

	self._breakdownCleaner:Clean()

	local sorted = {}
	for ingredientId, count in self._bought do
		table.insert(sorted, { Id = ingredientId, Count = count })
	end

	-- Most-bought first, ties settled by id, so the list doesn't reshuffle under the cursor.
	table.sort(sorted, function(a, b)
		if a.Count ~= b.Count then
			return a.Count > b.Count
		end

		return a.Id < b.Id
	end)

	for index, entry in sorted do
		local ingredient = Ingredients.GetIngredientFromId(entry.Id)
		local value, row = self:_addRow(self._breakdown, ingredient.Name, index)
		value.Text = `x{entry.Count}`
		value.TextColor3 = ingredient.Tier.TextColor
		self._breakdownCleaner:Add(row)
	end

	-- Grows with the list up to a cap, so nothing has been bought yet reads as no list at all rather
	-- than a panel of empty space.
	self._separator.Visible = #sorted > 0
	self._breakdown.Size = UDim2.new(1, 0, 0, math.min(#sorted * ROW_HEIGHT, BREAKDOWN_HEIGHT))
end

-- Shows or hides the panel, building it the first time, and reports which way it went so the command
-- can say so.
function DebugSessionStatsController:Toggle(): boolean
	if not self._panel then
		self:_build()
	end

	self._open = not self._open

	if self._open then
		self:_refresh()
		UIController:OpenFrame(self._panel, true)
	else
		UIController:CloseFrame(self._panel)
	end

	return self._open
end

function DebugSessionStatsController:OnStart()
	-- Counting runs from the join rather than from the first toggle, so opening the panel part way
	-- through a session still reports the whole of it.
	self._sessionStart = os.clock()

	IngredientRollingController.OnRollPerformed:Connect(function()
		self._rolls += 1
		self:_refresh()
	end)

	IngredientRollingController.OnIngredientBought:Connect(function(ingredientId: string, price: number)
		self._bought[ingredientId] = (self._bought[ingredientId] or 0) + 1
		self._boughtTotal += 1
		self._buxSpent += price
		self:_refresh()
	end)

	-- Off the loader thread: both reads await the replica.
	task.spawn(function()
		self._cookedBaseline = PlayerDataController:GetKey("SkewersCooked")
		self._soldBaseline = PlayerDataController:GetKey("SkewersSold")

		PlayerDataController:ListenForChange("SkewersCooked", function(newValue: number)
			self._cooked = newValue - self._cookedBaseline
			self:_refresh()
		end)

		PlayerDataController:ListenForChange("SkewersSold", function(newValue: number)
			self._sold = newValue - self._soldBaseline
			self:_refresh()
		end)
	end)

	-- Everything else repaints off its own signal; the clock is the only line that has to be chased,
	-- and a second is all a HH:MM:SS readout resolves.
	task.spawn(function()
		while true do
			task.wait(1)

			if self._open then
				self:_refreshTime()
			end
		end
	end)
end

return DebugSessionStatsController
