-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)
local BaseUnlocks = require(Shared.Config.BaseUnlocks)

-- Controllers
local Controllers = script.Parent.Parent
local UIController = require(Controllers.UIController)
local ShopController = require(Controllers.ShopController)

-- Assets
local UI = ReplicatedStorage.Assets.UI

--
local LocalPlayer = Players.LocalPlayer

-- Required lazily to break the cycle: UpgradeBoardController requires this class.
local UpgradeBoardController

-- One base's upgrade board: paints each unlock group off the levels the server publishes onto the base, and offers the buy buttons to its owner alone.

-- The boards' ScreenGui. In PlayerGui adorned back onto the world board, which makes buttons clickable.
local function getScreenGui(): ScreenGui
	local playerGui = LocalPlayer.PlayerGui
	local screenGui = playerGui:FindFirstChild("UpgradeBoard")

	if screenGui == nil then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "UpgradeBoard"
		screenGui.ResetOnSpawn = false
		screenGui.Parent = playerGui
	end

	return screenGui
end

--
local UpgradeBoard = {}
UpgradeBoard.__index = UpgradeBoard

function UpgradeBoard.new(baseModel: Model, board: BasePart)
	local cleaner = Trove.new()

	local self = setmetatable({
		_baseModel = baseModel,
		_board = board,

		-- The mounted UI, up only while the base has an owner
		_clone = nil,

		_sections = {}, -- { frame, unlock } per section of the board currently mounted

		_mountCleaner = cleaner:Construct(Trove), -- the clone and its button bindings

		_cleaner = cleaner,
	}, UpgradeBoard)

	-- Per attribute rather than the model's own signal, so anything else stamped on the base can't churn the repaint
	for _, unlock in BaseUnlocks.Data do
		cleaner:Connect(baseModel:GetAttributeChangedSignal(BaseUnlocks.GetLevelAttribute(unlock.Id)), function()
			self:Refresh()
		end)
	end

	self:Refresh()

	return self
end

-- The owner's published levels, or nil on a base nobody owns -- the server clears them as it's released.
function UpgradeBoard:_levels(): { [string]: number }?
	local levels = {}

	for _, unlock in BaseUnlocks.Data do
		local level = self._baseModel:GetAttribute(BaseUnlocks.GetLevelAttribute(unlock.Id))
		if level == nil then
			return nil
		end

		levels[unlock.Id] = level
	end

	return levels
end

-- Paints one section at the level the base publishes, hiding the buy buttons off the owner's own base and once the group is maxed.
function UpgradeBoard:_refreshSection(frame: Frame, unlock: BaseUnlocks.Unlock, level: number, owned: boolean)
	-- Gate on Limit, not #Costs: RollingStands keeps costs dense past its cap
	local isMax = level >= unlock.Limit

	-- A count group reads as the number; a stat group reads as what the stat becomes ("1.7s")
	local formatLevel = unlock.FormatLevel or tostring

	frame.Title.Text = `{unlock.Name} ({formatLevel(level)})`
	frame.Level.Text = if isMax
		then `Max ({formatLevel(unlock.Limit)})`
		else `{formatLevel(level)}>{formatLevel(level + 1)}`

	-- Someone else's stall is display only. A hidden frame can't be clicked, so the bindings stay wired
	frame.Buttons.Visible = owned and not isMax

	if isMax then
		return
	end

	-- Matches the server's Costs[currentLevel + 1] next-level cost
	frame.Buttons.CurrencyPurchase.Title.Text = `${GuiUtil.ConvertNumberWithSuffix(unlock.Costs[level + 1])}`

	-- Only on a level with a dev product, so a step without one shows the currency button alone
	local productId = unlock.RobuxProductIds and unlock.RobuxProductIds[level + 1]
	frame.Buttons.RobuxPurchase.Visible = productId ~= nil

	if productId then
		-- "-" until the MarketplaceService lookup lands, matching ShopController:GetPrice
		local stringId = BaseUnlocks.GetProductStringId(unlock.Id, level + 1)
		frame.Buttons.RobuxPurchase.Title.Text = `{GuiUtil.ROBUX_ICON}{ShopController:GetCachedPrice(stringId) or "-"}`
	end
end

-- Wires a section's buy buttons once; the server decides the next level and grants it either way.
function UpgradeBoard:_bindSection(frame: Frame, unlock: BaseUnlocks.Unlock)
	local currencyBinding = UIController:BindButtonClick(frame.Buttons.CurrencyPurchase, function()
		UpgradeBoardController = UpgradeBoardController or require(script.Parent)
		UpgradeBoardController:RequestPurchase(unlock.Id)
	end, true)
	self._mountCleaner:Add(currencyBinding.Disconnect)

	local robuxBinding = UIController:BindButtonClick(frame.Buttons.RobuxPurchase, function()
		UpgradeBoardController = UpgradeBoardController or require(script.Parent)
		UpgradeBoardController:RequestRobuxPurchase(unlock.Id)
	end, true)
	self._mountCleaner:Add(robuxBinding.Disconnect)
end

-- Puts the board up on an owned base and paints it, and takes it down once the base is released. Public -- the owner changing repaints every board.
function UpgradeBoard:Refresh()
	local levels = self:_levels()

	if not levels then
		self._mountCleaner:Clean()
		self._clone = nil
		self._sections = {}

		return
	end

	if not self._clone then
		local clone = UI.MainUpgradesUI:Clone()
		clone.Adornee = self._board
		clone.Active = true
		clone.Parent = getScreenGui()
		self._mountCleaner:Add(clone)

		self._clone = clone
		self._sections = {
			{ frame = clone.IngredientRolls, unlock = BaseUnlocks.GetUnlockFromId("RollingStands") },
			{ frame = clone.RollSpeed, unlock = BaseUnlocks.GetUnlockFromId("RollSpeed") },
		}

		for _, section in self._sections do
			self:_bindSection(section.frame, section.unlock)
		end
	end

	local owned = self._baseModel.Name == LocalPlayer:GetAttribute("BaseId")

	for _, section in self._sections do
		self:_refreshSection(section.frame, section.unlock, levels[section.unlock.Id], owned)
	end
end

function UpgradeBoard:Destroy()
	self._cleaner:Destroy()
end

return UpgradeBoard
