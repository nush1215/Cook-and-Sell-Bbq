-- A new player's head start: four dials fading out together over lifetime earnings. See docs/balance.md.

--
local EarlyBoost = {}

-- How high each dial starts; THRESHOLD alone says how long they run. No curve dial -- see getFade

-- The income bonus at nothing earned. Lifts the whole curve rather than lengthening it
EarlyBoost.MAX_BONUS = 0.5

-- How much of the customer wait comes off at nothing earned; scales the whole range proportionally
EarlyBoost.MAX_SPAWN_SPEEDUP = 0.3

-- How much of the walk-off chance comes off; scales the refusal share, so 1 stays the ceiling
EarlyBoost.MAX_DECLINE_REDUCTION = 0.5

-- How often a pull teases instead of rolling, as a percentage. Cheap, but still a pull that fed nothing
EarlyBoost.MAX_TEASE_CHANCE = 7

-- How far out of reach a teaser must be, measured on Bux held so it tracks someone who just spent.
EarlyBoost.TEASE_AFFORD_MARGIN = 2

-- Lifetime earnings where the boost ends. Sized on where the fade is steepest -- see docs/balance.md.
EarlyBoost.THRESHOLD = 150_000

-- How far through the head start `totalEarned` is: 0 at nothing, 1 at and past THRESHOLD.
local function getFade(totalEarned: number): number
	local progress = math.clamp(totalEarned / EarlyBoost.THRESHOLD, 0, 1)

	-- Smoothstep, flat at both ends -- an exponent can only be flat at one, which read as the game slowing
	return progress * progress * (3 - 2 * progress)
end

-- The income bonus still owed at `totalEarned`. Zero past THRESHOLD, so a caller can add it unconditionally.
function EarlyBoost.GetBonus(totalEarned: number): number
	return EarlyBoost.MAX_BONUS * (1 - getFade(totalEarned))
end

-- What the customer wait is multiplied by. 1 past THRESHOLD, so a caller can apply it unconditionally.
function EarlyBoost.GetSpawnDelayScale(totalEarned: number): number
	return 1 - EarlyBoost.MAX_SPAWN_SPEEDUP * (1 - getFade(totalEarned))
end

-- What the walk-off chance is multiplied by. 1 past THRESHOLD, so a caller can apply it unconditionally.
function EarlyBoost.GetDeclineScale(totalEarned: number): number
	return 1 - EarlyBoost.MAX_DECLINE_REDUCTION * (1 - getFade(totalEarned))
end

-- The teaser chance at `totalEarned`, as a percentage. Zero past THRESHOLD, so a caller can roll it unconditionally.
function EarlyBoost.GetTeaseChance(totalEarned: number): number
	return EarlyBoost.MAX_TEASE_CHANCE * (1 - getFade(totalEarned))
end

return EarlyBoost
