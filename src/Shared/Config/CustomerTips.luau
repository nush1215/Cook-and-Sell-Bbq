-- Customers tipping Gems on top of what they paid, likelier the better the BBQ. See docs/balance.md.

--
local CustomerTips = {}

-- Chance out of 100 that a stand customer tips an ordinary BBQ: Cooked, plain, Common, on a stick with room left
CustomerTips.STAND_CHANCE = 20

-- Chance out of 100 that a custom order customer tips a good one: exactly what it asked for, cooked Perfect
CustomerTips.CUSTOM_ORDER_CHANCE = 85

-- What each cook state multiplies the chance by. Cooked is the ordinary one, and an unlisted state never tips
CustomerTips.COOK_STATE_MULTIPLIERS = {
	Perfect = 1.25,
	Cooked = 1,
	Overcooked = 0.5,
}

table.freeze(CustomerTips.COOK_STATE_MULTIPLIERS)

-- The boost for a stick filled to capacity. Stand only: a custom order fixes the count itself
CustomerTips.FULL_STICK_MULTIPLIER = 1.1

-- The boost for a mutated BBQ (Golden, Shocked)
CustomerTips.MUTATION_MULTIPLIER = 1.25

-- What each tier above Common adds to the multiplier, off the mean tier of the stick's ingredients
CustomerTips.TIER_STEP = 0.05

-- Seconds after a player's tip is rolled before their next can be, so two never land on top of each other
CustomerTips.MIN_GAP = 15

-- The Gems one tip leaves, rolled per tip
CustomerTips.STAND_GEMS_MIN = 5
CustomerTips.STAND_GEMS_MAX = 10
CustomerTips.CUSTOM_ORDER_GEMS_MIN = 15
CustomerTips.CUSTOM_ORDER_GEMS_MAX = 20
CustomerTips.SEATED_GEMS_MIN = 20
CustomerTips.SEATED_GEMS_MAX = 30
CustomerTips.RICH_GEMS_MIN = 35
CustomerTips.RICH_GEMS_MAX = 50

-- The boost for a custom order customer eating seated at a table
CustomerTips.SEATED_CHANCE_MULTIPLIER = 1.2

-- Seconds into the eat before the tipping line, then from the line to the Gems landing; both inside SellNpc.EAT_DURATION
CustomerTips.SAY_DELAY = 3
CustomerTips.PAY_DELAY = 1

return CustomerTips
