-- The player's 0-5 star reputation and the four traits behind it. Every weight table must add up to 1; see docs/balance.md.

-- Shared
local MathUtil = require(script.Parent.Parent.MathUtil)

-- Config
local Ingredients = require(script.Parent.Ingredients)
local Sticks = require(script.Parent.Sticks)
local Structures = require(script.Parent.Structures)
local Plots = require(script.Parent.Plots)
local BaseUnlocks = require(script.Parent.BaseUnlocks)
local SellNpc = require(script.Parent.SellNpc)

--
local Rating = {}

-- The scale everything below is written against
Rating.MAX_STARS = 5

-- Decimals a rating shows in a panel title, e.g. "Menu (3.58)". Two, so the number and its stars agree
Rating.TITLE_DECIMALS = 2

-- What stands in for a rating with too little behind it to score
Rating.PENDING_TEXT = "—"

-- How the headline reads above the four traits, and how the world sign's own title reads
Rating.OVERALL_NAME = "Overall Rating"
Rating.SIGN_TITLE = "Rating"

-- The folder on a base model holding the rating's world parts, and the board under it the star sign adorns
Rating.BASE_FOLDER = "Rating"
Rating.SIGN_PATH = { "Sign", "Board" }

table.freeze(Rating.SIGN_PATH)

-- How far back the traits read. Longer is steadier, shorter is more responsive -- this is the knob
Rating.SALE_WINDOW = 50
Rating.ORDER_WINDOW = 50

-- Entries a trait needs before it reports at all, so a new player isn't shown a zero they can't move
Rating.MIN_SALE_SAMPLE = 5
Rating.MIN_ORDER_SAMPLE = 3

-- How far off 1 a weight table may sum before the load-time warn fires
Rating.WEIGHT_SUM_TOLERANCE = 0.001

-- The traits behind the headline, in display order
Rating.TRAITS = { "Cooking", "Satisfaction", "Menu", "Kitchen" }

table.freeze(Rating.TRAITS)

-- [traitId] = how it reads, and its frame under the panel's Container -- named, since the UI calls Satisfaction's row CustomerSatisfaction
Rating.TraitDisplay = {
	Cooking = { Name = "Cooking Quality", Frame = "Cooking" },
	Satisfaction = { Name = "Customer Satisfaction", Frame = "CustomerSatisfaction" },
	Menu = { Name = "Menu", Frame = "Menu" },
	Kitchen = { Name = "Kitchen", Frame = "Kitchen" },
}

table.freeze(Rating.TraitDisplay)

-- The player attribute the headline star is published under, so the server write and the client read can't drift
Rating.OVERALL_ATTRIBUTE = "Rating"

-- What each trait contributes to the headline. Cooking and Satisfaction lead because they're the two money can't buy
Rating.TRAIT_WEIGHTS = {
	Cooking = 0.35,
	Satisfaction = 0.3,
	Menu = 0.2,
	Kitchen = 0.15,
}

table.freeze(Rating.TRAIT_WEIGHTS)

-- Stars the headline may sit above the weaker of Cooking and Satisfaction, so Kitchen can't buy a reputation
Rating.SKILL_CAP_HEADROOM = 1

-- What a BBQ in each state is worth, 0-1. Authored, not off CookStates.Multiplier, where Raw (1) outranks Charred (0.98)
Rating.CookStateScores = {
	Perfect = 1,
	Cooked = 0.7,
	Overcooked = 0.35,
	Raw = 0.1,
	Charred = 0.05,
}

table.freeze(Rating.CookStateScores)

-- Reliability leads: finishing what you took on matters more than how fast, and refusals only ever subtract
Rating.SATISFACTION_WEIGHTS = {
	Reliability = 0.5,
	Promptness = 0.2,
	Refusals = 0.3,
}

table.freeze(Rating.SATISFACTION_WEIGHTS)

-- Variety leads, since serving one ingredient forever is the thing this trait exists to catch
Rating.MENU_WEIGHTS = {
	Variety = 0.4,
	Tier = 0.35,
	Fullness = 0.25,
}

table.freeze(Rating.MENU_WEIGHTS)

-- Grill quality leads, because it's the rung the whole cooking game is played on
Rating.KITCHEN_WEIGHTS = {
	GrillQuality = 0.3,
	GrillCount = 0.2,
	RollingStands = 0.2,
	RollSpeed = 0.15,
	Plots = 0.15,
}

table.freeze(Rating.KITCHEN_WEIGHTS)

-- Distinct ingredients across the window that reads as a full menu
Rating.VARIETY_TARGET = 12

-- The mean Tiers index that reads as full marks. Rare, not the top: variety and rarity pull against each other
Rating.TIER_TARGET = 3

-- Grillers placed that reads as a full kitchen; past this the count stops paying
Rating.GRILL_COUNT_TARGET = 4

