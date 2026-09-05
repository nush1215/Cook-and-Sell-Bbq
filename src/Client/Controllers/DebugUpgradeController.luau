-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local BaseUnlocks = require(Shared.Config.BaseUnlocks)
-- local Sauces = require(Shared.Config.Sauces)

-- Controllers
local PlayerDataController
local UIController

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

local ENABLED = false -- Flip to false to hide the debug panel entirely

-- Debug panel firing the real upgrade remotes. Self-contained and server-free, so it's safe to delete wholesale.
local DebugUpgradeController = {
	PurchaseUnlockUpgradeEvent = Network.Event("PurchaseUnlockUpgrade"),

	-- No stick remote, and there shouldn't be one: it would hand out any stick to anyone who found the identifier. The sauce remotes went with the dispenser system, since an unhandled Network.Event stalls the load
	--[==[
	FillSauceDispenserEvent = Network.Event("FillSauceDispenser"),
	GiveSauceEvent = Network.Event("GiveSauce"),
	]==]

	_open = false,
	_panel = nil,
	_content = nil,
	_currencyLabel = nil,
	_rowCleaner = Trove.new(), -- holds each rebuild's rows and their button bindings
}

-- Groups a number's digits with commas: 50000000 -> "50,000,000".
local function formatNumber(n: number): string
	local text = tostring(n)
	local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

-- Refreshes just the currency line, so an income tick doesn't tear down the rows mid-hover.
function DebugUpgradeController:_updateCurrency()
	local currency = PlayerDataController:GetKey("Currency") or 0
	self._currencyLabel.Text = `Currency: ${formatNumber(currency)}`
end

-- Builds one row. Disabled, the button reads "MAX" and does nothing; enabledText overrides its label.
function DebugUpgradeController:_addRow(labelText: string, enabled: boolean, onClick: () -> (), enabledText: string?)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 44)
	row.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	row.BorderSizePixel = 0

	local rowCorner = Instance.new("UICorner")
	rowCorner.CornerRadius = UDim.new(0, 6)
	rowCorner.Parent = row

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -104, 1, 0)
	label.Position = UDim2.fromOffset(10, 0)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(235, 235, 240)
	label.TextScaled = true
	label.Font = Enum.Font.GothamMedium
	label.Text = labelText
	label.Parent = row

	local labelPadding = Instance.new("UIPadding")
	labelPadding.PaddingTop = UDim.new(0, 8)
	labelPadding.PaddingBottom = UDim.new(0, 8)
	labelPadding.Parent = label

	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -8, 0.5, 0)
	button.Size = UDim2.fromOffset(84, 30)
	button.BackgroundColor3 = if enabled then Color3.fromRGB(80, 170, 90) else Color3.fromRGB(70, 70, 80)
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 15
	button.AutoButtonColor = false
	button.Text = if enabled then (enabledText or "Upgrade") else "MAX"
	button.Parent = row

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 6)
	buttonCorner.Parent = button

	row.Parent = self._content
	self._rowCleaner:Add(row)

	if enabled then
		local binding = UIController:BindButtonClick(button, onClick, true)
		self._rowCleaner:Add(binding.Disconnect)
	end
end

-- Rebuilds every row from current player data -- cheap enough for a debug panel not to diff levels.
function DebugUpgradeController:_rebuild()
	self._rowCleaner:Clean()
	self:_updateCurrency()

	local unlocks = PlayerDataController:GetKey("Unlocks")

	-- Base unlocks: each group buys its next slot. Past the last cost is fully upgraded
	for _, unlock in BaseUnlocks.Data do
		local level = unlocks[unlock.Id] or 0
		local maxLevel = #unlock.Costs
		local nextCost = unlock.Costs[level + 1]

		local labelText = if nextCost
			then `{unlock.Id}  [{level}/{maxLevel}]  -  ${formatNumber(nextCost)}`
			else `{unlock.Id}  [{level}/{maxLevel}]`

		self:_addRow(labelText, nextCost ~= nil, function()
			self.PurchaseUnlockUpgradeEvent:FireServer(unlock.Id)
		end)
	end

	-- Dormant with the dispenser system: a free fill per sauce, past the bottle the real path uses
	--[==[
	local dispensers = PlayerDataController:GetKey("SauceDispensers")
	local dispenserLevel = unlocks.SauceDispenser or 0
	for slotNumber = 1, dispenserLevel do
		local slotId = tostring(slotNumber)
		local record = dispensers[slotId]
		if not record then
			continue
		end

		for _, sauce in Sauces.GetAllSauces() do
			local loaded = if record.Sauce == sauce.Id then `  <- x{record.Remaining} left` else ""

			self:_addRow(`Sauce #{slotId}  {sauce.Name}  [{sauce.Multiplier}x]{loaded}`, true, function()
				self.FillSauceDispenserEvent:FireServer(slotId, sauce.Id)
			end, "Fill")
		end
	end
	]==]

	-- Dormant with the dispenser system: one row per flavour, granting a bottle. Always enabled, since they stack
	--[==[
	local sauces = PlayerDataController:GetKey("Sauces")
	for _, sauce in Sauces.GetAllSauces() do
		local owned = sauces[sauce.Id] or 0

		self:_addRow(`{sauce.Name} Bottle  [owned: {owned}]`, true, function()
			self.GiveSauceEvent:FireServer(sauce.Id)
		end, "Give")
	end
	]==]
