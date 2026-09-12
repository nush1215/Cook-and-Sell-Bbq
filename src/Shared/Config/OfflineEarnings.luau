-- What the hut's workers get done while their owner is away, and how it's claimed. See docs/balance.md.

--
local OfflineEarnings = {}

-- The ScreenGui the welcome-back panel lives in
OfflineEarnings.UI_NAME = "OfflineEarningUI"

-- Under this, a rejoin is a server hop or a crash rather than time away
OfflineEarnings.MIN_AWAY_SECONDS = 60

-- The most time away one absence is credited for
OfflineEarnings.MAX_AWAY_SECONDS = 24 * 60 * 60

-- How much of the time away the workers are credited for; 1 is the pace they work at while watched
OfflineEarnings.WORK_RATE = 1

-- Seconds between LastSeenAt refreshes, so a crashed server can't credit a whole session as time away
OfflineEarnings.HEARTBEAT_INTERVAL = 60

-- Studs of a typical walk between two stations, divided by the star walk speed. A base's real layout isn't
-- read at load, and the walk is the smallest part of any trip beside the cook and the customer
OfflineEarnings.WALK_LEG_STUDS = 40

-- Seconds a customer spends walking up, on top of SellNpc's spawn and decide waits
OfflineEarnings.CUSTOMER_WALK_SECONDS = 5

-- The most skewers one pass steps through, bounding what a join costs; a stocked day lands well under it
OfflineEarnings.MAX_SIMULATED_SKEWERS = 2000

-- Above this the amount reads with a suffix rather than commas, so a big number stays legible
OfflineEarnings.SUFFIX_THRESHOLD = 10_000

-- Why the workers stopped, as the report carries it. Nil on the report means they worked to the horizon
OfflineEarnings.STOP_REASONS = {
	NO_MAKER = "NoMaker",
	NO_COOKER = "NoCooker",
	NO_SELLER = "NoSeller",
	NO_STAND = "NoStand",
	NO_GRILL = "NoGrill",
	NO_STICKS = "NoSticks",
	NO_INGREDIENTS = "NoIngredients",
	EMPTY = "Empty",
}

table.freeze(OfflineEarnings.STOP_REASONS)

return OfflineEarnings
