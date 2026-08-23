-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

--
local FLUSH_INTERVAL = 60

--
local PlayerDataManager

--
local PlaytimeManager = {
	-- (player, sessionLength, totalPlaytime) when a player leaves.
	OnSessionEnded = Signal.new(),

	_sessionStart = {}, -- [player] = os.time() of the last flush / join
	_joinTime = {}, -- [player] = os.time() the player joined this session
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Adds the seconds elapsed since the last flush into TotalPlaytime and resets the
-- session start, so the periodic flush and the final leave flush never double-count.
-- Mutates playerData directly because at leave/shutdown the player may already be
-- gone, which would make SetPlayerDataKey reject the write.
function PlaytimeManager:_flush(player: Player, playerData: { any })
	local start = self._sessionStart[player]
	if not start then
		return
	end

	local elapsed = os.time() - start
	self._sessionStart[player] = os.time()

	if elapsed <= 0 then
		return
	end

	playerData.TotalPlaytime = (playerData.TotalPlaytime or 0) + elapsed
end

-- Flushes a present player's accumulated playtime through the replica so the live
-- value stays fresh during play.
function PlaytimeManager:_flushLive(player: Player)
	PlayerDataManager:GetPlayerData(player)
		:andThen(function(playerData)
			if not validatePlayer(player) then
				return
			end

			local start = self._sessionStart[player]
			if not start then
				return
			end

			local elapsed = os.time() - start
			self._sessionStart[player] = os.time()

			if elapsed <= 0 then
				return
			end

			PlayerDataManager:SetPlayerDataKey(player, "TotalPlaytime", (playerData.TotalPlaytime or 0) + elapsed)
		end)
		:catch(function(error)
			warn(`[PlaytimeManager] Failed to flush playtime for {player.Name}: {error}`)
		end)
end

function PlaytimeManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)

	Players.PlayerAdded:Connect(function(player: Player)
		self._sessionStart[player] = os.time()
		self._joinTime[player] = os.time()
	end)

	PlayerDataManager:RegisterPreCleanupCallback(function(player: Player, playerData: { any })
		self:_flush(player, playerData)
		self._sessionStart[player] = nil

		local joinTime = self._joinTime[player]
		self._joinTime[player] = nil
		if joinTime then
			self.OnSessionEnded:Fire(player, os.time() - joinTime, playerData.TotalPlaytime or 0)
		end
	end)
end

function PlaytimeManager:OnStart()
	-- Seed players already present (e.g. on a server hot-reload).
	for _, player in Players:GetPlayers() do
		if self._sessionStart[player] == nil then
			self._sessionStart[player] = os.time()
		end
		if self._joinTime[player] == nil then
			self._joinTime[player] = os.time()
		end
	end

	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)
			for _, player in Players:GetPlayers() do
				self:_flushLive(player)
			end
		end
	end)
end

return PlaytimeManager
