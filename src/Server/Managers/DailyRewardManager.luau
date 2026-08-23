-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local DailyRewardsConfig

--
local NotificationManager
local PlayerDataManager
local ShopManager

--
local DailyRewardManager = {
	ClaimRewardFunction = Network.Function("ClaimDailyReward"),
}

--
function DailyRewardManager:ClaimReward(player: Player, skip: boolean?): boolean
	--
	local hasData, playerData = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return false
	end

	-- Checks if the player is eligible to claim the reward (skip if skip parameter is true)
	local currentTime = os.time()
	if not skip and (currentTime - playerData.LastDailyRewardClaim) < DailyRewardsConfig.CLAIM_INTERVAL then
		NotificationManager:NotifyNormal(player, {
			Text = "Come back later to claim your reward!",
			Duration = 6,
			Sound = "Reject",
		})
		ShopManager:AttemptProductPurchase(player, "SkipDay")
		return false
	end

	-- Check if the player has reached the max reward
	local currentStreak = playerData.DailyRewardStreak
	if currentStreak + 1 > DailyRewardsConfig.GetTotalRewards() then
		currentStreak = 0
	end

	-- Get the reward for the current day
	local rewardData = DailyRewardsConfig.GetRewardForDay(currentStreak + 1)
	if not rewardData then
		return false
	end

	-- Grant the reward
	rewardData.Callback(player)
	NotificationManager:NotifyNormal(
		player,
		{
			Text = `Successfully Claimed <font color="#ffd400">Day {currentStreak + 1}</font> Reward!`,
			Duration = 6,
			Sound = "CollectedReward",
		}
	)

	PlayerDataManager:SetPlayerDataKey(player, "DailyRewardStreak", currentStreak + 1)
	PlayerDataManager:SetPlayerDataKey(player, "LastDailyRewardClaim", currentTime)

	--
	AnalyticsService:LogCustomEvent(player, "Daily Reward Day Claimed", 1, {
		[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = `Day {currentStreak + 1}`,
	})

	return true
end

-- Collects all remaining daily rewards for the player
function DailyRewardManager:CollectAllRewards(player: Player): boolean
	--
	local hasData, playerData = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return false
	end

	local currentTime = os.time()
	local currentStreak = playerData.DailyRewardStreak
	local totalRewards = DailyRewardsConfig.GetTotalRewards()

	-- Calculate how many rewards are left to claim
	local rewardsToClaim = totalRewards - currentStreak
	if rewardsToClaim <= 0 then
		-- Player has already claimed all rewards, reset streak
		currentStreak = 0
		rewardsToClaim = totalRewards
	end

	-- Grant all remaining rewards
	for i = 1, rewardsToClaim do
		local dayToClaim = currentStreak + i
		local rewardData = DailyRewardsConfig.GetRewardForDay(dayToClaim)
		if rewardData then
			rewardData.Callback(player)

			-- Log analytics for each reward
			AnalyticsService:LogCustomEvent(player, "Daily Reward Day Claimed", 1, {
				[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = `Day {dayToClaim}`,
			})
		end
	end

	-- Update streak to max and update last claim time
	PlayerDataManager:SetPlayerDataKey(player, "DailyRewardStreak", totalRewards)
	PlayerDataManager:SetPlayerDataKey(player, "LastDailyRewardClaim", currentTime)

	-- Send notification
	NotificationManager:NotifyNormal(player, {
		Text = `Successfully Claimed <font color="#ffd400">All {rewardsToClaim} Daily Rewards</font>!`,
		Duration = 6,
		Sound = "CollectedReward",
	})

	return true
end

-- Attempt to reset the player's daily reward streak if they missed a day
function DailyRewardManager:_attemptResetStreak(player: Player)
	--
	local hasData, playerData = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	--
	if os.time() - playerData.LastDailyRewardClaim >= DailyRewardsConfig.CLAIM_INTERVAL * 2 then
		playerData.DailyRewardStreak = 0
	end
end

function DailyRewardManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	NotificationManager = require(script.Parent.NotificationManager)
	ShopManager = require(script.Parent.ShopManager)

	DailyRewardsConfig = require(Shared.Config.DailyRewards)

	Players.PlayerAdded:Connect(function(player)
		self:_attemptResetStreak(player)
	end)
end

function DailyRewardManager:OnStart()
	self.ClaimRewardFunction:OnInvoke(function(player: Player, skip: boolean?)
		return self:ClaimReward(player, skip)
	end)
end

return DailyRewardManager
