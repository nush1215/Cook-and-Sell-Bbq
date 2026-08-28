--[[
    The head start a new player's income gets, and how it fades.

    A fresh base earns about the same per minute as an established one -- throughput is capped by how
    fast a skewer cooks rather than by how much money is behind it -- while what things cost climbs
    steeply (plots run 1K to 5M). So the opening is the slowest the game ever feels, which is exactly
    backwards. This is what fixes that: every dollar of gameplay income is topped up, hardest at the
    very start, tapering to nothing by the time the player is properly going.

    Keyed on lifetime earnings rather than playtime, and that's the whole design. It can't be idled
    through, it measures how far along the player actually is instead of how long they've been sat
    there, and it spends itself down -- TotalEarned is bumped by what actually lands, boosts included,
    so a boosted dollar burns the meter faster than a plain one and the taper closes itself out. It
    also means anyone already past the threshold gets exactly nothing the moment this ships, so an
    established player never sees it and there's nothing to migrate.

    What comes out is the bonus fraction, not a multiplier -- CurrencyManager stacks it into the same
    running `addition` as the gamepass and friend boosts, all of them figured on the base amount. So a
    brand-new player holding x2Bux gets 1 + 1 + 2, not 2 x 3.
]]

--
local EarlyBoost = {}

-- The bonus at nothing earned, as a fraction of the base amount: 2 is triple income. Raise it to make
-- the opening more generous without moving where it stops -- it steepens the whole curve rather than
-- lengthening it, since THRESHOLD is the only thing that says when this is over.
EarlyBoost.MAX_BONUS = 0.65

-- Lifetime earnings at which the bonus has run out entirely. This is the length of the head start, and
-- it's in dollars rather than minutes on purpose: a player who found a good loop gets through it sooner
-- than one still learning, which is the right way round.
EarlyBoost.THRESHOLD = 50_000

-- The shape of the fade between those two. 1 is a straight line; above it the bonus drops away early
-- and trails a long thin tail, below it the bonus holds high and then falls off a cliff near the end.
-- Kept at 1 because the tail is what the player feels as "slowing down", and either extreme turns that
-- into a moment they notice rather than something that just happens.
EarlyBoost.FALLOFF = 1

-- The bonus fraction a player with this much lifetime income still earns on top of what they're paid.
-- Zero at and past THRESHOLD, so a caller can add it unconditionally.
function EarlyBoost.GetBonus(totalEarned: number): number
	local progress = math.clamp(totalEarned / EarlyBoost.THRESHOLD, 0, 1)
	return EarlyBoost.MAX_BONUS * (1 - progress) ^ EarlyBoost.FALLOFF
end

return EarlyBoost
