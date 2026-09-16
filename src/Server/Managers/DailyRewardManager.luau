-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local DailyRewards = require(Shared.Config.DailyRewards)
local FreeWorkers = require(Shared.Config.FreeWorkers)
local Keywords = require(Shared.Config.Keywords)

-- Managers
local PlayerDataManager = require(script.Parent.PlayerDataManager)
local CurrencyManager = require(script.Parent.CurrencyManager)
local CrateManager = require(script.Parent.CrateManager)
local StickManager = require(script.Parent.StickManager)
local BuildManager = require(script.Parent.BuildManager)
local EmployeeManager = require(script.Parent.EmployeeManager)
local FreeWorkersManager = require(script.Parent.FreeWorkersManager)
local NotificationManager = require(script.Parent.NotificationManager)
local BaseManager = require(script.Parent.BaseManager)

-- The week of daily rewards, one claim a day off the panel's tiles. Nothing about a reward is written down: it's derived from the player's UserId and how many they've claimed, so the count and when the last was taken are the whole of the state. A worker day is claimed by picking one of three cards, and only the slot number comes back.

--
local DailyRewardManager = {
	ClaimDailyRewardEvent = Network.Event("ClaimDailyReward", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 2 },
	}), -- client -> server (slotIndex?)
	ClaimDailyRewardResultEvent = Network.Event("ClaimDailyRewardResult"), -- server -> client (success, slotIndex?)

	OnDailyRewardClaimed = Signal.new(), -- (player, day, week, reward)

	_claiming = {}, -- [player] = true, held across the read -> write yield window
}

-- Grants one Reward entry, a Bux one logged under `source`. A Worker hires `candidate`, the card picked for it. Also the daily quest board's grant.
function DailyRewardManager:GrantReward(
	player: Player,
	reward: DailyRewards.Reward,
	source: string,
	candidate: FreeWorkers.Candidate?
)
	if reward.Type == "Bux" then
		-- Boosts skipped: the tile advertises a fixed number, as a Bux pack's card does
		CurrencyManager:IncrementCurrency(player, reward.Amount, source, true)
	elseif reward.Type == "Crate" then
		CrateManager:GrantCrate(player, reward.Id, reward.Amount)
	elseif reward.Type == "Stick" then
		StickManager:GrantStick(player, reward.Id, reward.Amount)
	elseif reward.Type == "Structure" then
		-- Owned rather than placed, as a shop buy lands, so where it goes is theirs to choose
		BuildManager:GrantStructure(player, reward.Id, reward.Amount)
	else
		EmployeeManager:HireEmployee(player, candidate.Role, candidate.Body, candidate.Stars, {
			Name = candidate.Name,
			Cosmetics = candidate.Cosmetics,
		})
	end
end

