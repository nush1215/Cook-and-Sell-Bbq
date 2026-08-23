--[[
    All the numbers that control the sell-stand customers.

    How a sale goes: the player puts a skewer on the stand -> a customer walks over -> it thinks about it
    -> if it's not interested it leaves and another one comes -> if it is, it offers a price -> the player
    accepts or declines -> declining might get a better price, up to MAX_COUNTER_ROUNDS times -> it pays,
    steps back, and eats.

    A skewer a customer walks away from goes back on the stand and another comes for it, so turning an
    offer down is a reroll rather than a loss. What stops that reroll being free is the REFUSAL_ block
    below: refusals are remembered for a while and drag later customers' opening offers down toward the
    skewer's plain worth. Selling at a sensible price never touches any of it.

    Anything ending in MIN and MAX is one setting with a random range, not two settings. A 5/8 pair means
    "somewhere between 5 and 8, picked at random each time".

    What isn't here: the opening offer, the haggle chance and the haggle ceiling, all of which vary by
    how well the skewer was cooked and so live on CookStates.Data instead.

    One gotcha: INTERESTED_CHANCE is out of 1 (0.8 = 80%), but the cook states' CounterChance is out of
    100 (80 = 80%).
]]

--
local SellNpc = {}

-- Seconds before a customer shows up after a skewer is put on the stand.
-- Higher = slower money. Lower = customers appear almost instantly.
SellNpc.SPAWN_DELAY_MIN = 8
SellNpc.SPAWN_DELAY_MAX = 15

-- What a guaranteed customer waits instead of the range above (SellNpcManager:SetCustomersGuaranteed).
-- Its own number rather than the range's floor: the floor is balance -- how long money should take --
-- and this is pacing, for a player sat watching a banner that has told them to wait and given them
-- nothing to do. Short enough not to read as the tutorial having hung, long enough that the customer
-- still walks up rather than materialising on the spot.
SellNpc.GUARANTEED_SPAWN_DELAY = 3

-- Seconds before the next customer tries, after one leaves without buying. Someone always comes back for
-- it, so a rejection only costs time. This is the floor rather than the whole wait: REFUSAL_RETRY_DELAY
-- below adds to it for a player who's been turning offers down.
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

-- Odd customers in the line sit this far back toward the customer side, forming a second row.
-- The zig-zag pulls their billboard UIs apart by depth so a full line doesn't stack them flat.
-- Higher = a deeper stagger between the two rows. Lower = the rows flatten back into one line.
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

-- Chance out of 1 that the customer wants to buy. 0.8 means 8 out of 10 buy, 2 walk off.
-- Higher = nearly everyone buys and the thinking moment stops mattering. Lower = more rejections and
-- slower sales, but the wait feels tenser.
SellNpc.INTERESTED_CHANCE = 0.8

-- Seconds a customer that said no stands there before walking off.
-- Higher = the player has time to read it. Lower = they leave right away.
SellNpc.LEAVE_DELAY = 2.5

-- Where the skewer sits in the customer's hand once it's picked it up. Purely visual.
SellNpc.SKEWER_HOLD_OFFSET = CFrame.identity

-- The first price offered, the chance that declining gets a better one, and the most a customer can ever
-- be pushed to all live per cook state, on CookStates.Data (OfferMin, OfferMax, CounterChance and
-- CounterCap) -- how well a skewer was cooked changes how a customer haggles over it, not just what it's
-- worth. They're not repeated here, so there's only ever one place to tune them.
--
-- Worth knowing: a skewer's sell value is what its ingredients cost in the shop plus a slice of what
-- the stick under them cost (Sticks.SALE_RETURN_FACTOR), times that stick's tier boost
-- (Sticks.ValueBoost), times its sauce, times its cook state. So $1,000 of ingredients on a $2,500 gold
-- stick (+$250, then +20%) under mustard (1.6) makes a $4,320 skewer cooked perfectly (1.8), and
-- $1,920 if it's left on until it chars (0.8).

-- The guess shown on the billboard over a held skewer, as a multiple of its sell value. Both numbers
-- sit at or below 1 on purpose, and every state's OfferMin sits at or above it, so a customer's opening
-- offer always beats the guess and the sale reads as a win rather than a letdown. Each skewer's spot in
-- this range is fixed by its own id, so the number never changes on re-equip.
-- Higher = the guess creeps toward the real price and the sale stops feeling like a bonus. Push either
-- past 1 and skewers start selling for less than the player was promised.
SellNpc.ESTIMATE_MIN_FACTOR = 0.98
SellNpc.ESTIMATE_MAX_FACTOR = 1.05

-- How fast a state's CounterChance decays each round you push: an 80% start runs 80% -> 64% -> 51% ->
-- 41% and so on, so the first push is close to a sure thing and a long run still isn't.
-- Higher (closer to 1) = long haggles stay possible. Lower = the second decline nearly always ends it.
SellNpc.COUNTER_CHANCE_FALLOFF = 0.8

