-- A well-rated stall's pull: four dials rising together with the headline star. Live play only, never offline. See docs/balance.md.

-- Config
local Rating = require(script.Parent.Rating)

--
local RatingPerks = {}

-- How strong each dial is at full stars; START_STARS alone says where they all begin

-- The headline star the perks start from. At and below it the stall plays at the base pace, so a low rating never costs anything
RatingPerks.START_STARS = 2

-- How much of the wait for a customer comes off: the stand's arrival delay and the custom order cooldown
RatingPerks.MAX_ARRIVAL_SPEEDUP = 0.2

-- How much of the rich customer cooldown comes off
RatingPerks.MAX_RICH_SPEEDUP = 0.2

-- How far an opening offer's floor rises towards its top. Only the floor, so the best offer stays one anyone could roll
RatingPerks.MAX_OFFER_LIFT = 0.4

-- The tip chance bonus, as a fraction of the chance. The Gems a tip leaves don't change
RatingPerks.MAX_TIP_BONUS = 0.25

-- How far `stars` sits between START_STARS and full stars, 0-1. Linear, so every star past the start is worth the same.
local function getProgress(stars: number?): number
	return math.clamp(((stars or 0) - RatingPerks.START_STARS) / (Rating.MAX_STARS - RatingPerks.START_STARS), 0, 1)
end

-- What a customer wait is multiplied by. 1 at and below START_STARS, so a caller can apply it unconditionally.
function RatingPerks.GetArrivalScale(stars: number?): number
	return 1 - RatingPerks.MAX_ARRIVAL_SPEEDUP * getProgress(stars)
end

-- What the rich customer cooldown is multiplied by. 1 at and below START_STARS, so a caller can apply it unconditionally.
function RatingPerks.GetRichCooldownScale(stars: number?): number
	return 1 - RatingPerks.MAX_RICH_SPEEDUP * getProgress(stars)
end

-- The share of an opening range's gap its floor rises by. 0 at and below START_STARS, so a caller can apply it unconditionally.
function RatingPerks.GetOfferLift(stars: number?): number
	return RatingPerks.MAX_OFFER_LIFT * getProgress(stars)
end

-- What a tip chance is multiplied by. 1 at and below START_STARS, so a caller can apply it unconditionally.
function RatingPerks.GetTipChanceScale(stars: number?): number
	return 1 + RatingPerks.MAX_TIP_BONUS * getProgress(stars)
end

return RatingPerks
