-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local ReplayFormat = require(Shared.ReplayFormat)

-- Managers
local TutorialManager = require(script.Parent.TutorialManager)
local FtueLogManager = require(script.Parent.FtueLogManager)

-- The experience config that turns recording on, and the player attribute the recorder reads it off. Its own
-- key rather than LogFTUE's, so the replay can be switched off without touching the reporting that already works
local CONFIG_KEY = "LogFTUEReplay"

-- The step a track is kept up to, and the one that closes it unsaved. Mirrors FtueLogManager
local REPORTED_STEP = "Build Griller"

-- The share of new players a track is kept for. Its own knob, so the motion track can be thinned without
-- touching the reporting -- a track costs its player five samples a second, and they are the newest devices last
local SAMPLE_RATE = 1

-- Samples one track holds before the oldest go. At 5/s that's six minutes, far past where a drop happens
local MAX_TRACK_SAMPLES = 1800
-- Dropped in one block rather than one at a time: removing an array's first element copies the whole array,
-- and at five samples a second on a full track that is a shift of 1800 five times over, every second
local TRIM_BLOCK = 300
-- Samples taken from one batch, which is also the most ReplayRecorderController sends
local MAX_BATCH = 16

-- Where finished tracks land. Its own store, so nothing here can touch player data
local REPLAY_STORE_NAME = "FtueReplay"
-- Live and Studio write to different stores, so a playtest can never land a record among the real ones
local STUDIO_STORE_NAME = "FtueReplayStudio"

-- Records are read by key typed into a command, so the key has to be short enough to copy out of Discord
local KEY_FORMAT = "%d_%d"

-- The most a viewer may ask for at once, since a load hands the whole track over in one reply
local MAX_LOAD_SAMPLES = 3000

-- Keeps a motion track for each new player and saves it only for the ones who drop, which FtueLogManager asks
-- for as it builds its report. Everything here is off the gameplay path: the samples arrive on their own remote,
-- the save runs deferred, and with the config off not a single sample is kept.
local ReplayManager = {
	LogReplaySamplesEvent = Network.Event("LogReplaySamples", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 5 },
		Validate = function(_player, samples)
			return type(samples) == "table"
		end,
	}),

	-- The viewer is entirely client-side, so these only hand a loaded recording over and take it back again
	PlayReplayEvent = Network.Event("PlayReplay", { Direction = "ServerToClient" }),
	StopReplayEvent = Network.Event("StopReplay", { Direction = "ServerToClient" }),

	_tracks = {}, -- [player] = { Samples }, the run kept for a player still short of the reported step
	_store = nil, -- the DataStore tracks are saved to, nil where DataStores aren't reachable
}

-- Whether the LogFTUEReplay config is on. Read off FtueLogManager's snapshot rather than a second fetch of
-- this server's own, so there's one config to retry and one to fail.
function ReplayManager:_isEnabled(): boolean
	return FtueLogManager:GetConfigValue(CONFIG_KEY) == true
end

-- Drops a player's track and tells their client to stop sampling.
function ReplayManager:_stopRecording(player: Player)
	self._tracks[player] = nil
	player:SetAttribute(CONFIG_KEY, nil)
end

-- Opens a track at the tutorial's first step and closes it unsaved once the player is past the reported one.
function ReplayManager:_onFunnelStep(player: Player, _variant: string, stepIndex: number, stepName: string)
	if stepIndex == 1 and self:_isEnabled() and math.random() < SAMPLE_RATE then
		self._tracks[player] = { Samples = {} }
		player:SetAttribute(CONFIG_KEY, true)
		return
	end

	if stepName == REPORTED_STEP then
		self:_stopRecording(player)
	end
end

