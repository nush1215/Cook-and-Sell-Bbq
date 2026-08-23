-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AnalyticsService = game:GetService("AnalyticsService")
local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local GroupReward = require(Shared.Config.GroupReward)
local Network = require(Shared.Network)

-- Managers
local IngredientManager
local PlayerDataManager
local NotificationManager
local StickManager

--[[
	Owns the one-time group reward. GroupRewardController gates the claim on the player having
	favorited the game before it ever fires -- that check is client-only, since AvatarEditorService
	has no server side -- so everything that can be enforced lands here: the claim record, the group
	membership check and the grant itself.
]]
local GroupRewardManager = {
	ClaimGroupRewardEvent = Network.Event("ClaimGroupReward"),

	_inCooldown = {},
}

-- Grants the reward once, to a player who is in the group and hasn't claimed before.
function GroupRewardManager:ClaimGroupReward(player: Player)
	-- Authoritative debounce; the controller has its own, but a spammed remote shouldn't be able to
	-- queue a GetGroupsAsync call per frame.
	if self._inCooldown[player] then
		NotificationManager:NotifyNormal(player, {
			Text = "Please wait a moment before trying again",
			Duration = 3,
			Sound = "Reject",
		})
		return
	end

	self._inCooldown[player] = true
	task.delay(1, function()
		self._inCooldown[player] = false
	end)

	local hasData, playerData = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	if playerData.GroupRewardClaimed then
		NotificationManager:NotifyNormal(player, {
			Text = "You have already claimed the group reward",
			Duration = 5,
			Sound = "Reject",
		})
		return
	end

	-- GetGroupsAsync over Player:IsInGroupAsync: the latter caches for the session, so someone who
	-- joins the group while playing would be told they aren't in it until they rejoined.
	local success, groups = pcall(function()
		return GroupService:GetGroupsAsync(player.UserId)
	end)

	if not success then
		NotificationManager:NotifyNormal(player, {
			Text = "Couldn't check your group membership, try again in a moment",
			Duration = 5,
			Sound = "Reject",
		})
		return
	end

	local isInGroup = false
	for _, group in groups do
		if group.Id == GroupReward.GROUP_ID then
			isInGroup = true
			break
		end
	end

	if not isInGroup then
		NotificationManager:NotifyNormal(player, {
			Text = "Join the group first, then claim",
			Duration = 5,
			Sound = "Reject",
		})
		return
	end

	-- Recorded before the grants, which yield -- so a second claim landing mid-grant sees it taken.
	PlayerDataManager:SetPlayerDataKey(player, "GroupRewardClaimed", true)

	for _, reward in GroupReward.Data do
		if reward.Type == "Ingredient" then
			IngredientManager:GrantIngredient(player, reward.Id, reward.Amount)
		else
			-- GrantStick has no amount parameter, it adds exactly one per call.
			for _ = 1, reward.Amount do
				StickManager:GrantStick(player, reward.Id)
			end
		end
	end

	NotificationManager:NotifyNormal(player, {
		Text = "Claimed the group reward",
		Duration = 5,
		Sound = "CollectedReward",
		Effect = "Success",
	})

	task.spawn(function()
		pcall(function()
			AnalyticsService:LogCustomEvent(player, "Group Reward Claimed", 1)
		end)
	end)
end

function GroupRewardManager:OnInit()
	IngredientManager = require(script.Parent.IngredientManager)
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	NotificationManager = require(script.Parent.NotificationManager)
	StickManager = require(script.Parent.StickManager)
end

function GroupRewardManager:OnStart()
	self.ClaimGroupRewardEvent:OnServerEvent(function(player: Player)
		self:ClaimGroupReward(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._inCooldown[player] = nil
	end)
end

return GroupRewardManager
