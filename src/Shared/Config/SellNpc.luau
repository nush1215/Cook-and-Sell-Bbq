-- Every number controlling the sell-stand customers. A MIN/MAX pair is one setting with a range. See docs/balance.md.

--
local SellNpc = {}

-- Seconds before a customer arrives. What an established player waits; EarlyBoost scales a new one's
SellNpc.SPAWN_DELAY_MIN = 8
SellNpc.SPAWN_DELAY_MAX = 15

-- What a guaranteed customer waits: pacing rather than balance, so it's its own number
SellNpc.GUARANTEED_SPAWN_DELAY = 3

-- The floor on the retry wait; REFUSAL_RETRY_DELAY adds to it for a player who's been declining
SellNpc.RETRY_DELAY_MIN = 4
SellNpc.RETRY_DELAY_MAX = 7

-- How close a customer must get before it counts as arrived
SellNpc.ARRIVE_DISTANCE = 4

-- Gap between waiting customers, so they don't stand inside each other
SellNpc.STAND_SPACING = 8

-- Alternate lanes sit this far back, so a full line's billboards don't stack flat
SellNpc.STAND_ROW_OFFSET = 2.5

-- Give-up time for a customer that can't reach the stand -- a safety net for one stuck on scenery
SellNpc.WALK_TIMEOUT = 10

-- Seconds spent thinking it over, while the sign flicks between Interested and Not Interested
SellNpc.DECIDE_DURATION_MIN = 2
SellNpc.DECIDE_DURATION_MAX = 3

-- How fast that sign flicks: it starts at the first and slows to the second, winding down onto the answer
SellNpc.DECIDE_INITIAL_WAIT = 0.04
SellNpc.DECIDE_MAX_WAIT = 0.35

-- Chance out of 1 that the customer buys. Established players; EarlyBoost cuts a new one's walk-off share
SellNpc.INTERESTED_CHANCE = 0.85

-- Seconds a customer that said no stands there before walking off
SellNpc.LEAVE_DELAY = 2.5

-- Where the skewer sits in the customer's hand once it's picked it up. Purely visual.
SellNpc.SKEWER_HOLD_OFFSET = CFrame.identity

-- The opening offer, counter chance and ceiling live per cook state on CookStates.Data

-- The billboard guess over a held skewer. At or below 1, so an opening offer always beats it
SellNpc.ESTIMATE_MIN_FACTOR = 0.98
SellNpc.ESTIMATE_MAX_FACTOR = 1.05

-- How fast CounterChance decays per round pushed, so the first push is near sure and a long run isn't
SellNpc.COUNTER_CHANCE_FALLOFF = 0.8

-- A fraction of the gap left to CounterCap, so a haggle decelerates and can't overshoot. See docs/balance.md
SellNpc.COUNTER_INCREASE_MIN = 0.11
SellNpc.COUNTER_INCREASE_MAX = 0.18

-- How many times one customer sweetens its offer, so a patient player can't ride it to the ceiling
SellNpc.MAX_COUNTER_ROUNDS = 3

-- How much each counter past the first is pitched up, so being pushed sounds progressively strained
SellNpc.HAGGLE_PITCH_STEP = 0.2

-- Seconds a customer waits for an answer, so one ignored offer can't block the queue behind it
SellNpc.OFFER_TIMEOUT = 30

-- Seconds between nudges on a pending offer -- the toast is missable and the billboard is no use from the grill
SellNpc.OFFER_NUDGE_INTERVAL = 10

-- The red flash on a waiting customer, fed to HighlightPulse so the toast points at someone
SellNpc.NUDGE_PULSE_COLOR = Color3.fromRGB(255, 0, 0)
SellNpc.NUDGE_PULSE_START_TRANSPARENCY = 0.35
SellNpc.NUDGE_PULSE_DURATION = 2
SellNpc.NUDGE_PULSE_COUNT = 3

-- What declining costs, so a reroll isn't free. See docs/balance.md for how the four move together
SellNpc.REFUSAL_OFFER_PENALTY = 0.03
SellNpc.REFUSAL_GRACE = 1
SellNpc.REFUSAL_PENALTY_MAX = 4
SellNpc.REFUSAL_DECAY = 60
SellNpc.REFUSAL_RETRY_DELAY = 2

-- The narrowest the penalty may squeeze a range, or states opening at 1 quote one number every time
SellNpc.MIN_OFFER_SPREAD = 0.02

-- Where a customer eats after buying, so they scatter into a crowd rather than lining up behind the stand
SellNpc.EAT_BACK_DISTANCE_MIN = 5
SellNpc.EAT_BACK_DISTANCE_MAX = 9
SellNpc.EAT_SPREAD = 4
SellNpc.EAT_DURATION = 8

-- Rigs pre-created and reused, so a fresh one isn't cloned every visit
SellNpc.NPC_POOL_SIZE = 30

-- Seconds the customer fades in and out over, so it doesn't pop
SellNpc.FADE_IN_DURATION = 0.4
SellNpc.FADE_OUT_DURATION = 0.4

return SellNpc
