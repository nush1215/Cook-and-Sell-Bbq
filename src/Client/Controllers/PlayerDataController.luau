-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Replica = require(Packages.Replica)
local Promise = require(Packages.Promise)

-- Local Player
local LocalPlayer = Players.LocalPlayer

--
local DEFAULT_TIMEOUT = 15

-- Normalizes a data path into Replica's table path format.
local function normalizePath(path: string | { any }): { any }
	if typeof(path) == "string" then
		return { path }
	end

	return path
end

-- Gets a nested value from a data table.
local function getValueFromPath(data: { any }, path: { any }): any
	local value = data

	for _, key in path do
		if value == nil or typeof(value) ~= "table" then
			return nil
		end

		value = value[key]
	end

	return value
end

-- Copies table values so old values are not mutated by later replica updates.
local function snapshotValue(value: any, seen: { [any]: any }?): any
	if typeof(value) ~= "table" then
		return value
	end

	seen = seen or {}
	if seen[value] then
		return seen[value]
	end

	local copy = {}
	seen[value] = copy

	for key, childValue in value do
		copy[key] = snapshotValue(childValue, seen)
	end

	return copy
end

-- Checks whether either path is the same as, or inside, the other path.
local function isRelatedPath(watchedPath: { any }, changedPath: { any }): boolean
	local shortestLength = math.min(#watchedPath, #changedPath)

	for i = 1, shortestLength do
		if watchedPath[i] ~= changedPath[i] then
			return false
		end
	end

	return true
end

-- Gets each concrete changed path from a Replica OnChange event.
local function getChangedPaths(action: string, path: { any }, values: any): { { any } }
	if not (action == "SetValues") then
		return { path }
	end

	local changedPaths = {}
	for key in values do
		local changedPath = table.clone(path)
		table.insert(changedPath, key)
		table.insert(changedPaths, changedPath)
	end

	return changedPaths
end

--
local PlayerDataController = {
	_playerDataReplica = nil,
}

function PlayerDataController:GetReplica(timeout: number?)
	--
	timeout = timeout or DEFAULT_TIMEOUT
	local getTimeout = os.clock() + timeout

	--
	return Promise.new(function(resolve, reject)
		-- if there player replica has not yet been created, keep trying until it has
		if not self._playerDataReplica then
			repeat
				task.wait()
			until self._playerDataReplica or getTimeout - os.clock() <= 0

			if not self._playerDataReplica then
				reject("Timeout Reached! Player Replica does not exist.")
			end
		end

		--
		resolve(self._playerDataReplica)
	end)
end

function PlayerDataController:GetData(): { any }
	local hasData, playerDataReplica = self:GetReplica():await()
	if not hasData then
		return
	end

	return playerDataReplica.Data
end

function PlayerDataController:GetKey(key: string): any
	local playerData = PlayerDataController:GetData()
	return playerData[key]
end

-- Listens for changes to a player data path.
function PlayerDataController:ListenForChange(
	path: string | { any },
	callback: (newValue: any, oldValue: any, changedPath: { any }, action: string) -> (),
	timeout: number?
)
	local hasReplica, playerDataReplica = self:GetReplica(timeout):await()
	if not hasReplica then
		return
	end

	local watchedPath = normalizePath(path)
	local oldValue = snapshotValue(getValueFromPath(playerDataReplica.Data, watchedPath))

	return playerDataReplica:OnChange(function(action, changedPath, value)
		for _, currentChangedPath in getChangedPaths(action, changedPath, value) do
			if not isRelatedPath(watchedPath, currentChangedPath) then
				continue
			end

			local newValue = snapshotValue(getValueFromPath(playerDataReplica.Data, watchedPath))
			local previousValue = oldValue
			oldValue = snapshotValue(newValue)

			callback(newValue, previousValue, currentChangedPath, action)
			return
		end
	end)
end

function PlayerDataController:OnInit()
	Replica.OnNew("PlayerData", function(replica)
		if not (replica.Tags.UserId == LocalPlayer.UserId) then
			return
		end

		self._playerDataReplica = replica
	end)
end

return PlayerDataController
