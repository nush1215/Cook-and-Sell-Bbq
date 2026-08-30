--[[
    The states a skewer passes through on a grill: three bands along the cooking bar, then two more only
    a skewer nobody came back for reaches.

    The first three are fixed fractions of the 0-1 bar, so a client reads them straight off the progress
    it already derives from CookStartedAt. Only the bar's length varies per skewer.

    Past the end of the bar, states take over on `Overtime` -- wall-clock seconds rather than a fraction,
    so a quick skewer and a slow one get the same time to notice and react.

    Multiplier is what getting it right is worth; Tint darkens the cooked models so a bad cook is visible
    without a third set of them. The offer fields drive how a customer haggles over that quality
    (SellNpcManager): where it opens, how willing it is to be pushed, and how far it can be pushed to.
]]

--
local CookStates = {}

-- Where the bands meet on the 0-1 cooking bar. RAW_END also sizes the cook itself: an ingredient's
-- CookTime is the seconds until it first reads cooked, so a run is that stretched over the whole bar.
-- Widening the gap between the two is what makes the window more forgiving.
CookStates.RAW_END = 0.6
CookStates.PERFECT_END = 0.85

-- How far a charred part's colour is dragged toward its state's Tint. Short of 1, so a charred skewer
-- still reads as its ingredients rather than a flat black lump.
CookStates.BURNT_STRENGTH = 0.65

-- The most an unstable grill's cook rate may swing either side of 1. At exactly 1 the bar stalls dead at
-- the bottom of a cycle; past it the bar runs BACKWARDS, un-browning food and letting a stop settle a
-- state the player watched go by. Clamped where it's read, not where it's authored, so a typo can't.
CookStates.MAX_INSTABILITY = 0.9

-- Target length of one surge-and-stall. A target, not the actual period: GetBarElapsed rounds the bar to
-- a whole number of cycles, which is what puts it back on exactly cookTime. Seconds rather than a
-- fraction, so the lurch reads the same on a short skewer as on a long one.
CookStates.INSTABILITY_PERIOD = 4

-- How far either side of a point GetBarRate samples the bar to read its slope. A frame, so the sample
-- spans what the eye does; much finer and the difference of two near-equal seconds is float noise.
local RATE_EPSILON = 1 / 60

export type CookState = {
	Id: string, -- also the name of the UIGradient it lights on the cooking bar's title ("{Id}Gradient")
	Name: string, -- how that title reads
	End: number?, -- where this band ends on the 0-1 bar; the last one ends at 1. Nil past the bar
	Overtime: number?, -- seconds after the bar fills that this state takes over. Nil on the bar itself
	Multiplier: number, -- what a skewer in this state sells for, as a multiple of its ingredient value
	OfferMin: number, -- the customer's opening offer, as a multiple of that sell value
	OfferMax: number,
	CounterChance: number, -- chance out of 100 that declining gets a better price rather than a walk-off
	CounterCap: number, -- the most a customer can ever be haggled to, as a multiple of that sell value
	Icon: string, -- rbxassetid for this state's badge: a skewer's inventory slot and its held billboard
	Color: Color3, -- the [COOKED] tag's colour on the tooltip that slot pops up
	BarColor: Color3, -- what the cooking bar's fill turns while the skewer is in this state
	Tint: Color3?, -- what its cooked models darken toward, or nil to leave them as they are
	Notification: { Text: string, Sound: string, Effect: string }?, -- the toast on stopping here, if any
}

