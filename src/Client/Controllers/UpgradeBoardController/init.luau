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
local ShopController

-- Modules
local UpgradeBoard = require(script.UpgradeBoard)

--
local LocalPlayer = Players.LocalPlayer

-- How long a streamed-in base gets to finish replicating the folder its board sits in.
local CHILD_TIMEOUT = 10

-- Drives every base's upgrade board -- one UpgradeBoard per base, since a visitor sees the owner's levels too. The purchase is the owner's alone, and the nudge when a level first becomes affordable is theirs.

--
local UpgradeBoardController = {
	PurchaseUnlockUpgradeEvent = Network.Event("PurchaseUnlockUpgrade"),

	_boards = {}, -- [model: Model] = UpgradeBoard
	_cleaner = Trove.new(),

	_ownerCleaner = Trove.new(), -- the nameplate icon on the base the local player owns

	-- [unlockId] = the level already announced, so crossing the same threshold twice stays quiet
	_notifiedLevels = {},
}

-- Asks the server to buy the next level with currency; the level and the price aren't the client's to send.
function UpgradeBoardController:RequestPurchase(unlockId: string)
	local unlock = BaseUnlocks.GetUnlockFromId(unlockId)

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

	self.PurchaseUnlockUpgradeEvent:FireServer(unlockId)
end

-- Buys the next level with Robux. The product is read off the level they're on, as the price is.
function UpgradeBoardController:RequestRobuxPurchase(unlockId: string)
	local unlock = BaseUnlocks.GetUnlockFromId(unlockId)
	local level = (PlayerDataController:GetKey("Unlocks") or {})[unlockId] or 0

	-- The button hides on a level with no product, so this only catches a press that raced the refresh
	if not unlock.RobuxProductIds or not unlock.RobuxProductIds[level + 1] then
		return
	end

	ShopController:PromptProductPurchaseFromId(BaseUnlocks.GetProductStringId(unlockId, level + 1))
end

-- Repaints every base's board. Cheap, and each one follows the local player's base as well as its own levels.
function UpgradeBoardController:RefreshBoards()
	for _, board in self._boards do
		board:Refresh()
	end
end

-- Builds a base's board once its upgrades folder has replicated; the wait lives here, and each board follows its own levels.
function UpgradeBoardController:_setupBase(baseModel: Model)
	local upgrades = baseModel:WaitForChild("Upgrades", CHILD_TIMEOUT)
	local board = upgrades and upgrades:WaitForChild("Board", CHILD_TIMEOUT)

	if not board then
		warn(`[UpgradeBoard] {baseModel.Name}'s board never replicated, its upgrades won't render`)
		return
	end

	-- Waiting above yields, so the base can have streamed back out in the meantime
	if not baseModel.Parent then
		return
	end

	-- A racing thread can have built this board while the waits yielded
	if self._boards[baseModel] then
		return
	end

	local upgradeBoard = UpgradeBoard.new(baseModel, board)
	self._boards[baseModel] = upgradeBoard
	self._cleaner:Add(upgradeBoard)
end

-- Drops the board for a base that's streamed out or been removed.
function UpgradeBoardController:_removeBase(baseModel: Model)
	local board = self._boards[baseModel]
	if not board then
		return
	end

	self._cleaner:Remove(board)
	self._boards[baseModel] = nil
end

-- Raises the owner-only nameplate marker on the base the local player owns, and lowers it as they leave it.
function UpgradeBoardController:_refreshOwnerIcon()
	self._ownerCleaner:Clean()

	local baseId = LocalPlayer:GetAttribute("BaseId")
	if not baseId then
		return
	end

	-- Waited on, since the plate is made as the base is claimed
	task.spawn(function()
		local base = workspace:WaitForChild("Base"):WaitForChild(baseId)
		local baseIcon = base.BaseAttachment:WaitForChild("BaseUI").BaseIcon

		-- The waits yield, so the base can have been handed over in the meantime
		if LocalPlayer:GetAttribute("BaseId") ~= baseId then
			return
		end

		baseIcon.Visible = true

		self._ownerCleaner:Add(function()
			baseIcon.Visible = false
		end)
	end)
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

	self:RefreshBoards()
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

function UpgradeBoardController:OnInit()
	PlayerDataController = require(script.Parent.PlayerDataController)
	ShopController = require(script.Parent.ShopController)
end

function UpgradeBoardController:OnStart()
	-- Watched rather than swept once, and off this thread since the loader runs every OnStart on one
	task.spawn(function()
		local baseFolder = workspace:WaitForChild("Base")

		self._cleaner:Connect(baseFolder.ChildAdded, function(baseModel)
			self:_setupBase(baseModel)
		end)
		self._cleaner:Connect(baseFolder.ChildRemoved, function(baseModel)
			self:_removeBase(baseModel)
		end)

		-- _setupBase waits on the base's upgrades folder, so keep the sweep off this thread too
		for _, baseModel in baseFolder:GetChildren() do
			task.spawn(function()
				self:_setupBase(baseModel)
			end)
		end
	end)

	-- BaseId lands after the boards are built and moves on assignment, so re-check which one shows its buttons
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:RefreshBoards()
		self:_refreshOwnerIcon()
	end)

	-- Sweep once, since BaseId may already be set by the time we start
	self:_refreshOwnerIcon()

	task.spawn(function()
		self:_cacheRobuxPrices()
	end)

	-- The unlocks are the player's, not a base's. Gains only, or a purchase would stack on the server's own toast
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
