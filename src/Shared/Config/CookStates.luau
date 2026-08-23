--[[
    The states a skewer passes through on a grill: three bands along the cooking bar, then two more
    that only a skewer nobody came back for ever reaches.

    A cook isn't a countdown the player waits out -- they light the stove and decide when to turn it
    off, and nothing else ever ends it. Where they stopped is what they get. The first three states are
    fixed fractions of the 0-1 bar, so a client reads them straight off the progress it's already
    deriving from CookStartedAt without the server telling it anything. What changes per skewer is only
    how long that bar takes (GrillerManager stretches Ingredients.GetTotalCookTime over it).

    The bar itself is forgiving on purpose: the window is in the middle of it and the run after the
    window is still a fine skewer, so overshooting costs a little money rather than the cook. The
    punishment is what happens past the end of the bar, and that's measured in seconds rather than a
    fraction -- Overtime is how long after the bar fills a state takes over. Wall-clock is the point:
    a quick skewer and a slow one get the same window to notice and react in, which a fraction of the
    cook wouldn't give them.

    Multiplier is what getting it right is worth -- a charred skewer sells for a fraction of a
    properly cooked one and a raw one for almost nothing -- and Tint is what makes a bad cook visible,
    darkening the cooked ingredient models wherever the skewer is shown rather than needing a third
    set of models.

    The offer fields are the other half of that: quality doesn't only change what a skewer is worth,
    it changes how a customer haggles over it. SellNpcManager reads them off the state it's selling:
    what a customer opens at, how willing it is to be pushed, and how far it can ever be pushed to.
]]

--
local CookStates = {}

-- Where the bands meet on the 0-1 cooking bar. RAW_END also sizes the cook itself: an ingredient's
-- CookTime is the seconds until it first reads cooked, so a run is that stretched over the whole bar.
-- Widening the gap between the two is what makes the window more forgiving.
CookStates.RAW_END = 0.6
CookStates.PERFECT_END = 0.85

-- How far a charred part's colour is dragged toward its state's Tint. Short of 1 on purpose, so even a
-- charred skewer still reads as the ingredients it's made of rather than a flat black lump.
CookStates.BURNT_STRENGTH = 0.65

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
	Icon: string, -- rbxassetid for this state's badge on a skewer's inventory slot
	Color: Color3, -- the [COOKED] tag's colour on the tooltip that slot pops up
	BarColor: Color3, -- what the cooking bar's fill turns while the skewer is in this state
	Tint: Color3?, -- what its cooked models darken toward, or nil to leave them as they are
	Notification: { Text: string, Sound: string, Effect: string }?, -- the toast on stopping here, if any
}

-- Ordered along the cook: up to the window, in it, past it but still fine, then the two a skewer only
-- reaches by being left on. Every OfferMin sits at or above 1 on purpose -- SellNpc.ESTIMATE_MAX_FACTOR
-- keeps the billboard guess at or below the sell value, so an offer never comes in under the number the
-- player was just shown. The punishment for a bad cook lives in Multiplier, not in a second lowball
-- stacked on top of it -- so what a worse state changes is how far the range runs above 1, and it
-- narrows the whole way down the ladder. OfferMax has to stay above its own OfferMin: the pair is
-- handed straight to a Random:NextNumber, which has no opinion about being given them backwards.
--
-- CounterCap has to sit above OfferMax, and the gap between the two is what a haggle actually plays with:
-- each round closes a fraction of the distance left to the cap (SellNpc.COUNTER_INCREASE_MIN/MAX), so the
-- room above OfferMax is the whole negotiation and a state with almost none barely moves. That gap narrows
-- down the quality ladder the same way the offer range does (0.2x on a perfect skewer to 0.05x on a raw
-- one), which is why the cap belongs here rather than being one number for every state -- a single global
-- cap would leave a charred skewer opening at 1 with more room to be pushed than a perfect one opening at
-- 1.35, and burnt skewers would haggle hardest of all. Keep some gap even at the bottom of the ladder
-- though: a counter-offer that moves the price by nothing still spends a bubble and a sound saying it did.
CookStates.Data = {
	{
		Id = "Raw",
		Name = "Raw",
		End = CookStates.RAW_END,
		-- A raw skewer still sells, it just barely clears what its ingredients cost. Pulling one off
		-- early is a loss to eat rather than a wall to hit, and most customers won't touch it anyway.
		Multiplier = 1,
		OfferMin = 1,
		OfferMax = 1.05,
		CounterChance = 15,
		CounterCap = 1.1,
		Icon = "rbxassetid://85040089054254",
		Color = Color3.fromRGB(255, 120, 180),
		BarColor = Color3.fromRGB(255, 219, 248),
		-- The one state whose toast is about what didn't happen: the cook is banked on the skewer rather
		-- than lost, and the next light picks it back up. Reads as a success because it is one -- the
		-- alternative it's telling them about is the whole cook going in the bin.
		Notification = { Text = "Pulled off early, cook saved", Sound = "Notify", Effect = "Success" },
	},
	{
		Id = "Perfect",
		Name = "Perfectly Cooked",
		End = CookStates.PERFECT_END,
		-- The baseline every ingredient price is tuned against, rather than a bonus on top of one: the
		-- window is what a player is aiming for, so hitting it is what "normal" pays.
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
		-- Overshooting the window is a nick, not a penalty. This band is the whole point of the bar
		-- running past the window: a player who looked away comes back to a skewer worth selling.
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
		Overtime = 15,
		-- Past the bar the haggle narrows rather than the offer dipping under the estimate: a customer
		-- still opens above the guess, it just won't be talked much past it.
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
		Overtime = 40,
		-- The narrowest range of any state, so the bottom of the ladder haggles like the bottom of the
		-- ladder: nobody talks themselves up over a burnt skewer.
		Multiplier = 0.8,
		OfferMin = 1,
		OfferMax = 1.05,
		CounterChance = 30,
		CounterCap = 1.14,
		Icon = "rbxassetid://117732140813353",
		Color = Color3.fromRGB(92, 62, 48),
		BarColor = Color3.fromRGB(60, 20, 18),
		Tint = Color3.fromRGB(25, 18, 14),
		Notification = { Text = "You burnt your BBQ to a crisp!", Sound = "Reject", Effect = "Error" },
	},
}

