-- The customer who asks for a named recipe against a clock, and pays a premium for it. See docs/balance.md.

--
local CustomOrderNpc = {}

-- Sweep interval and per-player chance out of 100; with COOLDOWN these set how often an order turns up
CustomOrderNpc.CHECK_INTERVAL = 10
CustomOrderNpc.SPAWN_CHANCE = 80

-- Seconds before that player can draw another, so a lucky run can't queue orders back to back
CustomOrderNpc.COOLDOWN = 30

-- What the player needs before an order is fillable at all: either is enough, neither and they never come
CustomOrderNpc.MIN_GRILLERS = 2
CustomOrderNpc.MIN_ROLLING_STANDS = 2

-- The two ways a visit opens. Named rather than a boolean, so the command bar can ask for one by name
CustomOrderNpc.VARIATIONS = {
	Inspect = "Inspect",
	Direct = "Direct",
}

-- Share of visits out of 100 that open on Inspect, rather than asking on arrival
CustomOrderNpc.INSPECT_CHANCE = 50

-- Seconds between the Not Interested verdict landing and the ask, so the two beats read apart
CustomOrderNpc.REQUEST_DELAY = 1.5

-- How many ingredients an order names, before the player's best stick caps it
CustomOrderNpc.SLOT_COUNT_MIN = 2
CustomOrderNpc.SLOT_COUNT_MAX = 4

-- What an order asks for, out of 100. Weighted low so most orders are fillable, not a shopping list
CustomOrderNpc.TIER_WEIGHTS = {
	Common = 55,
	Uncommon = 30,
	Rare = 12,
	Epic = 2.5,
	Legendary = 0.5,
}

-- How much likelier an ingredient already in stock is to be asked for, so orders start part-filled
CustomOrderNpc.OWNED_WEIGHT_BONUS = 3

-- The most an unowned ingredient may cost, as a multiple of their Bux -- past this it isn't an order, it's a wall
CustomOrderNpc.AFFORD_FACTOR = 1.5

-- The premium on a perfect exact fill, climbing with what was asked for. See docs/balance.md
CustomOrderNpc.BASE_MULTIPLIER = 1.5
CustomOrderNpc.TIER_STEP = 0.12
CustomOrderNpc.MULTIPLIER_CAP = 2

-- What each ingredient they added but weren't asked for costs, so padding the stick out can't pay
CustomOrderNpc.EXTRA_INGREDIENT_PENALTY = 0.15

-- Resolved orders kept as facts for the rolling rating window, the way StatsManager.RECENT_SALES is
CustomOrderNpc.HISTORY_LENGTH = 20

-- The clock, split so a long recipe gets cooking time and every slot gets time to be rolled for
CustomOrderNpc.LEEWAY_BASE = 90
CustomOrderNpc.LEEWAY_PER_INGREDIENT = 45

-- Seconds it waits for an answer, so an ignored order doesn't hold its cooldown forever
CustomOrderNpc.OFFER_TIMEOUT = 30

-- Rolls that may pass without a wanted ingredient before the next one is forced to it
CustomOrderNpc.ROLL_PITY_THRESHOLD = 2

-- Where it stands once the deal is struck: off to one side, clear of the stand but still in sight
CustomOrderNpc.WAIT_SIDE_DISTANCE_MIN = 6
CustomOrderNpc.WAIT_SIDE_DISTANCE_MAX = 9
CustomOrderNpc.WAIT_BACK_DISTANCE = 4

-- Seconds between empty-handed scoldings, so leaning on the prompt can't stack bubbles on themselves
CustomOrderNpc.EMPTY_HANDED_INTERVAL = 1.5

-- Seconds left before the order starts being flagged as running out
CustomOrderNpc.HURRY_THRESHOLD = 60
CustomOrderNpc.HURRY_INTERVAL = 31

-- The red flash on a customer about to leave, fed to HighlightPulse. Matches the sell stand's nudge
CustomOrderNpc.HURRY_PULSE_COLOR = Color3.fromRGB(255, 0, 0)
CustomOrderNpc.HURRY_PULSE_START_TRANSPARENCY = 0.35
CustomOrderNpc.HURRY_PULSE_DURATION = 2
CustomOrderNpc.HURRY_PULSE_COUNT = 3

-- The order card springing up from nothing. Under 1 damping for the overshoot that makes it pop
CustomOrderNpc.UI_POP_DAMPING = 0.6
CustomOrderNpc.UI_POP_FREQUENCY = 3

-- How it walks, fades, stands and eats it reads off SellNpc

return CustomOrderNpc
