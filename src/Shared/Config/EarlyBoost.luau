--[[
    The head start a new player gets, and how it fades.

    A fresh base earns about the same per minute as an established one -- throughput is capped by how
    fast a skewer cooks rather than by how much money is behind it -- while what things cost climbs
    steeply (plots run 1K to 5M). So the opening is the slowest the game ever feels, which is exactly
    backwards. This is what fixes that, on four dials: what a sale pays, how long the player waits
    for the customer, how often that customer walks off without buying, and how often a rolling stand
    shows off something they can't afford yet. All four are hardest at the very start and taper to
    nothing by the time the player is properly going.

    The money is only half of it. Paying more per sale doesn't touch the rhythm of a sale, and the
    opening is where the dead air costs most -- few skewers, no upgrades to fill the gap, and a
    walk-off burning a whole retry cycle out of very little. Hence the two pacing dials beside it.

    The fourth isn't pacing at all, it's the reason to keep going. An early base rolls almost nothing
    but Commons, and the good stuff sits hundreds to thousands of rolls out, so a new player has no
    picture of what they're playing towards -- the opening reads as the whole game rather than the
    start of one. The teaser hands one stand over to something out of reach so they can walk up and
    read the price off it. It's the only dial here that gives nothing away: what it costs the player
    is the ordinary ingredient that stand would have rolled, and pulling again is free.

    Keyed on lifetime earnings rather than playtime, and that's the whole design. It can't be idled
    through, it measures how far along the player actually is instead of how long they've been sat
    there, and it spends itself down -- TotalEarned is bumped by what actually lands, boosts included,
    so a boosted dollar burns the meter faster than a plain one and the taper closes itself out. It
    also means anyone already past the threshold gets exactly nothing the moment this ships, so an
    established player never sees it and there's nothing to migrate.

    One key and one curve for all four, so they fade out together rather than one outliving the
    others and leaving the opening half-boosted. The teaser wants that most of all: a player still
    being shown things they can't buy after the head start has gone is being told they're behind.

    What GetBonus gives back is the bonus fraction, not a multiplier -- CurrencyManager stacks it into
    the same running `addition` as the gamepass and friend boosts, all of them figured on the base
    amount. So a brand-new player holding x2Bux gets 1 + 1 + 0.5, not 2 x 1.5. The two pacing dials
    are the other way round: they give back a multiplier for their caller to scale by, and
    GetTeaseChance a percentage to roll against.
]]

--
local EarlyBoost = {}

-- How high each dial starts, and the one THRESHOLD that says how long they all run. There's no dial for
-- the curve between them on purpose -- see getFade.

-- The bonus at nothing earned, as a fraction of the base amount: 0.5 is half again on every sale.
-- Raise it to make the opening more generous without moving where it stops -- it lifts the whole curve
-- rather than lengthening it, since THRESHOLD is the only thing that says when this is over.
EarlyBoost.MAX_BONUS = 0.5

-- How much of the wait for a customer is taken off at nothing earned: 0.3 is a 30% shorter wait, so
-- SellNpc's 8-15s range lands at roughly 5.6-10.5s for a brand-new player.
-- Higher = the opening sells faster. Lower = it keeps the established pace and only the money differs.
-- It scales the whole range, so the spread stays proportional rather than the floor closing on the top.
EarlyBoost.MAX_SPAWN_SPEEDUP = 0.3

-- How much of the walk-off chance is taken off at nothing earned: 0.5 halves it, so SellNpc's 1-in-5
-- refusal is 1-in-10 for a brand-new player. It scales the refusal share rather than lifting
-- INTERESTED_CHANCE, so 1 is the ceiling by construction and this can't overshoot into never refusing.
-- Higher = fewer wasted visits early. Lower = the thinking moment reads the same from the first skewer.
EarlyBoost.MAX_DECLINE_REDUCTION = 0.5

-- How often a pull is given over to showing off something out of reach at nothing earned, as a
-- percentage: 8 is about one pull in twelve. Higher = the good stuff is in front of a new player more
-- often. Lower = it stays a surprise. Cheap to be generous with -- it costs them the one ingredient that
-- stand would have rolled, and the lever is free -- but it is still a pull that fed them nothing, so
-- this wants to stay well short of common enough to read as the stand wasting their time.
EarlyBoost.MAX_TEASE_CHANCE = 10

