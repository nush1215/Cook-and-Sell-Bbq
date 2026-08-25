--
local Rolling = {}

-- Shape of the roll animation. The cycle steps through random ingredients, waiting a little
-- longer each step so it decelerates onto the final one.
Rolling.CYCLE_STEPS = 26
Rolling.CYCLE_INITIAL_WAIT = 0.03
Rolling.CYCLE_WAIT_INCREMENT = 0.0062
Rolling.CYCLE_MAX_WAIT = 0.5
Rolling.INTRO_DURATION = 0.25

-- The gap between a stand's Base part top and the resting ingredient's base. The ingredient's own
-- height is added on top of this at runtime (see Stand._getLandingCFrame), so it sits on the stand
-- with a little breathing room whatever its size, rather than at a fixed offset.
Rolling.LANDING_GAP = 2

-- How near the local player has to be to a base for its rolls to draw, measured from their character
-- to its lever. A roll clones a model per cycle step per stand, so every base in the server animating
-- at once is the one thing here that could sink the frame rate. Inside ANIMATE_DISTANCE a roll plays
-- in full; between that and RENDER_DISTANCE it skips the cycle and its result just lands, which costs
-- one clone instead of twenty-seven; past RENDER_DISTANCE the stands hold nothing at all.
Rolling.ANIMATE_DISTANCE = 120
Rolling.RENDER_DISTANCE = 250

-- Added to both distances before a base drops back out of the band it's in, so a player stood on a
-- boundary doesn't spawn and destroy the same models on every sweep.
Rolling.DISTANCE_HYSTERESIS = 25

-- How often the bands above are re-checked. Nobody walks far enough in a frame for this to need
-- driving per frame, and the sweep touches every base in the place.
Rolling.PROXIMITY_INTERVAL = 0.25

-- How late a pull can be picked up and still be worth cycling. The cycle always takes the full roll
-- duration, so one started halfway through would land that much after the pull it belongs to -- by
-- which point the owner may already have bought what it's cycling towards. Anyone who arrives past
-- this just gets the result seated. Sized well past a bad ping so a client's own pull always animates.
Rolling.ROLL_ANIMATION_GRACE = 0.5

-- Wall-clock length of the roll animation exactly as authored above, summed from the same constants
-- the client loops on so retuning the cycle can't leave this behind. It's the yardstick the speed
-- levels below are scaled against rather than a duration anything plays at -- the level 1 rung is
-- the slowest a roll ever runs, and it's a touch longer than this.
Rolling.AUTHORED_DURATION = (function(): number
	local duration = Rolling.INTRO_DURATION
	local waitTime = Rolling.CYCLE_INITIAL_WAIT

	-- The last step lands the real ingredient and doesn't wait, hence the -1.
	for _ = 1, Rolling.CYCLE_STEPS - 1 do
		duration += waitTime
		waitTime = math.min(waitTime + Rolling.CYCLE_WAIT_INCREMENT, Rolling.CYCLE_MAX_WAIT)
	end

	return duration
end)()

-- The RollSpeed upgrade ladder (Unlocks.RollSpeed in player data): each level shaves DURATION_STEP
-- off how long one pull takes, from SLOWEST_DURATION down to FASTEST_DURATION. Tuned from these three
-- numbers alone -- the table below is generated, so the rungs can't drift from the ends.
--
-- The ladder's length has to match the RollSpeed entry's Limit and Costs in Config.BaseUnlocks, which
-- are hand-authored. GetRollDuration clamps, so a drift between them reads as the nearest rung rather
-- than erroring on a level with no duration.
Rolling.SLOWEST_DURATION = 3
Rolling.FASTEST_DURATION = 1
Rolling.DURATION_STEP = 0.1

Rolling.LEVEL_DURATIONS = {} -- [level] = seconds one roll takes at that level
for level = 1, math.round((Rolling.SLOWEST_DURATION - Rolling.FASTEST_DURATION) / Rolling.DURATION_STEP) + 1 do
	Rolling.LEVEL_DURATIONS[level] = Rolling.SLOWEST_DURATION - (level - 1) * Rolling.DURATION_STEP
end

table.freeze(Rolling.LEVEL_DURATIONS)

-- Wall-clock length of one roll at the given RollSpeed level. The server gates claims and the roll
-- debounce on this and the client cycles at the matching scale below, so the two can't desync.
-- Clamped rather than indexed straight: a roll saved before the upgrade existed carries no level, and
-- one nudged past the cap from the command bar would otherwise have no duration at all.
function Rolling.GetRollDuration(level: number?): number
	return Rolling.LEVEL_DURATIONS[math.clamp(level or 1, 1, #Rolling.LEVEL_DURATIONS)]
end

-- How much of the authored cycle's timing one roll at this level plays at. The client multiplies this
-- into every wait its cycle takes, which is what lands the animation on GetRollDuration -- measured
-- against the authored length rather than a fixed number, so retuning the cycle re-derives it.
function Rolling.GetSpeedScale(level: number?): number
	return Rolling.GetRollDuration(level) / Rolling.AUTHORED_DURATION
end

return Rolling
