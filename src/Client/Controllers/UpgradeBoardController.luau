-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local BaseUnlocks = require(Shared.Config.BaseUnlocks)

-- Controllers
local NotificationController = require(script.Parent.NotificationController)
local PlayerDataController
local UIController
local ShopController

-- Assets
local UI = ReplicatedStorage.Assets.UI

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- Drives the owner's upgrade board: paints each unlock group's next level, fires the purchase, raises the owner-only nameplate icon, and nudges when a level first becomes affordable.
local UpgradeBoardController = {
	PurchaseUnlockUpgradeEvent = Network.Event("PurchaseUnlockUpgrade"),

	_baseCleaner = Trove.new(), -- board clone, button bindings and data listeners for the current base

	-- [unlockId] = the level already announced, so crossing the same threshold twice stays quiet
	_notifiedLevels = {},

	_sections = {}, -- { frame, unlock } per section of the board currently mounted; empty off a base
}

-- The board's ScreenGui. In PlayerGui adorned back onto the world board, which makes buttons clickable.
local function getScreenGui(): ScreenGui
	local screenGui = PlayerGui:FindFirstChild("UpgradeBoard")
	if screenGui == nil then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "UpgradeBoard"
		screenGui.ResetOnSpawn = false
		screenGui.Parent = PlayerGui
	end

	return screenGui
end

-- Paints one section from player data, hiding the buy buttons once the group is maxed.
function UpgradeBoardController:_refreshSection(frame: Frame, unlock: BaseUnlocks.Unlock)
	local unlocks = PlayerDataController:GetKey("Unlocks") or {}
	local level = unlocks[unlock.Id] or 0
	-- Gate on Limit, not #Costs: RollingStands keeps costs dense past its cap
	local isMax = level >= unlock.Limit

	-- A count group reads as the number; a stat group reads as what the stat becomes ("1.7s")
	local formatLevel = unlock.FormatLevel or tostring

	frame.Title.Text = `{unlock.Name} ({formatLevel(level)})`
	frame.Level.Text = if isMax
		then `Max ({formatLevel(unlock.Limit)})`
		else `{formatLevel(level)}>{formatLevel(level + 1)}`
	frame.Buttons.Visible = not isMax

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
function UpgradeBoardController:_bindSection(frame: Frame, unlock: BaseUnlocks.Unlock)
	local currencyBinding = UIController:BindButtonClick(frame.Buttons.CurrencyPurchase, function()
		-- The server rejects it too; the board stays priced through the run so they see what's waiting
		if unlock.TutorialLocked and not PlayerDataController:GetKey("TutorialCompleted") then
			NotificationController:NotifyNormal({
				Text = "Finish the tutorial first!",
				Effect = "Error",
				Duration = 3,
				Sound = "Reject",
			})
			return
		end

		self.PurchaseUnlockUpgradeEvent:FireServer(unlock.Id)
	end, true)
	self._baseCleaner:Add(currencyBinding.Disconnect)

	local robuxBinding = UIController:BindButtonClick(frame.Buttons.RobuxPurchase, function()
		self:_onRobuxPurchase(unlock.Id)
	end, true)
	self._baseCleaner:Add(robuxBinding.Disconnect)
end

-- Buys the next level with Robux. The product is read off the level they're on, as the price is.
function UpgradeBoardController:_onRobuxPurchase(unlockId: string)
	local unlock = BaseUnlocks.GetUnlockFromId(unlockId)
	local level = (PlayerDataController:GetKey("Unlocks") or {})[unlockId] or 0

	-- The button hides on a level with no product, so this only catches a press that raced the refresh
	if not unlock.RobuxProductIds or not unlock.RobuxProductIds[level + 1] then
		return
	end

	ShopController:PromptProductPurchaseFromId(BaseUnlocks.GetProductStringId(unlockId, level + 1))
end

