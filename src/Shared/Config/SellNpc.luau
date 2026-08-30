--[[
    All the numbers controlling the sell-stand customers.

    A sale: skewer goes on the stand -> a customer walks over -> thinks about it -> leaves (and another
    comes) or offers -> the player accepts or declines -> declining may get a better price, up to
    MAX_COUNTER_ROUNDS times -> it pays, steps back, and eats.

    Declining is a reroll rather than a loss, since the skewer goes back on the stand. The REFUSAL_ block
    is what stops that reroll being free: refusals are remembered and drag later opening offers down.

    A MIN/MAX pair is one setting with a random range, not two settings.

    Not here: the opening offer, haggle chance and haggle ceiling, which vary by cook state and so live on
    CookStates.Data. Gotcha: INTERESTED_CHANCE is out of 1, but CounterChance there is out of 100.
]]

--
local SellNpc = {}

-- Seconds before a customer shows up after a skewer is placed.
-- Higher = slower money. Lower = customers appear almost instantly.
-- What an established player waits -- a new one's is scaled by EarlyBoost.MAX_SPAWN_SPEEDUP.
SellNpc.SPAWN_DELAY_MIN = 8
SellNpc.SPAWN_DELAY_MAX = 15

-- What a guaranteed customer waits instead (SellNpcManager:SetCustomersGuaranteed). Its own number
-- because the range above is balance and this is pacing: short enough not to read as the tutorial
-- hanging, long enough that the customer still walks up rather than materialising.
SellNpc.GUARANTEED_SPAWN_DELAY = 3

-- Seconds before the next customer tries, after one leaves without buying. The floor rather than the
-- whole wait -- REFUSAL_RETRY_DELAY adds to it for a player who's been declining.
-- Higher = rejections hurt more. Lower = barely noticeable.
SellNpc.RETRY_DELAY_MIN = 4
SellNpc.RETRY_DELAY_MAX = 7

-- How close a customer has to get to the stand before it counts as having arrived.
-- Higher = they stop short and look disconnected from the stand. Lower = they can get stuck walking
-- forever if something blocks the last step.
SellNpc.ARRIVE_DISTANCE = 4

-- Gap between customers waiting at the stand, so they don't stand inside each other.
-- Higher = the line spreads out and might run past the stand. Lower = they overlap.
SellNpc.STAND_SPACING = 8

-- Odd customers sit this far back, forming a second row so a full line's billboards don't stack flat.
-- Higher = a deeper stagger. Lower = the rows flatten into one line.
SellNpc.STAND_ROW_OFFSET = 2.5

-- Give-up time for a customer that can't reach the stand. Just a safety net for one stuck on scenery.
-- Higher = stuck customers hang around longer. Lower = customers on a long walk get cut off early.
SellNpc.WALK_TIMEOUT = 10

-- Seconds the customer spends thinking it over, while the sign flicks between Interested and
-- Not Interested.
-- Higher = more suspense, slower selling. Lower = snappier, less of a moment.
SellNpc.DECIDE_DURATION_MIN = 2
SellNpc.DECIDE_DURATION_MAX = 3

-- How fast that sign flicks: it starts at the first number and slows to the second, so it winds down onto
-- the answer.
-- Higher = calmer flicking. Lower = faster and more frantic. Make them the same and it won't slow down.
SellNpc.DECIDE_INITIAL_WAIT = 0.04
SellNpc.DECIDE_MAX_WAIT = 0.35

-- Chance out of 1 that the customer wants to buy. 0.85 means roughly 6 in 7 buy, 1 walks off.
-- Higher = nearly everyone buys and the thinking moment stops mattering. Lower = tenser but slower.
-- What an established player faces -- a new one's walk-off share is cut by EarlyBoost.MAX_DECLINE_REDUCTION.
SellNpc.INTERESTED_CHANCE = 0.85

-- Seconds a customer that said no stands there before walking off.
-- Higher = the player has time to read it. Lower = they leave right away.
SellNpc.LEAVE_DELAY = 2.5

