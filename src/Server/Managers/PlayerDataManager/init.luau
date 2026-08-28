-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Replica = require(Packages.Replica)
local Promise = require(Packages.Promise)
local Signal = require(Packages.Signal)

-- Server Packages
local ServerPackages = ServerScriptService.ServerPackages
local ProfileStore = require(ServerPackages.ProfileStore)

-- Modules
local DataSettings = require(script.DataSettings)

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)

--
local USE_STUDIO_DATA = false
local LIVE_DATA_VERSION = "PLAYER_DATA_A3"
local STUDIO_DATA_VERSION = "PLAYER_DATA_STUDIO_A5"
local DEFAULT_TIMEOUT = 25
local DATA_POLL_INTERVAL = 0.1

--
local PlayerDataToken = Replica.Token("PlayerData")

-- Pre-cleanup callbacks run synchronously right before the profile's final save
-- (leave, shutdown, or external session takeover). Callbacks receive the live data
-- table and should mutate it directly -- do NOT call SetPlayerDataKey here, the
-- player may already be gone from the Players service.
-- Callbacks MUST NOT yield; anything after a yield won't make it into the save.
local PlayerDataManager = {
	OnDataChanged = Signal.new(),
	_playerData = {},
	_preCleanupCallbacks = {},
}

local PlayerDataStore = ProfileStore.New(
	RunService:IsStudio() and STUDIO_DATA_VERSION or LIVE_DATA_VERSION,
	DataSettings.PlayerDataTemplate
)

if RunService:IsStudio() and not USE_STUDIO_DATA then
	PlayerDataStore = PlayerDataStore.Mock
end

--
local function normalizeKey(key: string | { string }): { string }
	if typeof(key) == "table" then
		return key
	end
	return { key }
end

local function validatePlayer(player: Player): boolean
	return player and player:IsDescendantOf(Players)
end

-- Copies template data without sharing nested tables between players.
local function deepCopy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, childValue in value do
		copy[deepCopy(key)] = deepCopy(childValue)
	end
	return copy
end

-----[[ GET FUNCTIONS ]] -----
-- Note: all of the Get Functions returns a Promise

-- Gets a copy of the player data and the replica
-- @param player The player to get data for
-- @param timeout Optional timeout in seconds (default: DEFAULT_TIMEOUT)
-- @returns Promise<PlayerData, Replica>
function PlayerDataManager:GetPlayerData(player: Player, timeout: number?)
	if not validatePlayer(player) then
		return Promise.reject("Invalid player")
	end

	local startTime = tick()
	local timeoutDuration = timeout or DEFAULT_TIMEOUT

	return Promise.new(function(resolve, reject)
		local function checkData()
			local playerData = self._playerData[player]

			if playerData then
				resolve(playerData.Replica.Data, playerData.Replica)
				return true
			end

			if tick() - startTime >= timeoutDuration then
				reject(`Player data not found for {player.Name} within {timeoutDuration} seconds`)
				return true
			end

			if not validatePlayer(player) then
				reject(`Player {player.Name} left before data could be loaded`)
				return true
			end

			return false
		end

		-- Initial check
		if checkData() then
			return
		end

		-- Poll for data
		task.spawn(function()
			while true do
				task.wait(DATA_POLL_INTERVAL)
				if checkData() then
					break
				end
			end
		end)
	end)
end

-- The player's data as it stands right now, or nil if it hasn't loaded yet. The non-yielding
-- counterpart to GetPlayerData above, for callers on a hot path that can carry on without it -- a
-- promise there would change the contract of whatever they're called from. Read-only by convention:
-- writes still go through the Set/Increment functions below so the replica replicates them.
-- @param player The player to get data for
-- @returns the data table, or nil if the profile isn't loaded
function PlayerDataManager:GetLoadedPlayerData(player: Player)
	local loadedPlayerData = self._playerData[player]
	return loadedPlayerData and loadedPlayerData.Replica.Data
end

-- Gets a specific key from player data
-- @param player The player to get data for
-- @param key The key to retrieve
-- @returns Promise<any>
function PlayerDataManager:GetPlayerDataKey(player: Player, key: string)
	return Promise.new(function(resolve, reject)
		local success, playerData, replica = self:GetPlayerData(player):await()

		if not success then
			reject(`Failed to get player data for {player.Name}`)
			return
		end

		if playerData[key] == nil then
			reject(`Key '{key}' not found in player data for {player.Name}`)
			return
		end

		resolve(playerData[key])
	end)
end

-----[[ SET FUNCTIONS ]] -----

