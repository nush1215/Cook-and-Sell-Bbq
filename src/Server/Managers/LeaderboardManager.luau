-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- Packages
local Packages = ReplicatedStorage.Packages
local Replica = require(Packages.Replica)

--
local SAVE_TIME_INTERVAL = 2.5 * 60
local LOAD_TIME_INTERVAL = 3 * 60
local TOTAL_LEADERBOARD_ENTRIES = 100

--
local LEADERBOARD_DATA = {
	Currency = DataStoreService:GetOrderedDataStore("RICHEST_LEADERBOARD_V3"),
	SalesCompleted = DataStoreService:GetOrderedDataStore("MOST_SALES_COMPLETED_LEADERBOARD_V3"),
	TotalPlaytime = DataStoreService:GetOrderedDataStore("MOST_PLAYTIME_LEADERBOARD_V3"),
}

--
local PlayerDataManager

--
local LeaderboardManager = {
	_leaderboardReplica = nil,
	_lastSaved = {}, -- [userId] = { [dataKey] = value }
	_appliedRigUserIds = {}, -- [leaderboardKey] = userId currently shown on the Rig
}

function LeaderboardManager:UpdateLeaderboardRig(leaderboardKey: string, topEntry: { key: string, value: number }?)
	local leaderboards = Workspace:FindFirstChild("Leaderboards")
	local leaderboard = leaderboards and leaderboards:FindFirstChild(leaderboardKey)
	local rig = leaderboard and leaderboard:FindFirstChild("Rig")
	local humanoid = rig and rig:FindFirstChildWhichIsA("Humanoid")
	if not humanoid then
		return
	end

	local userId = topEntry and tonumber(topEntry.key)
	if not userId or userId < 1 then
		return
	end

	-- The rig persists across refreshes, so only re-apply when the #1 player changes.
	if self._appliedRigUserIds[leaderboardKey] == userId then
		return
	end
	self._appliedRigUserIds[leaderboardKey] = userId

	local success, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)

	if not success then
		-- Clear the cache so we retry on the next refresh.
		self._appliedRigUserIds[leaderboardKey] = nil
		return
	end

	pcall(function()
		humanoid:ApplyDescriptionAsync(description)
	end)
end

function LeaderboardManager:SaveLeaderboard()
	--
	if RunService:IsStudio() then
		return
	end

	for _, player in Players:GetPlayers() do
		PlayerDataManager:GetPlayerData(player)
			:andThen(function(playerData)
				local lastSaved = self._lastSaved[player.UserId]
				if not lastSaved then
					lastSaved = {}
					self._lastSaved[player.UserId] = lastSaved
				end

				for dataKey, dataStore: OrderedDataStore in LEADERBOARD_DATA do
					local currentKeyData = playerData[dataKey]
					if not currentKeyData then
						continue
					end

					local value = math.round(currentKeyData)

					-- Values < 1 are filtered out by the minValue in GetSortedAsync, and
					-- unchanged values don't need to be rewritten — both waste write budget.
					if value < 1 or lastSaved[dataKey] == value then
						continue
					end

					local success = pcall(function()
						dataStore:SetAsync(player.UserId, value)
					end)

					if success then
						lastSaved[dataKey] = value
					end
				end
			end)
			:catch(function(error)
				warn(`[LeaderboardManager] Failed to save leaderboard for {player.Name}: {error}`)
			end)
	end
end

function LeaderboardManager:LoadLeaderboard()
	local leaderboardData = {}
	for key, dataStore: OrderedDataStore in LEADERBOARD_DATA do
		local success, pages = pcall(function()
			return dataStore:GetSortedAsync(false, TOTAL_LEADERBOARD_ENTRIES, 1)
		end)

		if not success then
			continue
		end

		local topEntries = pages:GetCurrentPage()
		leaderboardData[key] = topEntries

		-- Dress this board's Rig as the current #1 player.
		self:UpdateLeaderboardRig(key, topEntries[1])
	end

	self._leaderboardReplica:Set({ "RefreshTime" }, workspace:GetServerTimeNow() + LOAD_TIME_INTERVAL)
	self._leaderboardReplica:Set({ "LeaderboardData" }, leaderboardData)
end

function LeaderboardManager:GetLeaderboardData(key: string)
	return self._leaderboardReplica.Data[key]
end

function LeaderboardManager:RemoveUserIdFromLeaderboards(userId: number)
	self._lastSaved[userId] = nil

	for _, dataStore: OrderedDataStore in LEADERBOARD_DATA do
		pcall(function()
			dataStore:RemoveAsync(userId)
		end)
	end
end

function LeaderboardManager:OnInit()
	--
	PlayerDataManager = require(script.Parent.PlayerDataManager)

	--
	self._leaderboardReplica = Replica.New({
		Token = Replica.Token("Leaderboard"),
		Data = {
			LeaderboardData = {},
			RefreshTime = workspace:GetServerTimeNow() + LOAD_TIME_INTERVAL,
		},
	})

	--
	Players.PlayerRemoving:Connect(function(player)
		self._lastSaved[player.UserId] = nil
	end)

	--
	task.spawn(function()
		while true do
			self:SaveLeaderboard()
			task.wait(SAVE_TIME_INTERVAL)
		end
	end)

	task.spawn(function()
		while true do
			self:LoadLeaderboard()
			task.wait(LOAD_TIME_INTERVAL)
		end
	end)

	--
	task.delay(3, function()
		self._leaderboardReplica:Replicate()
	end)
end

function LeaderboardManager:OnStart() end

return LeaderboardManager
