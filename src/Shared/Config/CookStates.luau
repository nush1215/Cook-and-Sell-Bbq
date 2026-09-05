-- The states a skewer passes through on a grill: three bands along the 0-1 bar, then two more on wall-clock overtime. See docs/balance.md.

--
local CookStates = {}

-- Where the bands meet on the 0-1 bar. RAW_END also sizes the cook: CookTime is stretched over the whole bar
CookStates.RAW_END = 0.6
CookStates.PERFECT_END = 0.85

-- How far a charred part is dragged toward its Tint. Short of 1, so it still reads as its ingredients
CookStates.BURNT_STRENGTH = 0.65

-- Max rate swing either side of 1. At 1 the bar stalls dead; past it, it runs backwards. Clamped where read
CookStates.MAX_INSTABILITY = 0.9

-- Target length of one surge-and-stall; GetBarElapsed rounds to whole cycles to land back on cookTime
CookStates.INSTABILITY_PERIOD = 4

-- How far GetBarRate samples either side to read its slope. A frame, so the sample spans what the eye does
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
	-- Seconds the take prompt is held in this band, or nil to fire on press -- only where a press is a mistake
	StopHold: number?,
	Notification: { Text: string, Sound: string, Effect: string }?, -- the toast on stopping here, if any
}

-- Ordered along the cook. CounterCap must sit above OfferMax -- that gap is the whole negotiation; see docs/balance.md
CookStates.Data = {
	{
		Id = "Raw",
		Name = "Raw",
		End = CookStates.RAW_END,
		-- Barely clears its ingredients; the chance is high to teach the mechanic, the cap keeps that honest
		Multiplier = 1,
		OfferMin = 1,
		OfferMax = 1.05,
		CounterChance = 30,
		CounterCap = 1.1,
		Icon = "rbxassetid://85040089054254",
		Color = Color3.fromRGB(255, 120, 180),
		BarColor = Color3.fromRGB(255, 219, 248),
		-- The only band asking to be held -- a stray press here throws away the run rather than settling it
		StopHold = 0.75,
		-- The cook is banked, not lost, so this reads as a success -- the alternative was binning the whole thing
		Notification = { Text = "Pulled off early, cook saved", Sound = "Notify", Effect = "Success" },
	},
	{
		Id = "Perfect",
		Name = "Perfectly Cooked",
		End = CookStates.PERFECT_END,
		-- The baseline every ingredient price is tuned against, not a bonus on top of one
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
		-- Overshooting is a nick, not a penalty -- a player who looked away still has a sellable skewer
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
		-- Past the bar the haggle narrows rather than the offer dipping under the estimate
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
		-- The narrowness lives in the cap, not the chance -- a counter that moves nothing teaches the state's worth
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

-- Where the bands meet, derived so a new state marks itself. Only states on the bar get one.
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

-- Which state a cook is in `elapsed` seconds in. Takes raw seconds, so the stop and the bar derive it alike.
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

	-- Past the bar, walk back to the last state whose grace has run out; a just-filled bar reaches none
	for index = #CookStates.Data, 1, -1 do
		local state = CookStates.Data[index]
		if not state.Overtime or overtime >= state.Overtime then
			return state.Id
		end
	end

	return CookStates.Data[1].Id
end

-- Maps wall seconds onto the bar's timeline, applying cookProgress then instability then windowStretch. See docs/balance.md.
function CookStates.GetBarElapsed(
	elapsed: number,
	cookTime: number,
	windowStretch: number?,
	cookProgress: number?,
	instability: number?,
	instabilityPhase: number?
): number
	-- Added before both warps, since a bank is a head start along the cook, not a position on this grill's bar
	elapsed += math.clamp(cookProgress or 0, 0, CookStates.RAW_END) * cookTime

	-- The integral of rate(t) = 1 + a*sin(w*t + phase), in closed form so a mid-cook join draws the same bar
	local amplitude = math.clamp(instability or 0, 0, CookStates.MAX_INSTABILITY)
	if amplitude > 0 and elapsed > 0 and elapsed < cookTime then
		-- A whole count puts the bar back on cookTime; never below one, so even a short skewer lurches
		local cycles = math.max(1, math.round(cookTime / CookStates.INSTABILITY_PERIOD))
		local frequency = 2 * math.pi * cycles / cookTime
		local phase = instabilityPhase or 0

		elapsed += (amplitude / frequency) * (math.cos(phase) - math.cos(frequency * elapsed + phase))
	end

	-- After the wobble, since windowStart is a bar fraction and the stretch must be handed bar seconds
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

-- Bar seconds gained per wall second right now, as a central difference. Cheap enough to call per frame.
function CookStates.GetBarRate(
	elapsed: number,
	cookTime: number,
	windowStretch: number?,
	cookProgress: number?,
	instability: number?,
	instabilityPhase: number?
): number
	-- A step back past zero would read a slope the cook never runs at, so the opening frames step forward
	local from = math.max(elapsed - RATE_EPSILON, 0)
	local to = math.max(elapsed, 0) + RATE_EPSILON

	local before = CookStates.GetBarElapsed(from, cookTime, windowStretch, cookProgress, instability, instabilityPhase)
	local after = CookStates.GetBarElapsed(to, cookTime, windowStretch, cookProgress, instability, instabilityPhase)

	return (after - before) / (to - from)
end

-- Wall seconds until the bar reaches `barTarget`, by bisection -- the instability term has no closed form. Solve once per cook.
function CookStates.GetElapsedForBar(
	barTarget: number,
	cookTime: number,
	windowStretch: number?,
	cookProgress: number?,
	instability: number?,
	instabilityPhase: number?
): number
	-- Catches a relight landing exactly on the start of the window
	if CookStates.GetBarElapsed(0, cookTime, windowStretch, cookProgress, instability, instabilityPhase) >= barTarget then
		return 0
	end

	-- Wide enough to bracket any target -- the wobble lands back on cookTime and the stretch adds one window
	local low = 0
	local high = cookTime * (1 + (windowStretch or 1))

	-- To a millisecond, iteration-capped so a target outside the bracket ends rather than spins
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

-- Sell multiple for this state. A stateless skewer is worth plain value, so callers multiply unconditionally.
function CookStates.GetMultiplier(id: string?): number
	local state = id and CookStates.GetStateFromId(id)
	return if state then state.Multiplier else 1
end

-- The colour a cooked part settles at. GetOvertimeColor ramps to these, so a rebuild has no colour to pop.
function CookStates.GetTintedColor(cookedColor: Color3, id: string?): Color3
	local state = id and CookStates.GetStateFromId(id)
	if not (state and state.Tint) then
		return cookedColor
	end

	return cookedColor:Lerp(state.Tint, CookStates.BURNT_STRENGTH)
end

-- The colour `overtime` seconds past a full bar: one ramp leg per timed state, landing exactly on its tint.
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