-- Sets a value in player data
-- @param player The player whose data to modify
-- @param key The key (string or table path) to set
-- @param newValue The new value to set
function PlayerDataManager:SetPlayerDataKey(player: Player, key: string | table, newValue: any)
	if not validatePlayer(player) then
		warn(`Cannot set data for invalid player: {player}`)
		return
	end

	local normalizedKey = normalizeKey(key)
	local loadedPlayerData = self._playerData[player]
	if loadedPlayerData then
		loadedPlayerData.Replica:Set(normalizedKey, newValue)
		self.OnDataChanged:Fire(player, normalizedKey[1], newValue)
		return
	end

	self:GetPlayerData(player)
		:andThen(function(playerData, replica)
			replica:Set(normalizedKey, newValue)
			self.OnDataChanged:Fire(player, normalizedKey[1], newValue)
		end)
		:catch(function(error)
			warn(`Failed to set player data key for {player.Name}: {error}`)
		end)
end

-- Inserts a value into an array in player data
-- @param player The player whose data to modify
-- @param key The key (string or table path) to the array
-- @param value The value to insert
function PlayerDataManager:InsertPlayerDataKey(player: Player, key: string | table, value: any)
	if not validatePlayer(player) then
		warn(`Cannot insert data for invalid player: {player}`)
		return
	end

	self:GetPlayerData(player)
		:andThen(function(playerData, replica)
			local normalizedKey = normalizeKey(key)
			local currentValue = playerData[normalizedKey[1]]

			if currentValue == nil then
				warn(`Key '{normalizedKey[1]}' does not exist for {player.Name}`)
				return
			end

			if typeof(currentValue) ~= "table" then
				warn(`Expected table for key '{normalizedKey[1]}', got {typeof(currentValue)}`)
				return
			end

			replica:TableInsert(normalizedKey, value)
			self.OnDataChanged:Fire(player, normalizedKey[1], playerData[normalizedKey[1]])
		end)
		:catch(function(error)
			warn(`Failed to insert player data key for {player.Name}: {error}`)
		end)
end

-- Inserts a value into an array in player data, trimming the oldest entries
-- (lowest indices) so the array length stays at or below maxSize after insertion.
-- @param player The player whose data to modify
-- @param key The key (string or table path) to the array
-- @param value The value to insert
-- @param maxSize The maximum number of entries to retain after insertion (must be >= 1)
function PlayerDataManager:InsertCappedPlayerDataKey(player: Player, key: string | table, value: any, maxSize: number)
	if not validatePlayer(player) then
		warn(`Cannot insert capped data for invalid player: {player}`)
		return
	end

	if typeof(maxSize) ~= "number" or maxSize < 1 then
		warn(`Invalid maxSize '{maxSize}' for capped insert on {player.Name}`)
		return
	end

	self:GetPlayerData(player)
		:andThen(function(playerData, replica)
			local normalizedKey = normalizeKey(key)
			local currentValue = playerData[normalizedKey[1]]

			if currentValue == nil then
				warn(`Key '{normalizedKey[1]}' does not exist for {player.Name}`)
				return
			end

			if typeof(currentValue) ~= "table" then
				warn(`Expected table for key '{normalizedKey[1]}', got {typeof(currentValue)}`)
				return
			end

			for _ = 1, #currentValue - maxSize + 1 do
				replica:TableRemove(normalizedKey, 1)
			end

			replica:TableInsert(normalizedKey, value)
			self.OnDataChanged:Fire(player, normalizedKey[1], playerData[normalizedKey[1]])
		end)
		:catch(function(error)
			warn(`Failed to insert capped data key for {player.Name}: {error}`)
		end)
end

-- Removes a value from an array in player data
-- @param player The player whose data to modify
-- @param key The key (string or table path) to the array
-- @param value The value to remove
function PlayerDataManager:RemovePlayerDataKey(player: Player, key: string | table, value: any)
	if not validatePlayer(player) then
		warn(`Cannot remove data for invalid player: {player}`)
		return
	end

	self:GetPlayerData(player)
		:andThen(function(playerData, replica)
			local normalizedKey = normalizeKey(key)
			local currentValue = playerData[normalizedKey[1]]

			if currentValue == nil then
				warn(`Key '{normalizedKey[1]}' does not exist for {player.Name}`)
				return
			end

			if typeof(currentValue) ~= "table" then
				warn(`Expected table for key '{normalizedKey[1]}', got {typeof(currentValue)}`)
				return
			end

			local index = table.find(currentValue, value)
			if not index then
				warn(`Value '{value}' not found in key '{normalizedKey[1]}' for {player.Name}`)
				return
			end

			replica:TableRemove(normalizedKey, index)
			self.OnDataChanged:Fire(player, normalizedKey[1], playerData[normalizedKey[1]])
		end)
		:catch(function(error)
			warn(`Failed to remove player data key for {player.Name}: {error}`)
		end)
