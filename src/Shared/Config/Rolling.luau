--
local Rolling = {}

-- Shape of the roll animation: each step waits a little longer, so it decelerates onto the final one
Rolling.CYCLE_STEPS = 26
Rolling.CYCLE_INITIAL_WAIT = 0.03
Rolling.CYCLE_WAIT_INCREMENT = 0.0062
Rolling.CYCLE_MAX_WAIT = 0.5
Rolling.INTRO_DURATION = 0.25

-- The gap above the stand's top; the ingredient's own height is added at runtime, so any size sits right
Rolling.LANDING_GAP = 2

-- The distance bands a base draws in: full cycle inside ANIMATE, result-only to RENDER, nothing past it
Rolling.ANIMATE_DISTANCE = 120
Rolling.RENDER_DISTANCE = 250

-- Widens the band a base is already in, so a player on a boundary doesn't thrash the models
Rolling.DISTANCE_HYSTERESIS = 25

-- How often the bands are re-checked -- nobody walks far in a frame, and the sweep touches every base
Rolling.PROXIMITY_INTERVAL = 0.25

-- How late a pull can still be worth cycling; past this the result just lands. Sized well past a bad ping
Rolling.ROLL_ANIMATION_GRACE = 0.5

-- The authored cycle's length, summed from the same constants the client loops on. The yardstick the speed levels scale against, not a duration anything plays at.
Rolling.AUTHORED_DURATION = (function(): number
	local duration = Rolling.INTRO_DURATION
	local waitTime = Rolling.CYCLE_INITIAL_WAIT

	-- The last step lands the real ingredient and doesn't wait, hence the -1
	for _ = 1, Rolling.CYCLE_STEPS - 1 do
		duration += waitTime
		waitTime = math.min(waitTime + Rolling.CYCLE_WAIT_INCREMENT, Rolling.CYCLE_MAX_WAIT)
	end

	return duration
end)()

-- The RollSpeed ladder, generated from three numbers so the rungs can't drift from the ends. Its length must match the RollSpeed entry in BaseUnlocks, which is hand-authored.
Rolling.SLOWEST_DURATION = 3
Rolling.FASTEST_DURATION = 1
Rolling.DURATION_STEP = 0.1

Rolling.LEVEL_DURATIONS = {} -- [level] = seconds one roll takes at that level
for level = 1, math.round((Rolling.SLOWEST_DURATION - Rolling.FASTEST_DURATION) / Rolling.DURATION_STEP) + 1 do
	Rolling.LEVEL_DURATIONS[level] = Rolling.SLOWEST_DURATION - (level - 1) * Rolling.DURATION_STEP
end

table.freeze(Rolling.LEVEL_DURATIONS)

-- One roll's length at `level`. The claim gate and the client's cycle both read it, so they can't desync. Clamped, for a roll saved before the upgrade existed.
function Rolling.GetRollDuration(level: number?): number
	return Rolling.LEVEL_DURATIONS[math.clamp(level or 1, 1, #Rolling.LEVEL_DURATIONS)]
end

-- What the client multiplies each cycle wait by to land on GetRollDuration, so retuning re-derives it.
function Rolling.GetSpeedScale(level: number?): number
	return Rolling.GetRollDuration(level) / Rolling.AUTHORED_DURATION
end

return Rolling
