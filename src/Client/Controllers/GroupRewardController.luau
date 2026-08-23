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

--[[
	Drives the Group Reward screen, opened from the HUD's Gift button. The reward takes two things:
	favoriting the game, which only the client can read, and being in the group, which the server
	checks. So this side owns the favorite gate and hands anything that clears it to the server, which
	owns the rest and reports every outcome through its own notifications.

	The reward is one-shot, so a successful claim closes the panel and hides the Gift button for good --
	there's no way back into either after that.
]]
local GroupRewardController = {
	ClaimGroupRewardEvent = Network.Event("ClaimGroupReward"),

	_lastClaimAt = 0,
	_claiming = false,
	_inventoryAccess = false,
	_awaitingFavorite = false,
}

-- Asks for the inventory read permission GetFavoriteAsync needs. The grant doesn't persist between
-- sessions, so this prompts once per session and remembers the answer.
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

-- Runs the favorite half of the requirement, reporting whether the player cleared it. Someone who
-- hasn't favorited gets the prompt instead of a rejection they can't act on; PromptSetFavoriteCompleted
-- picks the claim back up if they go through with it.
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
	-- Two guards, because the favorite check yields on Roblox prompts: _claiming stops a press landing
	-- while an earlier one is still sat on an open prompt (which would open a second one and fire
	-- twice off the same accept), _lastClaimAt throttles presses that make it through to the server.
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

	-- The HUD's Gift button toggles the screen open; the Exit button closes it.
	local giftButton = HudController:BindHudButton("Gift", function()
		UIController:OpenFrame(holder)
	end)
	UIController:BindButtonClick(holder.Exit, function()
		UIController:CloseFrame(holder)
	end, true)

	UIController:BindButtonClick(holder.Claim, function()
		self:ClaimReward()
	end, true)

	-- Picks the claim back up once the player favorites off the prompt, so they don't have to press
	-- Claim a second time.
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

	-- Retire the Gift button once the reward is spent, and keep it retired across rejoins. Deferred:
	-- the read awaits the replica.
	task.spawn(function()
		local function applyClaimed(isClaimed: boolean)
			giftButton.Button.Visible = not isClaimed

			if isClaimed then
				giftButton.StopAlert()
			else
				giftButton.StartAlert()
			end

			-- There's nothing left in the panel once the reward is spent, so it sees itself out on the
			-- claim landing. Guarded on Visible because this same path runs on the initial read, when a
			-- returning player's panel is already shut and a close would spring the camera for nothing.
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