end

-- Increments a numeric value in player data
-- @param player The player whose data to modify
-- @param key The key to increment
-- @param amount The amount to increment by (default: 1)
function PlayerDataManager:IncrementDataKey(player: Player, key: string, amount: number?)
	if not validatePlayer(player) then
		warn(`Cannot increment data for invalid player: {player}`)
		return
	end

	amount = amount or 1

	local loadedPlayerData = self._playerData[player]
	if loadedPlayerData then
		local playerData = loadedPlayerData.Replica.Data
		if typeof(playerData[key]) ~= "number" then
			warn(`Expected number for key '{key}', got {typeof(playerData[key])}`)
			return
		end

		local newValue = playerData[key] + amount
		loadedPlayerData.Replica:Set({ key }, newValue)
		self.OnDataChanged:Fire(player, key, newValue)
		return
	end

	self:GetPlayerData(player)
		:andThen(function(playerData, replica)
			if typeof(playerData[key]) ~= "number" then
				warn(`Expected number for key '{key}', got {typeof(playerData[key])}`)
				return
			end

			local currentValue = playerData[key]
			local newValue = currentValue + amount
			replica:Set({ key }, newValue)
			self.OnDataChanged:Fire(player, key, newValue)
		end)
		:catch(function(error)
			warn(`Failed to increment data key for {player.Name}: {error}`)
		end)
end

-- Decrements a numeric value in player data
-- @param player The player whose data to modify
-- @param key The key to decrement
-- @param amount The amount to decrement by (default: 1)
function PlayerDataManager:DecrementDataKey(player: Player, key: string, amount: number?)
	if not validatePlayer(player) then
		warn(`Cannot decrement data for invalid player: {player}`)
		return
	end

	amount = amount or 1

	self:GetPlayerData(player)
		:andThen(function(playerData, replica)
			if typeof(playerData[key]) ~= "number" then
				warn(`Expected number for key '{key}', got {typeof(playerData[key])}`)
				return
			end

			local currentValue = playerData[key]
			local newValue = currentValue - amount
			replica:Set({ key }, newValue)
			self.OnDataChanged:Fire(player, key, newValue)
		end)
		:catch(function(error)
			warn(`Failed to decrement data key for {player.Name}: {error}`)
		end)
end

-- Resets a player's saved data to the current template.
-- @param player The player whose data to reset
function PlayerDataManager:ResetPlayerData(player: Player): (boolean, string?)
	if not validatePlayer(player) then
		return false, "Invalid player"
	end

	local success, playerData, replica = self:GetPlayerData(player):await()
	if not success then
		return false, `Failed to get player data for {player.Name}`
	end

	local resetData = deepCopy(DataSettings.PlayerDataTemplate)
	for key in playerData do
		if resetData[key] == nil then
			replica:Set({ key }, nil)
			self.OnDataChanged:Fire(player, key, nil)
		end
	end

	for key, value in resetData do
		replica:Set({ key }, value)
		self.OnDataChanged:Fire(player, key, value)
	end

	return true
end

-----[[ LISTEN FUNCTIONS ]] -----
-- Listens for changes to a specific key in player data
-- @param player The player to listen for
-- @param key The key to listen for changes on
-- @param callback Function called when the key changes
function PlayerDataManager:ListenForChanges(player: Player, key: string, callback: (newValue: any) -> ())
	return self.OnDataChanged:Connect(function(dataChangedPlayer, changedKey, newValue)
		if dataChangedPlayer == player and changedKey == key then
			callback(newValue)
		end
	end)
end

-- Registers a callback that runs synchronously right before a player's data is saved
-- for the last time (leave / shutdown / external session takeover). The callback
-- gets the live data table and should mutate it directly. Must not yield.
-- @param callback (player, data, reason: "Manual" | "External" | "Shutdown") -> ()
-- @returns function that unregisters the callback
function PlayerDataManager:RegisterPreCleanupCallback(callback: (player: Player, data: any, reason: string) -> ())
	table.insert(self._preCleanupCallbacks, callback)

	return function()
		local index = table.find(self._preCleanupCallbacks, callback)
		if index then
			table.remove(self._preCleanupCallbacks, index)
		end
	end
end