-- The folder grillers are authored under, matching the category their models live in
local GRILLER_CATEGORY = "Grillers"

-- Warns on a weight table that doesn't add up, naming what it costs and what to change.
local function validateWeights(label: string, weights: { [string]: number })
	local total = 0
	for _, weight in weights do
		total += weight
	end

	if math.abs(total - 1) <= Rating.WEIGHT_SUM_TOLERANCE then
		return
	end

	-- Rounded, since summing decimals lands on 99.99999% often enough to make the message look like the bug
	local percent = math.round(total * 1000) / 10
	local direction = if total > 1 then "harsher" else "softer"
	local fix = if total > 1 then "lower" else "raise"

	warn(
		`Rating.{label} adds up to {percent}% instead of 100%, so every star it feeds reads {direction} `
			.. `than authored -- {fix} some of its weights to bring them back`
	)
end

validateWeights("TRAIT_WEIGHTS", Rating.TRAIT_WEIGHTS)
validateWeights("SATISFACTION_WEIGHTS", Rating.SATISFACTION_WEIGHTS)
validateWeights("MENU_WEIGHTS", Rating.MENU_WEIGHTS)
validateWeights("KITCHEN_WEIGHTS", Rating.KITCHEN_WEIGHTS)

-- [grillerId] = its rung, off config order (cheapest first). Position is safe here and not in saved data, being re-derived every read
local GRILLER_RUNGS = {}
local GRILLER_RUNG_COUNT = 0

for _, structure in Structures.Data do
	if structure.Category == GRILLER_CATEGORY then
		GRILLER_RUNG_COUNT += 1
		GRILLER_RUNGS[structure.Id] = GRILLER_RUNG_COUNT
	end
end

table.freeze(GRILLER_RUNGS)

-- An unlock's top level, so a trait normalises against the ladder rather than a number written twice.
local function getUnlockLimit(unlockId: string): number
	local unlock = BaseUnlocks.GetUnlockFromId(unlockId)
	return if unlock then unlock.Limit else 1
end

-- A level's share of its ladder. Level 1 is owned from the start, so it's the floor rather than a fraction.
local function scoreUnlockLevel(level: number?, limit: number): number
	if limit <= 1 then
		return 1
	end

	return math.clamp(((level or 1) - 1) / (limit - 1), 0, 1)
end

-- How well the player cooks, over the sale window. Nil until the window holds enough to be worth reading.
function Rating.ScoreCooking(recentSales: { any }): number?
	local total, rated = 0, 0

	for _, sale in recentSales do
		-- Skipped rather than scored zero, so retiring a cook state can't tank every rating that saw one
		local score = Rating.CookStateScores[sale.CookState]
		if score then
			total += score
			rated += 1
		end
	end

	if rated < Rating.MIN_SALE_SAMPLE then
		return nil
	end

	return total / rated
end

-- How well the player treats customers: orders finished, how promptly, less what they turned away.
function Rating.ScoreSatisfaction(orderHistory: { any }, standingRefusals: number): number?
	if #orderHistory < Rating.MIN_ORDER_SAMPLE then
		return nil
	end

	local delivered = 0
	local promptTotal, promptCount = 0, 0

	for _, entry in orderHistory do
		if entry.Outcome ~= "Delivered" then
			continue
		end

		delivered += 1

		-- Zero on an order that never got a clock, which is what tells a lapse from a hand-over on the buzzer
		if entry.Seconds and entry.Seconds > 0 then
			promptTotal += math.clamp((entry.SecondsLeft or 0) / entry.Seconds, 0, 1)
			promptCount += 1
		end
	end

	local reliability = delivered / #orderHistory
	local promptness = if promptCount > 0 then promptTotal / promptCount else 0
	local refusals = 1 - math.clamp(standingRefusals / SellNpc.REFUSAL_PENALTY_MAX, 0, 1)

	local weights = Rating.SATISFACTION_WEIGHTS
	return reliability * weights.Reliability + promptness * weights.Promptness + refusals * weights.Refusals
end