-- Warms the price cache for every product level, then repaints. Walks the config, so a new section is covered.
function UpgradeBoardController:_cacheRobuxPrices()
	for _, unlock in BaseUnlocks.Data do
		if not unlock.RobuxProductIds then
			continue
		end

		for level in unlock.RobuxProductIds do
			ShopController:GetPrice(BaseUnlocks.GetProductStringId(unlock.Id, level))
		end
	end

	self:_refreshSections()
end

-- Repaints every section of the mounted board, which only ever sits on the local player's own base.
function UpgradeBoardController:_refreshSections()
	for _, section in self._sections do
		self:_refreshSection(section.frame, section.unlock)
	end
end

-- Announces when a balance first covers the next level. Latched per level, and walks the config so a group with no section is still announced.
function UpgradeBoardController:_notifyAffordableUpgrades(currency: number)
	local unlocks = PlayerDataController:GetKey("Unlocks") or {}

	for _, unlock in BaseUnlocks.Data do
		local level = unlocks[unlock.Id] or 0
		local nextLevel = level + 1

		-- Same gate as the board and the server: past Limit, or the last cost, is fully upgraded
		local cost = unlock.Costs[nextLevel]
		if nextLevel > unlock.Limit or not cost then
			continue
		end

		if currency < cost or self._notifiedLevels[unlock.Id] == nextLevel then
			continue
		end

		self._notifiedLevels[unlock.Id] = nextLevel

		NotificationController:NotifyNormal({
			Text = `{unlock.Name} upgrade available for ${GuiUtil.ConvertNumberWithSuffix(cost)}!`,
			Duration = 4,
			Sound = "CanPurchase",
			Effect = "Success",
		})
	end
end

-- Rebuilds the board on the local player's base. Owner-only, since Unlocks only replicate to them.
function UpgradeBoardController:_setupBase()
	self._baseCleaner:Clean()

	-- The clean above destroyed the frames these point at, so they're dropped with them
	self._sections = {}

	local baseId = LocalPlayer:GetAttribute("BaseId")
	if not baseId then
		return
	end

	local base = workspace.Base[baseId]

	-- The owner-only nameplate marker. Waited on, since the plate is made as the base is claimed
	task.spawn(function()
		local baseIcon = base.BaseAttachment:WaitForChild("BaseUI").BaseIcon
		baseIcon.Visible = true

		self._baseCleaner:Add(function()
			baseIcon.Visible = false
		end)
	end)

	local board = base.Upgrades.Board

	local clone = UI.MainUpgradesUI:Clone()
	clone.Adornee = board
	clone.Active = true
	clone.Parent = getScreenGui()
	self._baseCleaner:Add(clone)

	self._sections = {
		{ frame = clone.IngredientRolls, unlock = BaseUnlocks.GetUnlockFromId("RollingStands") },
		{ frame = clone.RollSpeed, unlock = BaseUnlocks.GetUnlockFromId("RollSpeed") },
	}

	for _, section in self._sections do
		self:_bindSection(section.frame, section.unlock)
	end

	-- GetKey awaits the replica, so keep the first refresh and the listener off the setup thread
	task.spawn(function()
		self:_refreshSections()

		self._baseCleaner:Add(PlayerDataController:ListenForChange("Unlocks", function()
			self:_refreshSections()
		end))
	end)
end

function UpgradeBoardController:OnInit()
	PlayerDataController = require(script.Parent.PlayerDataController)
	UIController = require(script.Parent.UIController)
	ShopController = require(script.Parent.ShopController)
end

function UpgradeBoardController:OnStart()
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:_setupBase()
	end)

	-- Sweep once, since BaseId may already be set by the time we start
	self:_setupBase()

	task.spawn(function()
		self:_cacheRobuxPrices()
	end)

	-- Off the base cleaner, since the unlocks are the player's not the base's. Gains only, or a purchase would stack on the server's own toast
	task.spawn(function()
		PlayerDataController:ListenForChange("Currency", function(new, old)
			if new <= old then
				return
			end

			self:_notifyAffordableUpgrades(new)
		end)
	end)
end

return UpgradeBoardController
