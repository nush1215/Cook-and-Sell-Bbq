-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

-- Teleports idle players into a fresh server, freeing their slot. AfkController owns the detection.
local AfkManager = {
	ReportAfkEvent = Network.Event("ReportAfk"),

	_teleporting = {}, -- [player] = true while a TeleportAsync for them is in flight
}

-- Sends an idle player to a new server. TeleportAsync always fails in Studio, so that warn is expected.
function AfkManager:ReturnPlayerToNewServer(player: Player)
	-- Authoritative guard: a spammed remote shouldn't be able to queue a teleport per frame
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