-- Takes one batch of a player's motion track. Every sample is untrusted and is bound for a DataStore and then
-- a viewer's renderer, so anything misshapen is dropped rather than stored.
function ReplayManager:RecordReplaySamples(player: Player, samples: { any })
	local track = self._tracks[player]
	if not track then
		return
	end

	-- The switch going off mid-run ends the run, rather than leaving the client sampling into nothing
	if not self:_isEnabled() then
		self:_stopRecording(player)
		return
	end

	for index = 1, math.min(#samples, MAX_BATCH) do
		local sample = samples[index]
		if not ReplayFormat.IsValidSample(sample) then
			continue
		end

		table.insert(track.Samples, sample)

		-- One copy per block of samples rather than one per sample, which is what keeps this flat
		if #track.Samples > MAX_TRACK_SAMPLES + TRIM_BLOCK then
			track.Samples = table.move(track.Samples, TRIM_BLOCK + 1, #track.Samples, 1, {})
		end
	end
end

-- Hands a player's track over and forgets it, so the caller owns it from here. Never yields, which is what lets
-- FtueLogManager call it from inside the pre-cleanup callback.
function ReplayManager:TakeTrack(player: Player)
	local track = self._tracks[player]
	self:_stopRecording(player)

	if not (track and #track.Samples > 0) then
		return nil
	end

	return track
end

-- Saves a taken track against the trail that describes it, answering the key a viewer loads it by. Yields on the
-- DataStore and can throw, so it's only ever called deferred under a pcall.
function ReplayManager:SaveDropReplay(track, trail): string?
	if not self._store then
		return nil
	end

	local key = string.format(KEY_FORMAT, os.time(), trail.UserId)

	self._store:SetAsync(key, {
		Version = ReplayFormat.VERSION,
		SampleRate = ReplayFormat.SAMPLE_RATE,
		UserId = trail.UserId,
		Username = trail.Username,
		Variant = trail.Variant,
		Platform = trail.Platform,
		RecordedAt = os.time(), -- DataStores have no expiry of their own, so a sweep reads this
		StepEnteredAt = trail.StepAt - trail.StartedAt,
		Duration = trail.EndedAt - trail.StartedAt,
		Samples = track.Samples,
		Events = trail.Entries,
	})

	return key
end

-- Reads one saved recording back for the viewer. Yields on the DataStore and can throw, so the command pcalls it.
function ReplayManager:LoadReplay(key: string)
	if not self._store then
		return nil, "no DataStore is reachable from this server"
	end

	local record = self._store:GetAsync(key)
	if not record then
		return nil, `no recording is stored under "{key}"`
	end

	if record.Version ~= ReplayFormat.VERSION then
		return nil, `recording is format {tostring(record.Version)}, this build reads {ReplayFormat.VERSION}`
	end

	if #record.Samples > MAX_LOAD_SAMPLES then
		return nil, `recording holds {#record.Samples} samples, more than the {MAX_LOAD_SAMPLES} a load sends`
	end

	return record, nil
end

-- Hands a loaded recording to one viewer's client, which owns every part of playing it back.
function ReplayManager:SendReplayToViewer(player: Player, record)
	self.PlayReplayEvent:FireClient(player, record)
end

-- Tells one viewer's client to tear its replay down.
function ReplayManager:StopReplayForViewer(player: Player)
	self.StopReplayEvent:FireClient(player)
end

function ReplayManager:OnInit()
	-- Held here rather than resolved per call, and left nil where DataStores can't be reached at all
	local opened, store = pcall(function()
		return DataStoreService:GetDataStore(if RunService:IsStudio() then STUDIO_STORE_NAME else REPLAY_STORE_NAME)
	end)

	self._store = if opened then store else nil

	if not opened then
		warn("[ReplayManager] no DataStore access, so recordings can't be saved or loaded")
	end
end

function ReplayManager:OnStart()
	-- Registered rather than required back, so a fault here can never stop a drop report going out
	FtueLogManager:SetReplayProvider(self)

	self.LogReplaySamplesEvent:OnServerEvent(function(player: Player, samples: { any })
		self:RecordReplaySamples(player, samples)
	end)

	TutorialManager.OnFunnelStep:Connect(function(player: Player, variant: string, stepIndex: number, stepName: string)
		self:_onFunnelStep(player, variant, stepIndex, stepName)
	end)

	-- A track whose player left without dropping is never asked for, so this is what stops them piling up.
	-- Deferred, since FtueLogManager takes the track from inside this same leave, and the order of two
	-- PlayerRemoving handlers is not something to depend on
	Players.PlayerRemoving:Connect(function(player: Player)
		task.defer(function()
			self._tracks[player] = nil
		end)
	end)
end

return ReplayManager
