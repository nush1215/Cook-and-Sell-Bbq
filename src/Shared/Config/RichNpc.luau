-- The rare bulk buyer: takes the whole stand for one lump sum and never says no. See docs/balance.md.

--
local RichNpc = {}

-- Sweep interval and per-player chance out of 100; with COOLDOWN these set how often a rich one turns up
RichNpc.CHECK_INTERVAL = 10
RichNpc.SPAWN_CHANCE = 60

-- Skewers needed before a rich visit is worth sending -- a bulk buyer for one skewer wastes the feature
RichNpc.MIN_SKEWERS = 2

-- Seconds before that player can draw another, so a lucky run can't queue rich customers
RichNpc.COOLDOWN = 150

-- Seconds spent appraising the haul, standing in for the decide beat it doesn't run
RichNpc.APPRAISE_DURATION_MIN = 2
RichNpc.APPRAISE_DURATION_MAX = 3

-- The premium on top of the batch, each skewer having been priced by its own cook state first
RichNpc.BULK_MULTIPLIER = 1.6

-- Chance out of 100 that declining gets a better price; above a cooked skewer's 80, and still decays
RichNpc.COUNTER_CHANCE = 85

-- The ceiling and the share of the gap each round closes. Must stay above the highest opening (2.16x)
RichNpc.COUNTER_INCREASE_MIN = 0.05
RichNpc.COUNTER_INCREASE_MAX = 0.1
RichNpc.OFFER_CAP_FACTOR = 2.4

-- Matches SellNpc.MAX_COUNTER_ROUNDS, for the same reason
RichNpc.MAX_COUNTER_ROUNDS = 3

-- Seconds it waits for an answer. Shorter than normal -- the whole stand is off the shelf while it waits
RichNpc.OFFER_TIMEOUT = 25

return RichNpc