-- Sets up player data when a player joins
-- @param player The player to set up
function PlayerDataManager:_setupPlayer(player: Player)
	if not validatePlayer(player) then
		return
	end

	local playerProfile = PlayerDataStore:StartSessionAsync(`Player_{player.UserId}`, {
		Cancel = function()
			return not validatePlayer(player)
		end,
	})

	if not playerProfile then
		player:Kick("There's a problem loading your data! Please try rejoining.")
		return
	end

	playerProfile:AddUserId(player.UserId)
	playerProfile:Reconcile()

	playerProfile.OnSessionEnd:Connect(function()
		self._playerData[player] = nil
		player:Kick()
	end)

	playerProfile.OnLastSave:Connect(function(reason: string)
		for _, callback in self._preCleanupCallbacks do
			local ok, err = xpcall(callback, debug.traceback, player, playerProfile.Data, reason)
			if not ok then
				warn(`Pre-cleanup callback errored for {player.Name}: {err}`)
			end
		end
	end)

	if not validatePlayer(player) then
		playerProfile:EndSession()
		return
	end

	local dataReplica = Replica.New({
		Token = PlayerDataToken,
		Tags = { UserId = player.UserId },
		Data = playerProfile.Data,
	})

	local leaderstatConnections = self:_setupLeaderstats(player, playerProfile.Data)
	self:_subscribePlayerToReplica(player, dataReplica)

	self._playerData[player] = {
		Profile = playerProfile,
		Replica = dataReplica,
		LeaderstatConnections = leaderstatConnections,
	}

	if playerProfile.Data.HasOGTag then
		player:AddTag("OG")
	end
end

-- Sets up leaderstats for a player. Returns the data-change connections that keep them current, so
-- the caller can drop them when the player leaves -- they hang off the one shared OnDataChanged signal,
-- and left in place every write for anyone still here would walk a listener for everyone who ever was.
-- @param player The player to set up leaderstats for
-- @param playerData The player's data
function PlayerDataManager:_setupLeaderstats(player: Player, playerData: any): { RBXScriptConnection }
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local connections = {}

	for dataKey, leaderstatSetting in DataSettings.ToLeaderstats do
		if not DataSettings.PlayerDataTemplate[dataKey] then
			warn(`{dataKey} not found in PlayerDataTemplate`)
			continue
		end

		local useSuffix = type(leaderstatSetting) == "table" and leaderstatSetting.UseSuffix
		-- A Prefix ("$" for currency) forces the string form, since an IntValue can't carry it.
		local prefix = type(leaderstatSetting) == "table" and leaderstatSetting.Prefix or nil
		local asString = useSuffix or prefix ~= nil
		local statValue = Instance.new(if asString then "StringValue" else "IntValue")
		statValue.Name = if type(leaderstatSetting) == "table" then leaderstatSetting.Name else leaderstatSetting

		local function formatStat(value: number)
			if not asString then
				return value
			end

			local amount = if useSuffix then GuiUtil.ConvertNumberWithSuffix(value) else tostring(value)
			return if prefix then prefix .. amount else amount
		end

		statValue.Value = formatStat(playerData[dataKey])
		statValue.Parent = leaderstats

		table.insert(
			connections,
			self:ListenForChanges(player, dataKey, function(newValue)
				statValue.Value = formatStat(newValue)
			end)
		)
	end

	return connections
end

-- Subscribes a player to their data replica
-- @param player The player to subscribe
-- @param dataReplica The replica to subscribe to
function PlayerDataManager:_subscribePlayerToReplica(player: Player, dataReplica: any)
	if Replica.ReadyPlayers[player] then
		dataReplica:Subscribe(player)
		return
	end

	local connection
	connection = Replica.NewReadyPlayer:Connect(function(readyPlayer)
		if readyPlayer == player then
			dataReplica:Subscribe(player)
			connection:Disconnect()
		end
	end)

	dataReplica.Maid:Add(connection)
end

-- Cleans up player data when a player leaves
-- @param player The player to clean up
function PlayerDataManager:_cleanupPlayer(player: Player)
	local playerData = self._playerData[player]

	if playerData then
		for _, connection in playerData.LeaderstatConnections do
			connection:Disconnect()
		end

		playerData.Profile:EndSession()
		playerData.Replica:Destroy()
		self._playerData[player] = nil
	end
end

-- Initializes the PlayerDataManager
-- Sets up event connections for player join/leave
function PlayerDataManager:OnInit()
	Players.PlayerAdded:Connect(function(player: Player)
		self:_setupPlayer(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)
end

return PlayerDataManager