-- Hands over the reward that's up, authoritative on whether it's unlocked and on what it is. A worker day's three are re-rolled here off the same seed the client drew them from, so only the pick's slot comes over.
function DailyRewardManager:ClaimDailyReward(player: Player, slotIndex: number?): boolean
	-- Reading their data yields, so without this guard two rapid presses could both pass before either writes
	if self._claiming[player] then
		return false
	end
	self._claiming[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._claiming[player] = nil
		return false
	end

	-- The panel offers nothing before the tutorial ends or the day unlocks, so reaching either is a forged call, refused without a toast
	local now = workspace:GetServerTimeNow()
	local unlocksAt = data.LastDailyRewardClaim + DailyRewards.CLAIM_INTERVAL
	if not data.TutorialCompleted or now + DailyRewards.CLAIM_GRACE < unlocksAt then
		self._claiming[player] = nil
		return false
	end

	local claimedCount = data.DailyRewardStreak
	local reward = DailyRewards.GetReward(player.UserId, claimedCount)

	-- Checked before anything is stamped, so a forged slot can't spend the day on nothing
	local candidate
	if reward.Type == "Worker" then
		if type(slotIndex) ~= "number" or not FreeWorkers.SLOT_ROLES[slotIndex] then
			self._claiming[player] = nil
			return false
		end

		local seed = DailyRewards.GetSeed(player.UserId, claimedCount)
		candidate = FreeWorkers.RollCandidates(seed, reward.Stars)[slotIndex]
	end

	-- The stamp before the count, or the client reads the next day as unlocked in between. Both before the grant, as a redeemed code is
	PlayerDataManager:SetPlayerDataKey(player, "LastDailyRewardClaim", now)
	PlayerDataManager:SetPlayerDataKey(player, "DailyRewardStreak", claimedCount + 1)

	self:GrantReward(player, reward, "DailyReward", candidate)

	if candidate then
		-- These three are spent, so their faces go rather than stand in for the next worker day's
		local portraits = player.PlayerGui:FindFirstChild(DailyRewards.PORTRAIT_FOLDER)
		if portraits then
			portraits:Destroy()
		end
	end

	self._claiming[player] = nil

	local day = DailyRewards.GetDay(claimedCount)
	local title = DailyRewards.GetRewardDisplay(reward)
	local dayText = GuiUtil.Colorize(`Day {day}`, Keywords.NUMBER)

	-- A hire lands unequipped, so it names who they got and where they go to work rather than the day
	NotificationManager:NotifyNormal(player, {
		Text = if candidate
			then `Hired {GuiUtil.Colorize(candidate.Name, Keywords.Colors.Workers)}! Equip them at your Worker Hut`
			else `Claimed your {dayText} reward: {title}`,
		Duration = 5,
		Sound = "CollectedReward",
		Effect = "Success",
	})

	self.OnDailyRewardClaimed:Fire(player, day, claimedCount // #DailyRewards.Days + 1, reward)

	-- The next day may be a worker one, and its cards want faces waiting by the time it unlocks
	task.spawn(function()
		self:ResumeDailyRewardPortraits(player)
	end)

	return true
end

-- Unlocks the player's next day now, for the SkipDay product. Only the stamp moves, so the day is still theirs to claim off its tile.
function DailyRewardManager:SkipDailyRewardWait(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	PlayerDataManager:SetPlayerDataKey(
		player,
		"LastDailyRewardClaim",
		workspace:GetServerTimeNow() - DailyRewards.CLAIM_INTERVAL
	)

	local dayText = GuiUtil.Colorize(`Day {DailyRewards.GetDay(data.DailyRewardStreak)}`, Keywords.NUMBER)
	NotificationManager:NotifyNormal(player, {
		Text = `Your {dayText} reward is ready to claim`,
		Duration = 5,
		Sound = "CollectedReward",
		Effect = "Success",
	})
end

-- Dresses the three on offer when the player's next claim is a worker day, so its cards have faces waiting.
function DailyRewardManager:ResumeDailyRewardPortraits(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local claimedCount = data.DailyRewardStreak
	local reward = DailyRewards.GetReward(player.UserId, claimedCount)
	if reward.Type ~= "Worker" then
		return
	end

	local candidates = FreeWorkers.RollCandidates(DailyRewards.GetSeed(player.UserId, claimedCount), reward.Stars)
	FreeWorkersManager:BakeCandidatePortraits(player, DailyRewards.PORTRAIT_FOLDER, candidates, function(latest)
		-- A claim in the meantime moved them on, so these three are no longer the ones on offer
		return latest.DailyRewardStreak == claimedCount
	end)
end

-- Puts a player on `day`, counted across weeks, unlocking in `secondsLeft`. Written through the replica so the panel follows live. For the dailyReward command.
function DailyRewardManager:DebugSetDailyReward(player: Player, day: number, secondsLeft: number): boolean
	if not PlayerDataManager:GetLoadedPlayerData(player) then
		return false
	end

	-- The stamp before the count, as a claim writes them
	local claimedAt = workspace:GetServerTimeNow() - DailyRewards.CLAIM_INTERVAL + secondsLeft
	PlayerDataManager:SetPlayerDataKey(player, "LastDailyRewardClaim", claimedAt)
	PlayerDataManager:SetPlayerDataKey(player, "DailyRewardStreak", day - 1)

	-- Faces baked for the day they were on belong to a different three
	local portraits = player.PlayerGui:FindFirstChild(DailyRewards.PORTRAIT_FOLDER)
	if portraits then
		portraits:Destroy()
	end

	task.spawn(function()
		self:ResumeDailyRewardPortraits(player)
	end)

	return true
end

function DailyRewardManager:OnStart()
	self.ClaimDailyRewardEvent:OnServerEvent(function(player: Player, slotIndex: number?)
		local success = self:ClaimDailyReward(player, slotIndex)
		self.ClaimDailyRewardResultEvent:FireClient(player, success, slotIndex)
	end)

	-- Off the handover rather than PlayerAdded, so the bake waits behind the load the rest of the base waits on
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		task.spawn(function()
			self:ResumeDailyRewardPortraits(player)
		end)
	end)

	-- This manager can load after a player is already on a base, so sweep whoever is here
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:ResumeDailyRewardPortraits(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		self._claiming[player] = nil
	end)
end

return DailyRewardManager
