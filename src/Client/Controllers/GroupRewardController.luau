-- Services
local AvatarEditorService = game:GetService("AvatarEditorService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local GroupReward = require(Shared.Config.GroupReward)
local Network = require(Shared.Network)

-- Controllers
local PlayerDataController
local NotificationController
local UIController
local HudController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- Matches GroupRewardManager's own cooldown, so a spammed Claim never round-trips just to be rejected.
local CLAIM_COOLDOWN = 1

-- Drives the Group Reward screen. This side owns the favorite gate, which only a client can read; the server owns the rest. One-shot -- a claim hides the Gift button for good.
local GroupRewardController = {
	ClaimGroupRewardEvent = Network.Event("ClaimGroupReward"),

	_lastClaimAt = 0,
	_claiming = false,
	_inventoryAccess = false,
	_awaitingFavorite = false,
}

-- Asks for the inventory permission GetFavoriteAsync needs, once per session -- the grant doesn't persist.
function GroupRewardController:_ensureInventoryAccess(): boolean
	if self._inventoryAccess then
		return true
	end

	local success, granted = pcall(function()
		AvatarEditorService:PromptAllowInventoryReadAccess()
		return AvatarEditorService.PromptAllowInventoryReadAccessCompleted:Wait() == Enum.AvatarPromptResult.Success
	end)

	self._inventoryAccess = success and granted
	return self._inventoryAccess
end

-- Runs the favorite half, prompting rather than rejecting. PromptSetFavoriteCompleted picks the claim back up.
function GroupRewardController:_checkFavorite(): boolean
	if not self:_ensureInventoryAccess() then
		NotificationController:NotifyNormal({
			Text = "Allow inventory access to claim the reward",
			Duration = 5,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	local success, isFavorited = pcall(function()
		return AvatarEditorService:GetFavoriteAsync(GroupReward.FAVORITE_ASSET_ID, Enum.AvatarItemType.Asset)
	end)

	if not (success and isFavorited) then
		self._awaitingFavorite = true
		pcall(function()
			AvatarEditorService:PromptSetFavorite(GroupReward.FAVORITE_ASSET_ID, Enum.AvatarItemType.Asset, true)
		end)

		NotificationController:NotifyNormal({
			Text = "Favorite the game first, then claim",
			Duration = 5,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	return true
end

-- Gates the claim on the favorite check, then hands it to the server, which owns the group check.
function GroupRewardController:ClaimReward()
	-- Two guards: _claiming stops a second prompt opening over an open one, _lastClaimAt throttles the server
	if self._claiming or time() - self._lastClaimAt < CLAIM_COOLDOWN then
		return
	end

	self._claiming = true
	self._lastClaimAt = time()

	local favorited = self:_checkFavorite()
	self._claiming = false

	if favorited then
		self.ClaimGroupRewardEvent:FireServer()
	end
end

function GroupRewardController:OnInit()
	PlayerDataController = require(script.Parent.PlayerDataController)
	NotificationController = require(script.Parent.NotificationController)
	UIController = require(script.Parent.UIController)
	HudController = require(script.Parent.HudController)

	self.UI = PlayerGui:WaitForChild("GroupRewardUI")
end

function GroupRewardController:OnStart()
	local holder = self.UI.Holder
	holder.Visible = false

	-- The HUD's Gift button toggles the screen open; the Exit button closes it
	local giftButton = HudController:BindHudButton("Gift", function()
		UIController:OpenFrame(holder)
	end)
	UIController:BindButtonClick(holder.Exit, function()
		UIController:CloseFrame(holder)
	end, true)

	UIController:BindButtonClick(holder.Claim, function()
		self:ClaimReward()
	end, true)

	-- Picks the claim back up once they favorite off the prompt, so Claim isn't pressed twice
	AvatarEditorService.PromptSetFavoriteCompleted:Connect(function()
		if not self._awaitingFavorite then
			return
		end
		self._awaitingFavorite = false

		local success, isFavorited = pcall(function()
			return AvatarEditorService:GetFavoriteAsync(GroupReward.FAVORITE_ASSET_ID, Enum.AvatarItemType.Asset)
		end)

		if success and isFavorited then
			self.ClaimGroupRewardEvent:FireServer()
		end
	end)

	-- Retired once spent and kept so across rejoins. Deferred, since the read awaits the replica
	task.spawn(function()
		local function applyClaimed(isClaimed: boolean)
			giftButton.Button.Visible = not isClaimed

			if isClaimed then
				giftButton.StopAlert()
			else
				giftButton.StartAlert()
			end

			-- Guarded on Visible, since this runs on the initial read too, when a close would spring the camera for nothing
			if isClaimed and holder.Visible then
				UIController:CloseFrame(holder)
			end
		end

		applyClaimed(PlayerDataController:GetKey("GroupRewardClaimed"))

		PlayerDataController:ListenForChange("GroupRewardClaimed", function(isClaimed: boolean)
			applyClaimed(isClaimed)
		end)
	end)
end

return GroupRewardController