-- Where the skewer sits in the customer's hand once it's picked it up. Purely visual.
SellNpc.SKEWER_HOLD_OFFSET = CFrame.identity

-- The opening offer, the counter chance and the haggle ceiling live per cook state on CookStates.Data
-- (OfferMin/OfferMax/CounterChance/CounterCap), so there's one place to tune them.
--
-- A skewer's sell value: its ingredients' shop cost, plus a slice of the stick's (Sticks.SALE_RETURN_FACTOR),
-- times the stick's tier boost, its sauce and its cook state. So $1,000 of ingredients on a $2,500 gold
-- stick is $4,163 cooked perfectly and $1,850 charred. Sauce is a no-op today -- Sauces.Data ships empty.

-- The billboard guess over a held skewer, as a multiple of sell value. Kept at or below 1 while every
-- state's OfferMin sits at or above it, so an opening offer always beats the guess. Each skewer's spot in
-- the range is fixed by its own id, so the number never changes on re-equip.
-- Higher = the guess creeps toward the real price. Past 1, skewers sell for less than they were promised.
SellNpc.ESTIMATE_MIN_FACTOR = 0.98
SellNpc.ESTIMATE_MAX_FACTOR = 1.05

-- How fast a state's CounterChance decays each round you push: an 80% start runs 80% -> 64% -> 51% ->
-- 41% and so on, so the first push is close to a sure thing and a long run still isn't.
-- Higher (closer to 1) = long haggles stay possible. Lower = the second decline nearly always ends it.
SellNpc.COUNTER_CHANCE_FALLOFF = 0.8

-- What each better price adds, as a fraction of the distance left to the cook state's CounterCap -- not a
-- multiple of sell value. Closing a share of the remaining gap makes a haggle decelerate, and it can't
-- overshoot the ceiling, so nothing needs clamping.
--
-- Sized against REFUSAL_OFFER_PENALTY below rather than on feel: a push that lands has to be worth more
-- than a push that misses costs, or haggling is a losing move and the whole mechanic is decoration.
--
-- Keep the pair low. Reach for CookStates.CounterChance first -- it makes haggling reliable without
-- making any one round bigger.
-- Higher = jumpier rounds that eat most of the gap at once. Lower = pushing barely moves the number.
SellNpc.COUNTER_INCREASE_MIN = 0.11
SellNpc.COUNTER_INCREASE_MAX = 0.18

-- How many times one customer will sweeten its offer. The decaying CounterChance makes a long haggle
-- unlikely, but unlikely isn't never, and an unbounded one is something a patient player rides to the
-- ceiling. Three also gives the haggle sounds somewhere to go (Haggle1, then Haggle2 pitched up).
-- Higher = the ceiling comes back into reach. Lower = it stops being reachable and CounterCap is decorative.
SellNpc.MAX_COUNTER_ROUNDS = 3

-- How much higher each counter-offer past the first is pitched, so a customer being pushed sounds
-- progressively more strained.
-- Higher = the escalation is obvious but goes cartoonish fast. Lower = the rounds stop sounding distinct.
SellNpc.HAGGLE_PITCH_STEP = 0.2

-- Seconds a customer waits for an answer before giving up. Stops one ignored offer from blocking every
-- customer behind it.
-- Higher = players can step away mid-offer. Lower = the queue frees up sooner, but slow players lose
-- offers they wanted.
SellNpc.OFFER_TIMEOUT = 30

-- Seconds before a pending offer nudges again, repeating until answered. The opening toast is easy to
-- miss and the billboard is no use from the grill, so without this a sale can lapse unseen. Shared with
-- the rich customer -- a shorter window doesn't want a different rhythm.
-- Higher = fewer reminders and more offers lost. Lower = nagging, and the toast crowds the screen.
SellNpc.OFFER_NUDGE_INTERVAL = 10

