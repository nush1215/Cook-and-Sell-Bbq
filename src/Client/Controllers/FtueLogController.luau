-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

-- Controllers
local BuildController = require(script.Parent.BuildController)
local InputController = require(script.Parent.InputController)

--
local LocalPlayer = Players.LocalPlayer

-- Set by FtueLogManager while it keeps this player's trail; without it nothing is recorded or sent
local ENABLED_ATTRIBUTE = "LogFTUE"

-- Seconds a batch gathers for, so a burst of ghost flicker is one remote rather than dozens
local FLUSH_INTERVAL = 1
-- Entries one batch holds before the rest are dropped; FtueLogManager takes no more than this either
local MAX_BATCH = 32

-- The client half of the FTUE trail: hears what the build ghost is doing and hands it to the server in batches. It only listens to BuildController's signals, so with the attribute off an event costs one comparison.
local FtueLogController = {
	LogFtueTrailEvent = Network.Event("LogFtueTrail"),

	_pending = {}, -- { { os.clock(), kind, detail? } } waiting on the next flush
	_flushScheduled = false,
}

-- Queues one trail entry and schedules the batch it rides in. A no-op unless the server is keeping this player's trail.
function FtueLogController:RecordFtueEvent(kind: string, detail: string?)
	if LocalPlayer:GetAttribute(ENABLED_ATTRIBUTE) ~= true or #self._pending >= MAX_BATCH then
		return
	end

	table.insert(self._pending, { os.clock(), kind, detail })

	if self._flushScheduled then
		return
	end
	self._flushScheduled = true

	task.delay(FLUSH_INTERVAL, function()
		local now = os.clock()
		local entries = self._pending

		-- Reset ahead of the send, so a fire that errors can't leave the flag stuck and the trail silent
		self._pending = {}
		self._flushScheduled = false

		-- Sent as ages rather than clock readings, the two machines' clocks sharing no zero
		for _, entry in entries do
			entry[1] = now - entry[1]
		end

		self.LogFtueTrailEvent:FireServer(InputController:GetPreferredInput().Name, entries)
	end)
end

function FtueLogController:OnStart()
	BuildController.OnPlacementStarted:Connect(function(structureId: string)
		self:RecordFtueEvent("equip", structureId)
	end)
	BuildController.OnPlacementEnded:Connect(function()
		self:RecordFtueEvent("unequip")
	end)
	BuildController.OnGhostRefusalChanged:Connect(function(refusal: string?)
		self:RecordFtueEvent("ghost", refusal)
	end)
	BuildController.OnPlaceAttempted:Connect(function(refusal: string?)
		self:RecordFtueEvent("click", refusal)
	end)
	BuildController.OnGhostRotated:Connect(function()
		self:RecordFtueEvent("rotate")
	end)
end

return FtueLogController