-- Ordered along the cook. Every OfferMin sits at or above 1, so an offer never comes in under the estimate
-- the player was shown; a bad cook is punished through Multiplier rather than a second lowball on top.
-- OfferMax must stay above its own OfferMin -- the pair goes straight to Random:NextNumber.
--
-- CounterCap must sit above OfferMax, and the gap between them is the whole negotiation: each round closes
-- a fraction of the distance left to the cap. That gap narrows down the quality ladder (0.2x perfect to
-- 0.05x raw), which is why the cap is per state -- one global cap would let a charred skewer haggle harder
-- than a perfect one. Keep some gap even at the bottom, or a counter spends a bubble and moves nothing.
CookStates.Data = {
	{
		Id = "Raw",
		Name = "Raw",
		End = CookStates.RAW_END,
		-- A raw skewer barely clears what its ingredients cost -- a loss to eat, not a wall to hit.
		-- CounterChance is higher than it deserves because this is what a brand-new player is selling and
		-- the counter-offer has to be shown rather than told. The cap keeps that honest: 0.05x of headroom
		-- moves the price by under 1%, so they meet the mechanic without raw skewers becoming worth haggling.
		Multiplier = 1,
		OfferMin = 1,
		OfferMax = 1.05,
		CounterChance = 30,
		CounterCap = 1.1,
		Icon = "rbxassetid://85040089054254",
		Color = Color3.fromRGB(255, 120, 180),
		BarColor = Color3.fromRGB(255, 219, 248),
		-- The one toast about what *didn't* happen: the cook is banked, not lost, and the next light picks
		-- it back up. A success, since the alternative is the whole cook going in the bin.
		Notification = { Text = "Pulled off early, cook saved", Sound = "Notify", Effect = "Success" },
	},
	{
		Id = "Perfect",
		Name = "Perfectly Cooked",
		End = CookStates.PERFECT_END,
		-- The baseline every ingredient price is tuned against, not a bonus on top of one.
		Multiplier = 1.8,
		OfferMin = 1.1,
		OfferMax = 1.35,
		CounterChance = 90,
		CounterCap = 1.55,
		Icon = "rbxassetid://95690801659667",
		Color = Color3.fromRGB(255, 200, 80),
		BarColor = Color3.fromRGB(85, 255, 0),
		Notification = { Text = "Perfectly cooked BBQ!", Sound = "Notify", Effect = "Success" },
	},
	{
		Id = "Cooked",
		Name = "Cooked",
		End = 1,
		-- Overshooting is a nick, not a penalty: a player who looked away still has a skewer worth selling.
		Multiplier = 1.35,
		OfferMin = 1.05,
		OfferMax = 1.3,
		CounterChance = 80,
		CounterCap = 1.45,
		Icon = "rbxassetid://100459885373694",
		Color = Color3.fromRGB(214, 158, 74),
		BarColor = Color3.fromRGB(255, 200, 60),
		Notification = { Text = "Nicely cooked BBQ!", Sound = "Notify", Effect = "Success" },
	},
	{
		Id = "Overcooked",
		Name = "Overcooked",
		Overtime = 20,
		-- Past the bar the haggle narrows rather than the offer dipping under the estimate.
		Multiplier = 0.9,
		OfferMin = 1,
		OfferMax = 1.15,
		CounterChance = 50,
		CounterCap = 1.26,
		Icon = "rbxassetid://139591923454709",
		Color = Color3.fromRGB(150, 88, 60),
		BarColor = Color3.fromRGB(200, 70, 30),
		Tint = Color3.fromRGB(86, 55, 38),
		Notification = { Text = "You overcooked your BBQ!", Sound = "Reject", Effect = "Error" },
	},
	{
		Id = "Charred",
		Name = "Charred",
		Overtime = 60,
		-- The narrowest range of any state, and the narrowness lives in the cap rather than the chance: a
		-- customer counters happily, there's just nothing above 1.05 to reach into. A counter that visibly
		-- moves nothing teaches the state's worth better than a roll that silently fails.
		Multiplier = 0.8,
		OfferMin = 1,
		OfferMax = 1.05,
		CounterChance = 40,
		CounterCap = 1.14,
		Icon = "rbxassetid://117732140813353",
		Color = Color3.fromRGB(92, 62, 48),
		BarColor = Color3.fromRGB(60, 20, 18),
		Tint = Color3.fromRGB(25, 18, 14),
		Notification = { Text = "You burnt your BBQ to a crisp!", Sound = "Reject", Effect = "Error" },
	},
}

table.freeze(CookStates.Data)

-- Where the bands meet, in order. The cooking bar marks each, so the window can be seen coming rather
-- than only read off the title. Derived rather than authored again, so a new state marks itself. Only
-- states on the bar get one -- the ones past it are timed rather than positioned.
CookStates.BOUNDARIES = {}
for _, state in CookStates.Data do
	if state.End and state.End < 1 then
		table.insert(CookStates.BOUNDARIES, state.End)
	end
end

table.freeze(CookStates.BOUNDARIES)

function CookStates.GetStateFromId(id: string): CookState?
	for _, state in CookStates.Data do
		if state.Id == id then
			return state
		end
	end

	return nil
end

function CookStates.GetAllStates(): { CookState }
	return CookStates.Data
end

-- Which state a cook is in `elapsed` seconds into a bar of `cookTime` seconds: the band the progress falls
-- in, or past the bar, however many Overtime states have come round. Takes raw seconds rather than a
-- pre-clamped progress, so the server's stop and the client's bar derive it the same way.
function CookStates.GetStateFromCook(elapsed: number, cookTime: number): string
	local overtime = elapsed - cookTime

	if overtime < 0 then
		local progress = math.max(elapsed, 0) / cookTime
		for _, state in CookStates.Data do
			if state.End and progress < state.End then
				return state.Id
			end
		end
	end

	-- Past the bar: walk back to the last state whose grace period has run out. A just-filled bar reaches
	-- none of them and settles on the first untimed entry going backwards -- the bar's final band.
	for index = #CookStates.Data, 1, -1 do
		local state = CookStates.Data[index]
		if not state.Overtime or overtime >= state.Overtime then
			return state.Id
		end
	end

	return CookStates.Data[1].Id