table.freeze(CookStates.Data)

-- Where the bands meet along the bar, in order. The cooking bar plants a mark on each one, so the
-- window is something the player can see coming rather than only read off the title once they're
-- already in it. Derived from the bands above rather than authored again, so adding a state puts its
-- mark on the bar without anyone remembering to. Only the states that live on the bar get one -- the
-- ones past it are timed rather than positioned, and the bar sits full through both.
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

-- Which state a cook is in `elapsed` seconds into a run whose bar takes `cookTime` seconds. Under the
-- bar that's the band the progress falls in; past it, nothing has stopped the cook, so it's however
-- many of the Overtime states have since come round. Taking the raw seconds rather than a progress the
-- caller already clamped is what keeps the server's stop and the client's bar deriving it the same way.
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

	-- Past the bar: walk back to the last state whose grace period has run out. A cook that's only just
	-- filled hasn't reached any of them and settles on the final band of the bar, which is the first
	-- entry going backwards that isn't timed at all.
	for index = #CookStates.Data, 1, -1 do
		local state = CookStates.Data[index]
		if not state.Overtime or overtime >= state.Overtime then
			return state.Id
		end
	end

	return CookStates.Data[1].Id
end

-- Maps wall-clock seconds since a cook started onto the timeline the bands above are written against.
-- A stretch widens the window in real time without moving where it sits on the bar: the run up to it is
-- untouched, the window itself plays out `stretch` times slower, and everything past it carries on from
-- where it would have been -- so the bar still fills at the same second it always did and Overtime still
-- starts from there.
--
-- Nothing in normal play passes one. It's stamped per cook, by the server, for a player who's being
-- taught the timing rather than tested on it: the window is a quarter of the bar, which on the cheapest
-- ingredient is about two seconds, and that's a hard first attempt on a touchscreen. Absent or 1, this
-- is the identity function and every cook resolves exactly as it did before it existed.
--
-- A cook resumed from an earlier pull enters the timeline part-way along rather than at zero, and that
-- offset is folded in here for the same reason the stretch is: this is the one place the server's stop
-- and the client's bar both derive from, so a call site can't forget it and leave the two disagreeing.
-- @param elapsed: seconds since CookStartedAt
-- @param cookTime: the whole bar in seconds, as stamped on the cook
-- @param windowStretch: how many times longer the perfect window should run, or nil for untouched
-- @param cookProgress: bar fraction banked by an earlier raw pull, or nil on a skewer lit from cold
function CookStates.GetBarElapsed(
	elapsed: number,
	cookTime: number,
	windowStretch: number?,
	cookProgress: number?
): number
	-- Banked bar seconds added to real ones, which only lines up because a bank never reaches the window:
	-- the stretch below is the identity function up to windowStart, so the two measure the same thing over
	-- the stretch of timeline a bank can occupy. Clamped rather than trusted -- it comes back off saved
	-- data, and a value past the window would let a relight open straight into the perfect band.
	elapsed += math.clamp(cookProgress or 0, 0, CookStates.RAW_END) * cookTime

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

-- What a skewer in this state sells for, as a multiple of its ingredient value. A skewer carrying no
-- state -- one saved before cook states existed -- is worth its plain value, so callers can multiply
-- unconditionally. StickModel.GetCookStateId is what resolves a record to an id worth passing here.
function CookStates.GetMultiplier(id: string?): number
	local state = id and CookStates.GetStateFromId(id)
	return if state then state.Multiplier else 1
end

-- The colour a cooked part settles at in this state: dragged BURNT_STRENGTH of the way toward the
-- state's Tint, or left alone in a state without one. StickModel paints a finished skewer with it, and
-- GetOvertimeColor below is the ramp the griller runs toward the very same colours, so the moment a
-- cook stops and the model is rebuilt underneath there's no colour to pop.
function CookStates.GetTintedColor(cookedColor: Color3, id: string?): Color3
	local state = id and CookStates.GetStateFromId(id)
	if not (state and state.Tint) then
		return cookedColor
	end

	return cookedColor:Lerp(state.Tint, CookStates.BURNT_STRENGTH)
end

-- The colour a cooked part has darkened to `overtime` seconds past a full bar: one leg of the ramp per
-- timed state, each running from the state before it and landing exactly on that state's own tinted
-- colour as it takes over. Landing there is what makes a stop seamless -- the model the server rebuilds
-- underneath is painted from GetTintedColor with the same id. Driven off Data rather than the two
-- states being named here, so the ramp follows whatever the config says burns.
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
