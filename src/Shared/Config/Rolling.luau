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

-- Wall-clock length of one roll animation, summed from the same constants the client loops on.
-- The server gates claims and the roll debounce on this, so retuning the animation can't
-- silently desync the two.
function Rolling.GetRollDuration(): number
	local duration = Rolling.INTRO_DURATION
	local waitTime = Rolling.CYCLE_INITIAL_WAIT

	-- The last step lands the real ingredient and doesn't wait, hence the -1.
	for _ = 1, Rolling.CYCLE_STEPS - 1 do
		duration += waitTime
		waitTime = math.min(waitTime + Rolling.CYCLE_WAIT_INCREMENT, Rolling.CYCLE_MAX_WAIT)
	end

	return duration
end

return Rolling