-- How interesting the menu is: how many different ingredients, how dear, and how full the skewers go out.
function Rating.ScoreMenu(recentSales: { any }): number?
	local distinctCount, distinct = 0, {}
	local tierTotal, tierCount = 0, 0
	local fullnessTotal, fullnessCount = 0, 0
	local rated = 0

	for _, sale in recentSales do
		-- Absent on entries written before this trait existed, and they can't be backfilled -- so they're skipped
		if not sale.Ingredients then
			continue
		end

		rated += 1

		for _, ingredientId in sale.Ingredients do
			if not distinct[ingredientId] then
				distinct[ingredientId] = true
				distinctCount += 1
			end

			local ingredient = Ingredients.GetIngredientFromId(ingredientId)
			if ingredient then
				tierTotal += ingredient.Tier.Index
				tierCount += 1
			end
		end

		local stick = Sticks.GetStickFromId(sale.StickId)
		if stick then
			fullnessTotal += math.clamp(#sale.Ingredients / stick.Capacity, 0, 1)
			fullnessCount += 1
		end
	end

	if rated < Rating.MIN_SALE_SAMPLE then
		return nil
	end

	local variety = math.clamp(distinctCount / Rating.VARIETY_TARGET, 0, 1)

	-- Measured up from the commonest tier, so a Common-only menu scores the floor rather than a fraction of one
	local meanTier = if tierCount > 0 then tierTotal / tierCount else 1
	local tier = math.clamp((meanTier - 1) / math.max(Rating.TIER_TARGET - 1, 1), 0, 1)

	local fullness = if fullnessCount > 0 then fullnessTotal / fullnessCount else 0

	local weights = Rating.MENU_WEIGHTS
	return variety * weights.Variety + tier * weights.Tier + fullness * weights.Fullness
end

-- How good the setup is, read off the build rather than a window -- so it never withholds, even on a fresh base.
function Rating.ScoreKitchen(data, grillCount: number): number
	local bestRung = 0
	for _, placed in data.Structures do
		bestRung = math.max(bestRung, GRILLER_RUNGS[placed.Type] or 0)
	end

	local grillQuality = if GRILLER_RUNG_COUNT > 0 then bestRung / GRILLER_RUNG_COUNT else 0
	local grillCountScore = math.clamp(grillCount / Rating.GRILL_COUNT_TARGET, 0, 1)

	local rollingStands = scoreUnlockLevel(data.Unlocks.RollingStands, getUnlockLimit("RollingStands"))
	local rollSpeed = scoreUnlockLevel(data.Unlocks.RollSpeed, getUnlockLimit("RollSpeed"))
	local plots = math.clamp(Plots.GetUnlockedCount(data.Plots) / #Plots.Costs, 0, 1)

	local weights = Rating.KITCHEN_WEIGHTS
	return grillQuality * weights.GrillQuality
		+ grillCountScore * weights.GrillCount
		+ rollingStands * weights.RollingStands
		+ rollSpeed * weights.RollSpeed
		+ plots * weights.Plots
end

-- The headline, over whichever traits are rated. Held under the skill cap, so upgrades can't outrun the cooking.
function Rating.CombineTraits(traits: { [string]: number? }): number
	local total, weightSum = 0, 0

	for traitId, weight in Rating.TRAIT_WEIGHTS do
		local score = traits[traitId]
		if score then
			total += score * weight
			weightSum += weight
		end
	end

	-- Renormalised over what's rated, or a trait still filling would drag the headline down while it waits
	local combined = if weightSum > 0 then total / weightSum else 0

	-- An unrated skill trait doesn't cap anything -- there's nothing yet to say the upgrades ran ahead of it
	local skill = math.min(traits.Cooking or 1, traits.Satisfaction or 1)

	return math.min(combined, skill + Rating.SKILL_CAP_HEADROOM / Rating.MAX_STARS)
end

-- A 0-1 score as stars. Nil in, nil out, so an unrated trait stays unrated.
function Rating.ToStars(score: number?): number?
	if not score then
		return nil
	end

	return MathUtil.RoundUpTo2Dec(math.clamp(score, 0, 1) * Rating.MAX_STARS)
end

-- One star's gradient offset, -0.5 empty to 0.5 full, so a fraction lands part-way through its own star.
function Rating.GetStarOffset(stars: number?, index: number): number
	return MathUtil.RoundUpTo2Dec(math.clamp((stars or 0) - (index - 1), 0, 1) - 0.5)
end

-- Fills a star row: a frame whose children are named "1" upward, each holding a UIGradient. Only the X offset is ours, so a gradient inset in the place file stays inset.
function Rating.DrawStars(starsFrame: Frame, stars: number?)
	for index = 1, Rating.MAX_STARS do
		local gradient = starsFrame[tostring(index)].UIGradient
		gradient.Offset = Vector2.new(Rating.GetStarOffset(stars, index), gradient.Offset.Y)
	end
end

-- A star rating as a number reads, e.g. "1.05". Trailing zeros stay, or the number changes width as it moves.
function Rating.FormatStars(stars: number?): string
	if not stars then
		return Rating.PENDING_TEXT
	end

	return string.format(`%.{Rating.TITLE_DECIMALS}f`, stars)
end

-- A rating as a panel title reads it, e.g. "Menu (3.58)".
function Rating.FormatTitle(name: string, stars: number?): string
	return `{name} ({Rating.FormatStars(stars)})`
end

-- The player attribute one trait's stars are published under, built here so the write and the read can't drift.
function Rating.GetTraitAttribute(traitId: string): string
	return `{Rating.OVERALL_ATTRIBUTE}_{traitId}`
end

return Rating
