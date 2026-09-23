-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local ReplayFormat = require(Shared.ReplayFormat)

-- Controllers
local BuildController = require(script.Parent.BuildController)

--
local LocalPlayer = Players.LocalPlayer

-- Set by ReplayManager while it keeps this player's motion track. Its own attribute rather than the FTUE
-- trail's, so the replay can be turned off on its own and the reporting that already works is left alone
local ENABLED_ATTRIBUTE = "LogFTUEReplay"

-- Samples a second, matched to the format's stride so the viewer can seek by multiplying
local SAMPLE_INTERVAL = 1 / ReplayFormat.SAMPLE_RATE

-- Seconds a batch gathers for, so a run of samples is one remote rather than five
local FLUSH_INTERVAL = 1

-- Samples one batch holds before the rest are dropped; ReplayManager takes no more than this either
local MAX_BATCH = 16

-- The client half of the replay: samples where the player is, where they're looking and what the build ghost
-- says, then hands the run to the server once a second. Nothing is recorded unless the server has asked for it,
-- so with the attribute unset every frame costs one comparison.
local ReplayRecorderController = {
	LogReplaySamplesEvent = Network.Event("LogReplaySamples"),

	_pending = {}, -- packed sample arrays waiting on the next flush
	_sinceSample = 0,
	_sinceFlush = 0,
	_fps = 0,
	_connection = nil, -- the sampling loop, held only while the server is asking for samples
}

-- Takes one sample, or nothing at all before the base's floors have streamed in and given it an origin to
-- measure against. Everything is base-relative, so the recording plays back on whichever base the viewer uses.
function ReplayRecorderController:_sample()
	local origin = BuildController:GetGroundOrigin()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (origin and root) then
		return
	end

	local camera = workspace.CurrentCamera
	local placement = BuildController:GetPlacementSnapshot()

	-- Turned into the base's frame, which is also the frame the cells and the viewer's rebuild are in
	local localRoot = origin:ToObjectSpace(root.CFrame)
	local localCamera = origin:ToObjectSpace(camera.CFrame)
	local _, rootYaw = localRoot:ToOrientation()
	local cameraPitch, cameraYaw = localCamera:ToOrientation()

	local uiFlags = 0
	if placement.GuideShown then
		uiFlags += ReplayFormat.UiFlag.Guide
	end
	if placement.InvalidShown then
		uiFlags += ReplayFormat.UiFlag.Invalid
	end

	-- Built in ReplayFormat.Field order, rounded here rather than at the store so the wire carries it once
	local round = ReplayFormat.Round
	local positionDecimals = ReplayFormat.POSITION_DECIMALS
	local angleDecimals = ReplayFormat.ANGLE_DECIMALS

	table.insert(self._pending, {
		round(localRoot.X, positionDecimals),
		round(localRoot.Y, positionDecimals),
		round(localRoot.Z, positionDecimals),
		round(math.deg(rootYaw), angleDecimals),
		round(localCamera.X, positionDecimals),
		round(localCamera.Y, positionDecimals),
		round(localCamera.Z, positionDecimals),
		round(math.deg(cameraYaw), angleDecimals),
		round(math.deg(cameraPitch), angleDecimals),
		placement.CellX or ReplayFormat.NO_CELL,
		placement.CellZ or ReplayFormat.NO_CELL,
		placement.Rotation,
		ReplayFormat.StateFromRefusal(placement.Placing, placement.Refusal),
		math.round(self._fps),
		uiFlags,
	})
end

-- One frame of the sampling loop, which only runs at all while the server is asking for samples.
function ReplayRecorderController:_step(deltaTime: number)
	self._fps = if deltaTime > 0 then 1 / deltaTime else self._fps

	self._sinceSample += deltaTime
	if self._sinceSample >= SAMPLE_INTERVAL then
		-- Carried over rather than zeroed. A device whose frames are longer than the interval would otherwise
		-- sample slower than it claims to, and the viewer reads the track at a fixed stride -- so the replay
		-- would play back faster than the session really ran, on exactly the devices worth watching.
		-- Clamped, or a loading hitch pays itself back as a burst over the frames after it
		self._sinceSample = math.min(self._sinceSample - SAMPLE_INTERVAL, SAMPLE_INTERVAL)

		if #self._pending < MAX_BATCH then
			self:_sample()
		end
	end

	self._sinceFlush += deltaTime
	if self._sinceFlush < FLUSH_INTERVAL then
		return
	end
	self._sinceFlush = 0

	if #self._pending == 0 then
		return
	end

	local batch = self._pending
	self._pending = {}
	self.LogReplaySamplesEvent:FireServer(batch)
end

-- Starts or stops the loop to match the attribute. Held off entirely while nothing is being recorded, so a
-- player the server never asked about pays no per-frame cost at all.
function ReplayRecorderController:_refresh()
	local wanted = LocalPlayer:GetAttribute(ENABLED_ATTRIBUTE) == true

	if wanted == (self._connection ~= nil) then
		return
	end

	if not wanted then
		self._connection:Disconnect()
		self._connection = nil

		-- Anything gathered before the server closed the track has nowhere to go
		table.clear(self._pending)
		return
	end

	self._sinceSample = 0
	self._sinceFlush = 0
	self._connection = RunService.RenderStepped:Connect(function(deltaTime: number)
		self:_step(deltaTime)
	end)
end

function ReplayRecorderController:OnStart()
	LocalPlayer:GetAttributeChangedSignal(ENABLED_ATTRIBUTE):Connect(function()
		self:_refresh()
	end)

	-- The attribute can already be set, the server having opened the track before this ran
	self:_refresh()
end

return ReplayRecorderController