-- How much each better price adds, as a fraction of the distance still left between what's on the table
-- and the cook state's CounterCap -- not as a multiple of the skewer's sell value. Closing a share of the
-- remaining gap is what makes a haggle decelerate: a customer gives ground readily on the first push and
-- grudgingly on the third, because there's less left to give. On a $1,000 perfect skewer opening at $1,225
-- against a $1,550 ceiling that runs +$36-$59, then +$31-$50, then +$26-$43 -- so the badge steps roughly
-- +23% -> +27% -> +31% -> +34%, a few points at a time and shrinking. It also can't overshoot the ceiling,
-- so nothing needs clamping off it.
--
-- Sized against the REFUSAL_OFFER_PENALTY below rather than picked on feel: a push that lands has to be
-- worth more than a push that doesn't costs, or haggling is a losing move at every cook state and the
-- whole mechanic is decoration. At these numbers a landed push averages +$47 on that skewer against the
-- $30 a refusal takes off the next opening range.
--
-- Keep the pair low even so. The old flat-slice-of-value version added a fixed 8-12% every round no matter
-- how far in it was, which is what made a haggle leap instead of inching; a share this size of the gap is
-- what keeps each step to a few points. The chance a push lands (CookStates.CounterChance) is the dial to
-- reach for first -- it makes haggling reliable without making any one round bigger.
-- Higher = bigger, jumpier rounds that eat most of the gap at once. Lower = pushing barely moves the
-- number and the haggle stops being worth the risk.
SellNpc.COUNTER_INCREASE_MIN = 0.11
SellNpc.COUNTER_INCREASE_MAX = 0.18

-- How many times one customer will ever sweeten its offer. CounterChance decaying by
-- COUNTER_CHANCE_FALLOFF already makes a long haggle unlikely, but unlikely isn't never -- and an
-- unbounded haggle is one a patient player can ride to the ceiling. Three is also what gives the haggle
-- sounds somewhere to go: the first counter plays Haggle1, the rest play Haggle2 pitched up a step each.
-- Higher = rare long runs are possible again and the top of the ceiling comes back into reach.
-- Lower = the ceiling stops being reachable at all and CounterCap turns decorative.
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

-- Seconds a pending offer goes unanswered before it nudges the player again, repeating until they answer
-- or the window shuts. The opening toast is easy to miss -- only four fit on screen at once -- and the
-- offer's own billboard is no use from the grill, so without this a sale can lapse purely because nobody
-- saw it. The rich customer shares this rather than carrying its own; a shorter window doesn't want a
-- different reminder rhythm.
-- Higher = fewer reminders, and more offers quietly lost. Lower = nagging, and the toast crowds the rest
-- of the screen out.
SellNpc.OFFER_NUDGE_INTERVAL = 10

-- The red flash the waiting customer wears alongside each nudge, so the toast points at someone rather
-- than just saying one of them is waiting. Fed straight to the HighlightPulse effect: START_TRANSPARENCY
-- is where the fill begins before it tweens out, and COUNT is how many times it does so across DURATION.
-- Higher COUNT = a faster, more urgent blink. 1 is a single slow fade.
SellNpc.NUDGE_PULSE_COLOR = Color3.fromRGB(255, 0, 0)
SellNpc.NUDGE_PULSE_START_TRANSPARENCY = 0.35
SellNpc.NUDGE_PULSE_DURATION = 2
SellNpc.NUDGE_PULSE_COUNT = 3

-- What turning offers down costs. Without these it costs nothing at all: the skewer goes straight back on
-- the stand, the next customer prices it from the full range again, and a player who declines everything
-- eventually accepts near the ceiling for the price of a few seconds' waiting. So a refusal is remembered
-- against the player, and every one still standing does two things -- shifts the next customer's whole
-- opening range down by PENALTY of the skewer's sell value, and adds RETRY_DELAY seconds to the wait
-- before that customer arrives. Two small costs rather than one harsh one: the money side is what removes
-- the reason to reroll, and the time side is the part that can't feel unfair.
--
-- The shifted range is floored at the skewer's plain sell value, so declining stops paying a bonus but
-- never pays out a loss -- and the offer still can't come in under the estimate the player was shown.
-- A well-cooked skewer therefore runs from +10-35% clean down to +1-26% at PENALTY_MAX, and a charred one
-- (opening at 1-1.05) is squeezed almost flat, so rerolling a burnt skewer is worth next to nothing.
--
-- Deliberately smaller than what one landed counter-offer pays (see COUNTER_INCREASE above). A refusal has
-- to cost less than a successful push earns, or the arithmetic tells the player never to haggle -- which
-- is the opposite of what the stand is built around. What it still has to beat is the *free* reroll: a
-- player declining everything to fish for a high opening roll.
--
-- Refusals are stored in player data on the synced clock rather than a session timer, for the same reason
-- the rich customer's cooldown is: rejoining or hopping servers would otherwise wipe the slate.
-- Higher PENALTY = a couple of refusals gut the offer and the mechanic reads as punishing. Lower = the
-- reroll is profitable again.
-- Higher DECAY = the penalty hangs over a session for much longer. Lower = waiting it out beats selling.
-- Higher PENALTY_MAX = the floor is reached and there's nothing left to lose by declining forever.
SellNpc.REFUSAL_OFFER_PENALTY = 0.03
SellNpc.REFUSAL_PENALTY_MAX = 3
SellNpc.REFUSAL_DECAY = 60
SellNpc.REFUSAL_RETRY_DELAY = 2

-- The narrowest the penalty is allowed to squeeze an opening range. Without it the two ends converge --
-- OfferMax is floored to OfferMin, and the states that open at 1 reach that floor first -- so a charred or
-- raw skewer stops being offered a range at all and comes back the same number every single time. A dead
-- identical price reads as a broken customer rather than a penalised one, so a sliver of spread is kept
-- even at PENALTY_MAX. The penalty still lands; it just can't flatten the roll out of existence.
-- Higher = the penalty stops biting on the states that open near 1. Lower = those states go deterministic.
SellNpc.MIN_OFFER_SPREAD = 0.02

-- How far the customer steps back after buying, and how long it eats there. Each eater picks a random
-- back distance in this range plus a random sideways offset (up to EAT_SPREAD either way), so finished
-- customers scatter into a loose crowd instead of lining up behind the stand.
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
