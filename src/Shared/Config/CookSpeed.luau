--
local CookSpeed = {}

-- How much one level speeds a grill up, and how many levels it can take: level N cooks at
-- 1 + INCREMENT * N times speed, so 20 levels tops out at 2x.
CookSpeed.INCREMENT = 0.05
CookSpeed.MAX_LEVEL = 20

-- Costs[n] is what level n costs to own, matching the BaseUnlocks convention -- a purchase reads
-- Costs[currentLevel + 1]. Kept dense to MAX_LEVEL.
--
-- The curve runs in three phases, each with its own step ratio, so the numbers stay easy to nudge by
-- hand. The opening levels are near-free to get the first upgrades landing straight away: a player
-- spawns with 500, so levels 1 and 2 cost 260 together and leave them 10 short of level 3.
--
-- The grind phase is priced against where income is heading rather than where it is today -- sauces,
-- the x2/VIP passes and the Legendary/Mythic tiers are all still empty, and between them they're
-- worth roughly an order of magnitude on late-game earnings. Scale it down if that content slips.
CookSpeed.Costs = {
	-- Hook, x1.6 a level
	100,
	160,
	250,
	400,
	650,
	1_000,
	1_600,
	2_500,
	-- Steady, x2 a level
	5_000,
	10_000,
	20_000,
	40_000,
	80_000,
	160_000,
	-- Grind, x2.5 a level
	400_000,
	1_000_000,
	2_500_000,
	6_500_000,
	16_000_000,
	40_000_000,
}

-- What each grill scales the costs above by, so later grills are pricier to speed up: grill 1 pays the
-- list price, grill 2 pays 1.5x, and so on. Kept to a gentle spread on purpose -- the grind belongs in
-- the level curve above, and stacking a steep multiplier on top of it just turns the later grills into
-- something nobody ever upgrades. A grill past the end of this list uses the last entry, so adding a
-- grill to the place file doesn't have to mean touching this.
CookSpeed.SlotCostMultipliers = { 1, 1.5, 2, 2.5, 3 }

-- The Robux dev products a level can be bought with, cheapest first. Unlike BaseUnlocks.RobuxProductIds
-- these are keyed by *tier*, not by the level they buy: there are 20 levels and only 10 products, so a
-- product is a price band rather than a particular level. ProductTiers below is what picks the band, and
-- every one of them buys the player's next level on the grill they prompted it from -- so a receipt that
-- lands out of order can't skip a level or hand out one they already own.
CookSpeed.RobuxProductIds = {
	3709025322,
	3709025352,
	3709025371,
	3709025391,
	3709025414,
	3709025448,
	3709025463,
	3709025557,
	3709025569,
	3709025591,
}

-- ProductTiers[n] is the band level n is sold in. Weighted toward the middle of the ladder on purpose:
-- the opening levels cost a few hundred Bux and nobody spends Robux on them, so they share the cheapest
-- band, while the levels either side of 10k-160k -- where the Bux price is real money's worth of play
-- but not yet absurd -- get a band each. The top of the Costs curve runs away far faster than any Robux
-- ladder can follow, so those levels share the last band and are knowingly the best value on the list.
CookSpeed.ProductTiers = {
	-- 100 - 400 Bux
	1,
	1,
	1,
	1,
	-- 650 - 1.6k
	2,
	2,
	2,
	-- 2.5k - 5k
	3,
	3,
	-- 10k, 20k, 40k, 80k, 160k -- a band each
	4,
	5,
	6,
	7,
	8,
	-- 400k - 1M
	9,
	9,
	-- 2.5M - 40M
	10,
	10,
	10,
	10,
}

-- How many bands up the tier moves on each grill, so a later grill costs more Robux to speed up the same
-- way it costs more Bux. Derived from SlotCostMultipliers above against a band step of roughly 1.4x:
-- 1.5x is about a band, 3x about two. A grill past the end of this list uses the last entry, the same way
-- GetCost handles one, so adding a grill to the place file doesn't have to mean touching this.
CookSpeed.SlotTierOffsets = { 0, 1, 1, 2, 2 }

table.freeze(CookSpeed.Costs)
table.freeze(CookSpeed.SlotCostMultipliers)
table.freeze(CookSpeed.RobuxProductIds)
table.freeze(CookSpeed.ProductTiers)
table.freeze(CookSpeed.SlotTierOffsets)

-- How much faster a grill at this level cooks, as a multiple of the base cook time.
function CookSpeed.GetMultiplier(level: number): number
	return 1 + CookSpeed.INCREMENT * level
end

-- The multiplier as it reads on a sign -- "1.0", "1.05", "1.1" rather than "1.00", "1.10". Always
-- keeps a decimal, so a sign reads "1.0x>1.05x" instead of jumping from a whole number.
function CookSpeed.FormatMultiplier(level: number): string
	local text = string.format("%.2f", CookSpeed.GetMultiplier(level))
	return (text:gsub("(%.%d)0$", "%1"))
end

-- What `level` costs to own on the given grill, or nil past the cap.
function CookSpeed.GetCost(slotNumber: number, level: number): number?
	local cost = CookSpeed.Costs[level]
	if not cost then
		return nil
	end

	local multipliers = CookSpeed.SlotCostMultipliers
	local multiplier = multipliers[math.min(slotNumber, #multipliers)]

	return math.round(cost * multiplier)
end

-- The Products.luau string id for one of the Robux price bands. Built in one place so the config that
-- generates the product and the code that prompts it can't drift apart.
function CookSpeed.GetProductStringId(tier: number): string
	return `CookSpeed_T{tier}`
end

-- The string id of the product that buys `level` on the given grill, or nil past the cap. The band comes
-- off the level and is then shifted up by the grill, so the same level costs more Robux on a later one.
function CookSpeed.GetProductStringIdForLevel(slotNumber: number, level: number): string?
	local tier = CookSpeed.ProductTiers[level]
	if not tier then
		return nil
	end

	local offsets = CookSpeed.SlotTierOffsets
	local offset = offsets[math.min(slotNumber, #offsets)]

	return CookSpeed.GetProductStringId(math.min(tier + offset, #CookSpeed.RobuxProductIds))
end

return CookSpeed
