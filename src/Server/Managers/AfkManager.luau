-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

-- Moves players whose client has reported them idle into a fresh server of this place, freeing the
-- slot they were holding. AfkController owns the 15 minute detection; this side owns the teleport.
local AfkManager = {
	ReportAfkEvent = Network.Event("ReportAfk"),

	_teleporting = {}, -- [player] = true while a TeleportAsync for them is in flight
}

-- Sends an idle player into a new server of this same place. TeleportAsync always fails in Studio, so
-- the warn there is expected rather than a fault.
function AfkManager:ReturnPlayerToNewServer(player: Player)
	-- Authoritative guard: the client resets its own timer after reporting, but a spammed remote
	-- shouldn't be able to queue a teleport per frame
	if self._teleporting[player] then
		return
	end

	self._teleporting[player] = true

	local success, err = pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, { player })
	if not success then
		warn(`[AfkManager] AFK teleport errored for {player.Name}: {err}`)
		self._teleporting[player] = nil
	end
end

function AfkManager:OnStart()
	self.ReportAfkEvent:OnServerEvent(function(player: Player)
		self:ReturnPlayerToNewServer(player)
	end)

	-- A teleport that never lands leaves the player sat here; clear the guard so a later report retries.
	TeleportService.TeleportInitFailed:Connect(function(player: Player, result: Enum.TeleportResult, message: string)
		warn(`[AfkManager] AFK teleport failed for {player.Name}: {result.Name} - {message}`)
		self._teleporting[player] = nil
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._teleporting[player] = nil
	end)
end

return AfkManager