-- How many times over their Bux a teased ingredient has to cost to count as out of reach. At 1 it would
-- only have to be a dollar clear and the next sale would close it, which makes it a purchase they were
-- about to make rather than something to play towards -- the want is the whole point.
--
-- Measured against what they're holding rather than what they've earned, so it tracks a player who just
-- spent everything on a plot. That also means the pool climbs the ladder on its own as they get richer:
-- $100 in hand draws from the whole cool roster, $10,000 from Lamb alone, and past $20,000 there's
-- nothing dear enough left to show them -- which is the teaser bowing out on its own, before the fade
-- below gets to it.
EarlyBoost.TEASE_AFFORD_MARGIN = 3

-- Lifetime earnings at which the bonus has run out entirely. This is the length of the head start, and
-- it's in dollars rather than minutes on purpose: a player who found a good loop gets through it sooner
-- than one still learning, which is the right way round.
--
-- What sets it is where the fade is steepest, not where it ends. Smoothstep sheds the bonus fastest at
-- the halfway mark, so this is sized at twice the fourth plot (Config.Plots.Costs) to land that on the
-- plot-4 purchase -- the biggest drop lands on the biggest thing the player buys, instead of part-way
-- between two of them where nothing arrives to cover it. At the 100,000 this used to read, the steep
-- part fell at 50,000, and the only purchases either side of it were roll speed and rolling stands,
-- which add ingredient supply rather than throughput: one stand already feeds about four grills, so
-- they buy nothing at all for a player under that. Income went down and there was no way to spend
-- their way out of it, which is what read as the game stalling.
--
-- Re-sizing this means re-checking what the new midpoint lands on, and moving a purchase onto it is
-- as good a fix as moving the threshold.
EarlyBoost.THRESHOLD = 150_000

-- How far through the head start this much lifetime income is: 0 at nothing earned, 1 at and past
-- THRESHOLD. Every dial runs off this, so none of them can drift onto its own curve or threshold.
local function getFade(totalEarned: number): number
	local progress = math.clamp(totalEarned / EarlyBoost.THRESHOLD, 0, 1)

	-- Smoothstep, so the fade is flat at both ends: the head start barely moves over the opening, gives
	-- way through the middle, and eases into zero rather than arriving there still on a slope. This used
	-- to be a tunable exponent, which is what made the early game read as the game slowing down -- an
	-- exponent can only ever be flat at one end, so whichever way it was set there was a stretch where
	-- income visibly fell away, and at the start is the worst place for that: it's where the player has
	-- the fewest upgrades of their own to cover the drop.
	return progress * progress * (3 - 2 * progress)
end

-- The bonus fraction a player with this much lifetime income still earns on top of what they're paid.
-- Zero at and past THRESHOLD, so a caller can add it unconditionally.
function EarlyBoost.GetBonus(totalEarned: number): number
	return EarlyBoost.MAX_BONUS * (1 - getFade(totalEarned))
end

-- What the wait for a customer to show up is multiplied by. 1 at and past THRESHOLD, so a caller can
-- apply it unconditionally.
function EarlyBoost.GetSpawnDelayScale(totalEarned: number): number
	return 1 - EarlyBoost.MAX_SPAWN_SPEEDUP * (1 - getFade(totalEarned))
end

-- What a customer's chance of walking off without buying is multiplied by. 1 at and past THRESHOLD, so
-- a caller can apply it unconditionally.
function EarlyBoost.GetDeclineScale(totalEarned: number): number
	return 1 - EarlyBoost.MAX_DECLINE_REDUCTION * (1 - getFade(totalEarned))
end

-- The chance a pull shows off an ingredient this player can't afford yet, as a percentage. Zero at and
-- past THRESHOLD, so a caller can roll it unconditionally.
function EarlyBoost.GetTeaseChance(totalEarned: number): number
	return EarlyBoost.MAX_TEASE_CHANCE * (1 - getFade(totalEarned))
end

return EarlyBoost