-- The red flash on the waiting customer, so the toast points at someone. Fed to HighlightPulse:
-- START_TRANSPARENCY is where the fill begins, COUNT how many times it tweens out across DURATION.
-- Higher COUNT = a faster, more urgent blink. 1 is a single slow fade.
SellNpc.NUDGE_PULSE_COLOR = Color3.fromRGB(255, 0, 0)
SellNpc.NUDGE_PULSE_START_TRANSPARENCY = 0.35
SellNpc.NUDGE_PULSE_DURATION = 2
SellNpc.NUDGE_PULSE_COUNT = 3

-- What declining costs. Without it a reroll is free: the skewer goes back on the stand and the next
-- customer prices it from the full range again. Each standing refusal shifts the next opening range down
-- by PENALTY of sell value and adds RETRY_DELAY to the wait -- money removes the reason to reroll, time is
-- the half that can't feel unfair. The shifted range is floored at plain sell value, so declining stops
-- paying a bonus but never a loss.
--
-- Deliberately smaller than a landed counter-offer pays (COUNTER_INCREASE above): if a refusal cost more
-- than a push earns, the arithmetic would tell the player never to haggle. What it must still beat is the
-- free reroll -- declining everything to fish for a high opening roll.
--
-- GRACE is how many refusals cost nothing. Declining once is the mechanic working as the onboarding taught
-- it, so charging for that would teach them not to; the penalty is aimed at repeat refusals. GRACE and
-- PENALTY_MAX move together -- the most anyone pays is (PENALTY_MAX - GRACE). A completed sale sheds one
-- (ForgiveSaleRefusal). Stored in player data on the synced clock, so a rejoin can't wipe the slate.
--
-- Higher PENALTY = a couple of refusals gut the offer. Lower = the reroll is profitable again.
-- Higher DECAY = the penalty hangs over a session. Lower = waiting it out beats selling.
-- Higher GRACE = declining stays free for longer. Lower = the first no costs.
-- Higher PENALTY_MAX = the floor is reached and there's nothing left to lose by declining forever.
SellNpc.REFUSAL_OFFER_PENALTY = 0.03
SellNpc.REFUSAL_GRACE = 1
SellNpc.REFUSAL_PENALTY_MAX = 4
SellNpc.REFUSAL_DECAY = 60
SellNpc.REFUSAL_RETRY_DELAY = 2

-- The narrowest the penalty may squeeze an opening range. Without it the ends converge and the states
-- opening at 1 quote the same number every time, which reads as a broken customer rather than a penalised
-- one. The penalty still lands; it just can't flatten the roll out of existence.
-- Higher = the penalty stops biting on states opening near 1. Lower = those states go deterministic.
SellNpc.MIN_OFFER_SPREAD = 0.02

-- Where a customer eats after buying: a random back distance in this range plus up to EAT_SPREAD either
-- way, so finished customers scatter into a crowd rather than lining up behind the stand.
-- Higher DISTANCE = they get out of the way properly. Lower = they eat right in front of the stand.
-- Higher SPREAD = eaters fan out wider sideways. Lower = they stay closer to straight behind.
-- Higher DURATION = they hang around and the place looks busy. Lower = they clear out fast.
SellNpc.EAT_BACK_DISTANCE_MIN = 5
SellNpc.EAT_BACK_DISTANCE_MAX = 9
SellNpc.EAT_SPREAD = 4
SellNpc.EAT_DURATION = 8

-- How many customer rigs to pre-create and keep around for reuse, so a fresh one isn't cloned every
-- visit. Customers are handed out from this pool and returned to it when they leave.
-- Higher = more rigs held in memory but fewer built on the fly during a rush. Lower = leaner, but a
-- busy server clones extras past the pool.
SellNpc.NPC_POOL_SIZE = 30

-- Seconds the customer's transparency ramps over when it appears and when it leaves, so it fades in
-- and out instead of popping.
-- Higher = a slower, softer fade. Lower = snappier, closer to an instant pop.
SellNpc.FADE_IN_DURATION = 0.4
SellNpc.FADE_OUT_DURATION = 0.4

return SellNpc
