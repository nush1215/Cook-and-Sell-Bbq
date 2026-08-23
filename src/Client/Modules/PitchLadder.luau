--
local PitchLadder = {}
PitchLadder.__index = PitchLadder

export type Config = {
	Base: number?,
	Increment: number?,
	Max: number?,
	ResetSeconds: number?,
	MaxHits: number?,
}

type State = { pitch: number, lastUsed: number, maxHits: number }

export type PitchLadder = typeof(setmetatable(
	{} :: {
		Base: number,
		Increment: number,
		Max: number,
		ResetSeconds: number,
		MaxHits: number,
		states: { [any]: State },
	},
	PitchLadder
))

local DEFAULTS = {
	Base = 1,
	Increment = 0.05,
	Max = 2,
	ResetSeconds = 1.5,
	MaxHits = 5,
}

-- Creates a pitch ladder that ramps PlaybackSpeed up on consecutive hits and resets after a pause.
-- @param config: Optional overrides for Base/Increment/Max/ResetSeconds/MaxHits
function PitchLadder.new(config: Config?): PitchLadder
	local config = config or {}

	return setmetatable({
		Base = config.Base or DEFAULTS.Base,
		Increment = config.Increment or DEFAULTS.Increment,
		Max = config.Max or DEFAULTS.Max,
		ResetSeconds = config.ResetSeconds or DEFAULTS.ResetSeconds,
		MaxHits = config.MaxHits or DEFAULTS.MaxHits,
		states = {},
	}, PitchLadder)
end

-- Advances the ladder for the given key and returns the pitch to play.
-- Each key (plot, player, etc.) ramps independently; a pause longer than ResetSeconds restarts it at base.
-- @param key: Any value identifying the independent ramp (Model, Player, etc.)
function PitchLadder.Next(self: PitchLadder, key: any): number
	local now = os.clock()
	local state = self.states[key]

	if not state or (now - state.lastUsed) > self.ResetSeconds then
		state = { pitch = self.Base, lastUsed = now, maxHits = 0 }
		self.states[key] = state
	else
		state.lastUsed = now
		state.pitch = math.min(state.pitch + self.Increment, self.Max)

		-- Once the pitch has played at max enough times, drop back down to the base.
		if state.pitch >= self.Max then
			state.maxHits += 1
			if state.maxHits > self.MaxHits then
				state.pitch = self.Base
				state.maxHits = 0
			end
		end
	end

	return state.pitch
end

return PitchLadder