end

-- Maps wall-clock seconds since a cook started onto the timeline the bands above are written against.
-- All three warps live here because this is the one place the server's stop and the client's bar both
-- derive from -- a caller that skipped one would draw a bar the stop doesn't resolve against.
--
--  * windowStretch widens the perfect window in real time without moving where it sits on the bar, so
--    the bar still fills on the same second and Overtime still starts there. Absent or 1 is the identity.
--  * instability swings the rate either side of 1 all the way up the bar, so the fill surges and stalls.
--    It too leaves the fill second untouched. Maths written out at the warp below.
--  * cookProgress enters the timeline part-way along, for a cook resumed from an earlier raw pull.
-- @param elapsed: seconds since CookStartedAt
-- @param cookTime: the whole bar in seconds, as stamped on the cook
-- @param windowStretch: how many times longer the perfect window should run, or nil for untouched
-- @param cookProgress: bar fraction banked by an earlier raw pull, or nil on a skewer lit from cold
-- @param instability: how far this grill's cook rate swings either side of 1, or nil for a steady one
-- @param instabilityPhase: where in that swing this cook was lit, in radians, as stamped on it
function CookStates.GetBarElapsed(
	elapsed: number,
	cookTime: number,
	windowStretch: number?,
	cookProgress: number?,
	instability: number?,
	instabilityPhase: number?
): number
	-- Added *before* both warps: a bank is a head start along the cook, not a position on this grill's
	-- bar, and both warps can only keep the bar filling on cookTime if the total they're handed is what
	-- has to reach it. The cost is that a bank measured off a wobbling bar is spent on the steady axis
	-- underneath -- under a second of drift at the tuned figures, across a relight that resets everything
	-- visible anyway. Clamped, since it comes off saved data and a value past the window would let a
	-- relight open straight into the perfect band.
	elapsed += math.clamp(cookProgress or 0, 0, CookStates.RAW_END) * cookTime

	-- The rate is a sinusoid, rate(t) = 1 + a*sin(w*t + phase); applied here is its integral, in closed
	-- form so a client joining mid-cook draws exactly the bar one that watched it all is drawing:
	--
	--     bar(t) = t + (a / w) * (cos(phase) - cos(w*t + phase)),   w = 2*pi*cycles / cookTime
	--
	-- Three properties of that shape are the point:
	--  * strictly increasing for any a < 1 (that's just rate(t) > 0), so the bar never runs backwards and
	--    a stop can't settle a band the player watched go by. MAX_INSTABILITY holds it there.
	--  * cycles is a whole number, so bar(cookTime) == cookTime whatever the phase -- an unstable grill
	--    costs the timing, not the cook.
	--  * identity past the bar, which Overtime's wall-clock seconds require. The rate jumps at that seam
	--    unless phase is zero, but the fill is pinned full from there so nothing shows it.
	--
	-- The phase is stamped per cook: fixed at zero, the surges would land on the same places every time
	-- and each recipe would be one lottery drawn once rather than something to watch.
	local amplitude = math.clamp(instability or 0, 0, CookStates.MAX_INSTABILITY)
	if amplitude > 0 and elapsed > 0 and elapsed < cookTime then
		-- A whole count is what puts the bar back on cookTime; never below one, so even the shortest
		-- skewer gets a lurch rather than a straight line.
		local cycles = math.max(1, math.round(cookTime / CookStates.INSTABILITY_PERIOD))
		local frequency = 2 * math.pi * cycles / cookTime
		local phase = instabilityPhase or 0

		elapsed += (amplitude / frequency) * (math.cos(phase) - math.cos(frequency * elapsed + phase))
	end

	-- After the wobble, not before: windowStart is a fraction of cookTime *on the bar*, so the stretch has
	-- to be handed bar seconds -- which is what the wobble produces. The other way round, the stretch's
	-- promise about the fill second would be bent after it made it.
	local stretch = windowStretch or 1
	local windowStart = CookStates.RAW_END * cookTime
	if stretch <= 1 or elapsed <= windowStart then
		return elapsed
	end

	local windowLength = (CookStates.PERFECT_END - CookStates.RAW_END) * cookTime
	local stretched = windowLength * stretch

	if elapsed <= windowStart + stretched then
		return windowStart + (elapsed - windowStart) / stretch
	end

	return elapsed - (stretched - windowLength)
end

-- How many bar seconds the cook is gaining per wall-clock second right now -- the slope of the map
-- above, which is what a countdown reads to say how hard the grill is burning at this instant.
--
-- Taken as a central difference rather than differentiated by hand, for two reasons. The warps live in
-- exactly one place and the stretch leg is piecewise, so a written-out derivative would be a second copy
-- of that shape to keep in step with. And the slope genuinely jumps at each stretch seam; a difference
-- smears that across one frame instead of snapping, which is what something being rendered wants.
--
-- Cheap enough to call per frame: GetBarElapsed is a sine and a couple of branches. It's GetElapsedForBar
-- that's the expensive one.
-- @param elapsed: seconds since CookStartedAt
-- @param cookTime, windowStretch, cookProgress, instability, instabilityPhase: as GetBarElapsed takes them
-- @return bar seconds per wall second; 1 on a steady grill outside a stretched window
function CookStates.GetBarRate(
	elapsed: number,
	cookTime: number,
	windowStretch: number?,
	cookProgress: number?,
	instability: number?,
	instabilityPhase: number?
): number
	-- A step back past zero falls outside the wobble's own `elapsed > 0` guard and would read a slope the
	-- cook never runs at, so the opening frames step forward from where they are instead.
	local from = math.max(elapsed - RATE_EPSILON, 0)
	local to = math.max(elapsed, 0) + RATE_EPSILON

	local before = CookStates.GetBarElapsed(from, cookTime, windowStretch, cookProgress, instability, instabilityPhase)
	local after = CookStates.GetBarElapsed(to, cookTime, windowStretch, cookProgress, instability, instabilityPhase)

	return (after - before) / (to - from)
end

-- The other direction: how many wall-clock seconds after a cook started its bar reaches `barTarget`.
-- What the cooking bar's countdown is written against -- "perfect in 9.45s" is this, solved for the
-- band's own boundary, minus the seconds already gone.
--
-- Solved by bisection rather than rearranged: the instability term is `t` plus a cosine of `t`, which has
-- no closed form (Kepler's equation). Exact rather than approximate because the map is strictly increasing
-- for any amplitude under 1, so the target sits in exactly one place.
--
-- Not per-frame cheap, and every argument is fixed for the cook's whole run, so solve once as it opens.
-- @param barTarget: the bar second to reach, e.g. RAW_END * cookTime for the start of the window
-- @param cookTime: the whole bar in seconds, as stamped on the cook
-- @param windowStretch, cookProgress, instability, instabilityPhase: as GetBarElapsed takes them
function CookStates.GetElapsedForBar(
	barTarget: number,
	cookTime: number,
	windowStretch: number?,
	cookProgress: number?,
	instability: number?,
	instabilityPhase: number?
): number
	-- A resumed cook can open at or past a target a cold one is still seconds from. Clamped to RAW_END,
	-- so what this actually catches is a relight landing exactly on the start of the window.
	if CookStates.GetBarElapsed(0, cookTime, windowStretch, cookProgress, instability, instabilityPhase) >= barTarget then
		return 0
	end

	-- Wide enough to bracket any target: the wobble puts bar(cookTime) back on cookTime, and the stretch
	-- can only add its own window again on top.
	local low = 0
	local high = cookTime * (1 + (windowStretch or 1))

	-- To a millisecond, finer than anything reading this shows. Iteration-capped as well, so a target
	-- outside the bracket ends the loop rather than spinning.
	for _ = 1, 64 do
		if high - low <= 1e-3 then
			break
		end

		local middle = (low + high) / 2
		if CookStates.GetBarElapsed(middle, cookTime, windowStretch, cookProgress, instability, instabilityPhase) < barTarget then
			low = middle
		else
			high = middle
		end
	end

	return high
end

-- What a skewer in this state sells for, as a multiple of its ingredient value. A skewer with no state
-- (saved before cook states existed) is worth its plain value, so callers can multiply unconditionally.
function CookStates.GetMultiplier(id: string?): number
	local state = id and CookStates.GetStateFromId(id)
	return if state then state.Multiplier else 1
end

-- The colour a cooked part settles at: dragged BURNT_STRENGTH toward the state's Tint. GetOvertimeColor
-- ramps toward these same colours, so a stop that rebuilds the model underneath has no colour to pop.
function CookStates.GetTintedColor(cookedColor: Color3, id: string?): Color3
	local state = id and CookStates.GetStateFromId(id)
	if not (state and state.Tint) then
		return cookedColor
	end

	return cookedColor:Lerp(state.Tint, CookStates.BURNT_STRENGTH)
end

-- The colour a cooked part has darkened to `overtime` seconds past a full bar: one ramp leg per timed
-- state, each landing exactly on that state's tinted colour as it takes over -- which is what makes a
-- stop seamless. Driven off Data, so the ramp follows whatever the config says burns.
function CookStates.GetOvertimeColor(cookedColor: Color3, overtime: number): Color3
	local color = cookedColor
	local from = 0

	for _, state in CookStates.Data do
		if not state.Overtime then
			continue
		end

		local alpha = math.clamp((overtime - from) / (state.Overtime - from), 0, 1)
		color = color:Lerp(CookStates.GetTintedColor(cookedColor, state.Id), alpha)
		from = state.Overtime
	end

	return color
end

return CookStates