end

function DebugUpgradeController:OnInit()
	PlayerDataController = require(script.Parent.PlayerDataController)
	UIController = require(script.Parent.UIController)
end

function DebugUpgradeController:OnStart()
	if not ENABLED then
		return
	end

	-- Static shell, built synchronously: a toggle button and the panel it opens
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DebugUpgrades"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = PlayerGui

	local toggle = Instance.new("TextButton")
	toggle.Name = "Toggle"
	toggle.AnchorPoint = Vector2.new(0, 0.5)
	toggle.Position = UDim2.new(0, 16, 0.5, 0)
	toggle.Size = UDim2.fromOffset(120, 42)
	toggle.BackgroundColor3 = Color3.fromRGB(60, 120, 200)
	toggle.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggle.Font = Enum.Font.GothamBold
	toggle.TextSize = 17
	toggle.Text = "Upgrades"
	toggle.Parent = screenGui

	local toggleCorner = Instance.new("UICorner")
	toggleCorner.CornerRadius = UDim.new(0, 8)
	toggleCorner.Parent = toggle

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0, 150, 0.5, 0)
	panel.Size = UDim2.fromOffset(340, 380)
	panel.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = screenGui

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel

	local panelPadding = Instance.new("UIPadding")
	panelPadding.PaddingTop = UDim.new(0, 12)
	panelPadding.PaddingBottom = UDim.new(0, 12)
	panelPadding.PaddingLeft = UDim.new(0, 12)
	panelPadding.PaddingRight = UDim.new(0, 12)
	panelPadding.Parent = panel

	local header = Instance.new("TextLabel")
	header.Name = "Currency"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 28)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.TextColor3 = Color3.fromRGB(255, 220, 120)
	header.Font = Enum.Font.GothamBold
	header.TextSize = 18
	header.Text = "Currency: -"
	header.Parent = panel
	self._currencyLabel = header

	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Position = UDim2.fromOffset(0, 36)
	content.Size = UDim2.new(1, 0, 1, -36)
	content.CanvasSize = UDim2.new()
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.ScrollBarThickness = 5
	content.Parent = panel
	self._content = content
	self._panel = panel

	local contentLayout = Instance.new("UIListLayout")
	contentLayout.Padding = UDim.new(0, 6)
	contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
	contentLayout.Parent = content

	UIController:BindButtonClick(toggle, function()
		self._open = not self._open
		if self._open then
			UIController:OpenFrame(panel, true)
		else
			UIController:CloseFrame(panel)
		end
	end, true)

	-- Data reads await the replica, so keep the binding and first build off the loader thread
	task.spawn(function()
		self:_rebuild()

		PlayerDataController:ListenForChange("Unlocks", function()
			self:_rebuild()
		end)

		--[==[
		PlayerDataController:ListenForChange("SauceDispensers", function()
			self:_rebuild()
		end)

		PlayerDataController:ListenForChange("Sauces", function()
			self:_rebuild()
		end)
		]==]

		PlayerDataController:ListenForChange("Sticks", function()
			self:_rebuild()
		end)

		PlayerDataController:ListenForChange("Currency", function()
			self:_updateCurrency()
		end)
	end)
end

return DebugUpgradeController
