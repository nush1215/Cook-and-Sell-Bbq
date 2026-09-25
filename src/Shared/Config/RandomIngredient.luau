-- The Random Ingredient offer: one roll off the pool below per purchase, the first each day on a discounted product. Chances must sum to 100% -- Roblox requires the shown odds to be the real ones.

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)

--
export type Entry = {
	Id: string, -- an Ingredients id
	Chance: number, -- percent of rolls that land on it; the pool's chances sum to 100
}

--
local RandomIngredient = {}

RandomIngredient.Id = "RandomIngredient" -- also its Products.luau id, and the key its daily discount is stamped under
RandomIngredient.FirstOfDayId = "FirstRandomIngredientOfTheDay" -- the discounted twin's Products.luau id
RandomIngredient.Name = "Random Ingredient"

RandomIngredient.RobuxProductId = 3714525411
RandomIngredient.FirstOfDayRobuxProductId = 3714525471

-- How far the chances may sum off 100% before the load-time warn fires, in percentage points
RandomIngredient.CHANCE_SUM_TOLERANCE = 0.5

-- The reveal a purchase plays for everyone nearby: a silhouette crashes in front of the buyer, rolls, then flies into them.

-- Where it lands and falls in from. It enters beyond the landing and off to the buyer's right, so it streaks diagonally across their view -- straight down their sightline reads as a vertical drop
RandomIngredient.REVEAL_DISTANCE = 10 -- studs in front of the buyer
RandomIngredient.REVEAL_ENTRY_HEIGHT = 100
RandomIngredient.REVEAL_ENTRY_BACK = 60 -- studs beyond the landing, away from the buyer
RandomIngredient.REVEAL_ENTRY_SIDE = 80 -- studs off to the buyer's right; about 45 degrees off vertical with the two above
RandomIngredient.REVEAL_FALL_DURATION = 1.5

-- The impact: lighter than the tutorial crate's, since this one can land anywhere and often
RandomIngredient.REVEAL_EXPLOSION_ROCKS = 10
RandomIngredient.REVEAL_EXPLOSION_MIN_SIZE = 0.75
RandomIngredient.REVEAL_EXPLOSION_MAX_SIZE = 1.75
RandomIngredient.REVEAL_CRATER_RADIUS = 4
RandomIngredient.REVEAL_CRATER_MIN_ROCKS = 8
RandomIngredient.REVEAL_CRATER_MAX_ROCKS = 12
RandomIngredient.REVEAL_SHAKE = { Magnitude = 3, Roughness = 8, FadeIn = 0.1, FadeOut = 0.4 } -- the buyer's only

-- The roll, played the stand's way off Config.Rolling and stretched to REVEAL_ROLL_DURATION
RandomIngredient.REVEAL_IMPACT_PAUSE = 0.4 -- the beat on the ground before it lifts into the roll
RandomIngredient.REVEAL_ROLL_DURATION = 3
RandomIngredient.REVEAL_HOVER_HEIGHT = 5 -- studs above the ground the roll's centre sits at; keep it past half of DISPLAY_SIZE
RandomIngredient.REVEAL_DISPLAY_SIZE = 5 -- studs across; every ingredient scales to this, so a grape reads like a rib rack. Viewed from ~10 studs plus the camera's distance
RandomIngredient.REVEAL_ROLL_START_SCALE = 0.4 -- fraction of DISPLAY_SIZE the crash and the roll start at; the roll grows it to full, so the result swells in
RandomIngredient.REVEAL_HOLD_DURATION = 1.5 -- the result hovers with its name up before flying in

-- The near-miss: the step before the result is always a good ingredient other than it, lingering past its own wait
RandomIngredient.REVEAL_EDGE_HOLD = 0.6 -- extra seconds the tease lingers on top of its step's own wait

-- How often each tier is the bait. Only pool entries are ever shown, so a tier with none drops out and the rest split its share
RandomIngredient.REVEAL_EDGE_TIER_WEIGHTS = { Epic = 60, Legendary = 25, Mythic = 15 }

-- The discounted first buy of the day leans hard on the Mythic, so the cheap roll shows off what a full-price one can land
RandomIngredient.REVEAL_EDGE_TIER_WEIGHTS_FIRST_OF_DAY = { Epic = 15, Legendary = 10, Mythic = 75 }

-- Bystanders further than this from the landing skip the show; the buyer always plays it
RandomIngredient.REVEAL_VIEW_DISTANCE = 150

-- A second buy waits for the first to finish, plus this, which covers the first one's fly-in
RandomIngredient.REVEAL_QUEUE_GAP = 1

-- Slack on the server's claim gate, sized past a bad ping, and how long past the reveal it hands over unclaimed
RandomIngredient.CLAIM_GRACE = 0.5
RandomIngredient.CLAIM_FALLBACK_DELAY = 5

-- Commonest first. No entry beats one a tier below it, so the odds panel reads as a clean ladder. Commons are the dearest few, so the floor isn't a Corn
RandomIngredient.Pool = {
	-- Common, 55%
	{ Id = "Mushroom", Chance = 13 },
	{ Id = "Broccoli", Chance = 12 },
	{ Id = "Chicken", Chance = 11 },
	{ Id = "Cauliflower", Chance = 10 },
	{ Id = "Eggplant", Chance = 9 },

	-- Uncommon, 35%
	{ Id = "Pineapple", Chance = 5 },
	{ Id = "Pork", Chance = 4.5 },
	{ Id = "Egg", Chance = 4.5 },
	{ Id = "Hotdog", Chance = 4 },
	{ Id = "Banana", Chance = 3.5 },
	{ Id = "Lemon", Chance = 3.5 },
	{ Id = "Peach", Chance = 3 },
	{ Id = "Strawberry", Chance = 2.5 },
	{ Id = "Grape", Chance = 2.5 },
	{ Id = "Kiwi", Chance = 2 },

	-- Rare, 8%
	{ Id = "Mango", Chance = 2 },
	{ Id = "Turkey", Chance = 1.75 },
	{ Id = "Beef", Chance = 1.75 },
	{ Id = "Bacon", Chance = 1.5 },
	{ Id = "Shrimp", Chance = 1 },

	-- Epic, 1.99%: each under 1%, so a hit is an event
	{ Id = "DragonFruit", Chance = 0.8 },
	{ Id = "Ribeye", Chance = 0.6 },
	{ Id = "CrocodileMeat", Chance = 0.4 },
	{ Id = "Salmon", Chance = 0.19 },

	-- Mythic, 0.01% (1 in 10,000): the one headline pull, there to be chased rather than landed
	{ Id = "Caviar", Chance = 0.01 },
}

-- An entry naming something the config doesn't have is dropped, so a typo can't be sold and then fail
for index = #RandomIngredient.Pool, 1, -1 do
	local entry = RandomIngredient.Pool[index]

	if not Ingredients.GetIngredientFromId(entry.Id) then
		warn(`Random Ingredient pool contains an ingredient the config doesn't have ({entry.Id}), it won't be rolled`)
		table.remove(RandomIngredient.Pool, index)
	end
end

local total = 0
for _, entry in RandomIngredient.Pool do
	total += entry.Chance
end

if math.abs(total - 100) > RandomIngredient.CHANCE_SUM_TOLERANCE then
	-- Rounded, since summing decimals lands on 99.99999 often enough to make the message look like the bug
	local percent = math.round(total * 10) / 10
	local direction = if total > 100 then "rarer" else "commoner"
	local fix = if total > 100 then "lower" else "raise"

	warn(
		`Random Ingredient pool chances add up to {percent}% instead of 100%, so every one of them `
			.. `lands {math.abs(percent - 100)}% {direction} than shown -- {fix} some Chances to bring them back`
	)
end

table.freeze(RandomIngredient.Pool)

-- Seconds from a reveal's start to the claim, off the same constants the client plays on, so the gate and the show can't desync.
function RandomIngredient.GetRevealDuration(): number
	return RandomIngredient.REVEAL_FALL_DURATION
		+ RandomIngredient.REVEAL_IMPACT_PAUSE
		+ RandomIngredient.REVEAL_ROLL_DURATION
		+ RandomIngredient.REVEAL_EDGE_HOLD
		+ RandomIngredient.REVEAL_HOLD_DURATION
end

return RandomIngredient
