-- Every ingredient, and the tiers that price them. Chances must sum to 100% -- see docs/balance.md before editing.

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Assets
local Assets = ReplicatedStorage.Assets
local IngredientsFolder = Assets.Ingredients

-- Shared
local Shared = ReplicatedStorage.Shared
local Colors = require(Shared.Colors)

--
export type Tier = {
	Id: string, -- also the key into Shared.Colors this tier takes its label colour from
	Price: number, -- the anchor an entry costs off a stand when it names no Price of its own
	CookTime: number, -- seconds one of them takes to cook on a griller (see GetTotalCookTime)
	ValueMultiplier: number, -- what it sells for per dollar it cost, on top of SALE_VALUE_MULTIPLIER
	TextColor: Color3, -- not authored below, back-filled from Shared.Colors
	StrokeColor: Color3, -- the label's stroke, likewise back-filled
	Index: number, -- position on the ladder, back-filled; the commonest tier is 1
	PityThreshold: number?, -- rolls without this tier or better before one is forced; nil leaves it untracked
	PityWeights: { { any } }?, -- back-filled { id, Weight } for this tier's own entries, what a forced roll draws from
}

export type Ingredient = {
	Id: string, -- also the name of the model under Assets.Ingredients.Raw / .Cooked
	Name: string,
	Tier: Tier, -- authored as a tier id (a string) below, back-filled to the tier itself
	Chance: number, -- the odds on its label, 1 in this many rolls; corrected at load to the real odds
	Color: Color3, -- label colour, to tell ingredients apart in the stick UI
	Icon: string, -- rbxassetid for this ingredient's UI icon
	Price: number, -- authored per entry below; falls back to its tier's price when it isn't
	CookTime: number, -- not authored below unless it's overriding its tier's cook time
	Weight: number, -- derived from Chance: how heavily the roller draws this one
	Model: Model, -- raw model, back-filled from Assets.Ingredients.Raw
	CookedModel: Model, -- cooked model, back-filled from Assets.Ingredients.Cooked
}

--
local Ingredients = {}

-- The global economy dial, on top of every tier's ValueMultiplier
Ingredients.SALE_VALUE_MULTIPLIER = 1.45

-- What each slot past the slowest adds, as a fraction of its own CookTime. Short of 1 so filling a stick pays
Ingredients.ADDITIONAL_SLOT_FACTOR = 0.75

-- How far off 100% the chances may sum before the load-time warn fires
Ingredients.CHANCE_SUM_TOLERANCE = 0.02

-- The Robux products an ingredient can be bought outright with, cheapest first. Keyed by band, not by entry
Ingredients.RobuxProductIds = {
	3709025916,
	3709025936,
	3709025973,
	3709025996,
	3709026012,
	3709026026,
	3709026042,
	3709026064,
	3709026098,
	3709026113,
}

-- ProductPriceBands[n] is the most Bux band n covers, so an entry places itself from its Price alone
Ingredients.ProductPriceBands = {
	100, -- T1: Corn - Jalapeno
	200, -- T2: Carrot - Chicken
	500, -- T3: Cauliflower, Eggplant
	1_000, -- T4: Pineapple
	2_500, -- T5: Pork - Banana
	6_000, -- T6: Melon - Kiwi
	15_000, -- T7: Asparagus - Turkey
	60_000, -- T8: Beef - Duck
	150_000, -- T9: Salmon, Lamb
	-- T10 is everything above, which is where Mythic's 400k anchor lands
}

table.freeze(Ingredients.RobuxProductIds)
table.freeze(Ingredients.ProductPriceBands)

-- Commonest first. Price and CookTime are anchors an entry fans around; see docs/balance.md for the ladder
Ingredients.Tiers = {
	{
		Id = "Common",
		Price = 100,
		CookTime = 10,
		ValueMultiplier = 1.3,
	},
	{
		Id = "Uncommon",
		Price = 3_000,
		CookTime = 24,
		ValueMultiplier = 1.1,
	},
	{
		Id = "Rare",
		Price = 18_000,
		CookTime = 40,
		ValueMultiplier = 1.07,
		PityThreshold = 65,
	},
	{
		Id = "Epic",
		Price = 65_000,
		CookTime = 60,
		ValueMultiplier = 1.05,
		PityThreshold = 350,
	},
	{
		Id = "Legendary",
		Price = 100_000,
		CookTime = 85,
		ValueMultiplier = 1,
		PityThreshold = 650,
	},
	{
		Id = "Mythic",
		Price = 400_000,
		CookTime = 110,
		ValueMultiplier = 1,
		-- A placeholder until Mythic has entries -- inert either way, since an empty tier gets no counter
		PityThreshold = 1_500,
	},
}

-- The same palette the sticks use, so a Rare ingredient and a Rare stick read the same colour
local tiersById = {}

for index, tier in Ingredients.Tiers do
	tier.TextColor = Colors[tier.Id].TextColor
	tier.StrokeColor = Colors[tier.Id].StrokeColor
	-- On the tier so a rarity comparison is a number against a number, which the pity reset does every roll
	tier.Index = index
	tiersById[tier.Id] = tier
end

table.freeze(Ingredients.Tiers)
table.freeze(tiersById)

-- Where the ladder starts being worth a fuss. A position, so a tier added above Rare is celebrated too
Ingredients.COOL_TIER_INDEX = tiersById.Rare.Index

-- Grouped by tier, commonest first; config order is the Index grid's layout order and nothing else
Ingredients.Data = {
	{
		Id = "Corn",
		Name = "Corn",
		Tier = "Common",
		Chance = 9,
		Price = 75,
		CookTime = 13,
		Color = Color3.fromRGB(255, 214, 71),
		Icon = "rbxassetid://138967242632937",
	},
	{
		Id = "Onion",
		Name = "Onion",
		Tier = "Common",
		Chance = 10,
		Price = 80,
		CookTime = 9,
		Color = Color3.fromRGB(216, 206, 224),
		Icon = "rbxassetid://98242838233542",
	},
	{
		Id = "Garlic",
		Name = "Garlic",
		Tier = "Common",
		Chance = 11,
		Price = 80,
		CookTime = 8,
		Color = Color3.fromRGB(235, 227, 209),
		Icon = "rbxassetid://116516365048951",
	},
	{
		Id = "Potato",
		Name = "Potato",
		Tier = "Common",
		Chance = 12,
		Price = 85,
		CookTime = 14,
		Color = Color3.fromRGB(205, 170, 118),
		Icon = "rbxassetid://117339991702527",
	},
	{
		Id = "RedBellPepper",
		Name = "Red Bell Pepper",
		Tier = "Common",
		Chance = 14,
		Price = 90,
		CookTime = 10,
		Color = Color3.fromRGB(206, 62, 53),
		Icon = "rbxassetid://77712961773231",
	},
	{
		Id = "YellowBellPepper",
		Name = "Yellow Bell Pepper",
		Tier = "Common",
		Chance = 15,
		Price = 90,
		CookTime = 10,
		Color = Color3.fromRGB(240, 196, 62),
		Icon = "rbxassetid://72467817521534",
	},
	{
		Id = "Jalapeno",
		Name = "Jalapeno",
		Tier = "Common",
		Chance = 17,
		Price = 95,
		CookTime = 9,
		Color = Color3.fromRGB(58, 138, 62),
		Icon = "rbxassetid://74090150295164",
	},
	{
		Id = "Carrot",
		Name = "Carrot",
		Tier = "Common",
		Chance = 19,
		Price = 105,
		CookTime = 14,
		Color = Color3.fromRGB(235, 122, 46),
		Icon = "rbxassetid://123200499909407",
	},
	{
		Id = "Tomato",
		Name = "Tomato",
		Tier = "Common",
		Chance = 21,
		Price = 110,
		CookTime = 8,
		Color = Color3.fromRGB(228, 65, 55),
		Icon = "rbxassetid://136870243322899",
	},
	{
		Id = "Zucchini",
		Name = "Zucchini",
		Tier = "Common",
		Chance = 25,
		Price = 115,
		CookTime = 9,
		Color = Color3.fromRGB(109, 166, 70),
		Icon = "rbxassetid://72438289618144",
	},
	{
		Id = "Mushroom",
		Name = "Mushroom",
		Tier = "Common",
		Chance = 28,
		Price = 140,
		CookTime = 9,
		Color = Color3.fromRGB(198, 170, 132),
		Icon = "rbxassetid://120620478711696",
	},
	{
		Id = "Broccoli",
		Name = "Broccoli",
		Tier = "Common",
		Chance = 32,
		Price = 150,
		CookTime = 11,
		Color = Color3.fromRGB(74, 140, 61),
		Icon = "rbxassetid://102620202132074",
	},
	{
		Id = "Chicken",
		Name = "Chicken",
		Tier = "Common",
		Chance = 38,
		Price = 180,
		CookTime = 13,
		Color = Color3.fromRGB(238, 208, 156),
		Icon = "rbxassetid://85763737510059",
	},
	{
		Id = "Cauliflower",
		Name = "Cauliflower",
		Tier = "Common",
		Chance = 44,
		Price = 210,
		CookTime = 12,
		Color = Color3.fromRGB(238, 232, 214),
		Icon = "rbxassetid://123187358827349",
	},
	{
		Id = "Eggplant",
		Name = "Eggplant",
		Tier = "Common",
		Chance = 51,
		Price = 260,
		CookTime = 11,
		Color = Color3.fromRGB(108, 62, 140),
		Icon = "rbxassetid://88534976012906",
	},

	{
		Id = "Pineapple",
		Name = "Pineapple",
		Tier = "Uncommon",
		Chance = 55,
		Price = 1_000,
		CookTime = 27,
		Color = Color3.fromRGB(245, 203, 54),
		Icon = "rbxassetid://104408088619027",
	},
	{
		Id = "Pork",
		Name = "Pork",
		Tier = "Uncommon",
		Chance = 61,
		Price = 1_300,
		CookTime = 30,
		Color = Color3.fromRGB(241, 157, 157),
		Icon = "rbxassetid://79245029595159",
	},
	{
		Id = "Apple",
		Name = "Apple",
		Tier = "Uncommon",
		Chance = 67,
		Price = 1_700,
		CookTime = 25,
		Color = Color3.fromRGB(214, 61, 58),
		Icon = "rbxassetid://120797045727521",
	},
	{
		Id = "Banana",
		Name = "Banana",
		Tier = "Uncommon",
		Chance = 75,
		Price = 2_200,
		CookTime = 22,
		Color = Color3.fromRGB(245, 219, 91),
		Icon = "rbxassetid://85163764338788",
	},
	{
		Id = "Melon",
		Name = "Melon",
		Tier = "Uncommon",
		Chance = 83,
		Price = 2_800,
		CookTime = 24,
		Color = Color3.fromRGB(243, 163, 96),
		Icon = "rbxassetid://71556666204567",
	},
	{
		Id = "Peach",
		Name = "Peach",
		Tier = "Uncommon",
		Chance = 91,
		Price = 3_400,
		CookTime = 23,
		Color = Color3.fromRGB(250, 176, 124),
		Icon = "rbxassetid://131315537607177",
	},
	{
		Id = "Strawberry",
		Name = "Strawberry",
		Tier = "Uncommon",
		Chance = 101,
		Price = 4_100,
		CookTime = 20,
		Color = Color3.fromRGB(240, 84, 110),
		Icon = "rbxassetid://76710810752276",
	},
	{
		Id = "Grape",
		Name = "Grape",
		Tier = "Uncommon",
		Chance = 112,
		Price = 5_000,
		CookTime = 20,
		Color = Color3.fromRGB(150, 92, 196),
		Icon = "rbxassetid://111929211427017",
	},
	{
		Id = "Kiwi",
		Name = "Kiwi",
		Tier = "Uncommon",
		Chance = 124,
		Price = 6_000,
		CookTime = 21,
		Color = Color3.fromRGB(143, 191, 74),
		Icon = "rbxassetid://127403783130431",
	},
	{
		Id = "Asparagus",
		Name = "Asparagus",
		Tier = "Uncommon",
		Chance = 137,
		Price = 7_000,
		CookTime = 23,
		Color = Color3.fromRGB(106, 158, 84),
		Icon = "rbxassetid://101470358908580",
	},

	{
		Id = "Mango",
		Name = "Mango",
		Tier = "Rare",
		Chance = 170,
		Price = 10_500,
		CookTime = 40,
		Color = Color3.fromRGB(247, 168, 51),
		Icon = "rbxassetid://82309715085228",
	},
	{
		Id = "Turkey",
		Name = "Turkey",
		Tier = "Rare",
		Chance = 220,
		Price = 14_000,
		CookTime = 46,
		Color = Color3.fromRGB(214, 168, 110),
		Icon = "rbxassetid://135131325322026",
	},
	{
		Id = "Beef",
		Name = "Beef",
		Tier = "Rare",
		Chance = 280,
		Price = 18_000,
		CookTime = 50,
		Color = Color3.fromRGB(156, 66, 53),
		Icon = "rbxassetid://95071209025169",
	},
	{
		Id = "Bacon",
		Name = "Bacon",
		Tier = "Rare",
		Chance = 350,
		Price = 23_000,
		CookTime = 55,
		Color = Color3.fromRGB(206, 92, 84),
		Icon = "rbxassetid://122800616171926",
	},
	{
		Id = "Shrimp",
		Name = "Shrimp",
		Tier = "Rare",
		Chance = 450,
		Price = 30_000,
		CookTime = 60,
		Color = Color3.fromRGB(255, 133, 112),
		Icon = "rbxassetid://83047236472578",
	},

	{
		Id = "Duck",
		Name = "Duck",
		Tier = "Epic",
		Chance = 700,
		Price = 50_000,
		CookTime = 66,
		Color = Color3.fromRGB(150, 88, 66),
		-- TODO: real icon -- a blank one on an undiscovered Index cell looks like the locked state, so it hides
		Icon = "rbxassetid://0",
	},
	{
		Id = "Salmon",
		Name = "Salmon",
		Tier = "Epic",
		Chance = 1_200,
		Price = 85_000,
		CookTime = 90,
		Color = Color3.fromRGB(250, 142, 110),
		Icon = "rbxassetid://115449184910204",
	},

	{
		Id = "Lamb",
		Name = "Lamb",
		Tier = "Legendary",
		Chance = 2_200,
		CookTime = 120,
		Color = Color3.fromRGB(176, 96, 88),
		Icon = "rbxassetid://84226839644571",
	},
}

-- Resolves each entry's tier and models, dropping any that are incomplete before anything is weighted.
local RawFolder = IngredientsFolder.Raw
local CookedFolder = IngredientsFolder.Cooked

for index = #Ingredients.Data, 1, -1 do
	local ingredient = Ingredients.Data[index]
	local tier = tiersById[ingredient.Tier]
	local model = RawFolder:FindFirstChild(ingredient.Id)
	local cookedModel = CookedFolder:FindFirstChild(ingredient.Id)

	if not tier then
		warn(`Ingredient {ingredient.Id} names a tier ({ingredient.Tier}) that doesn't exist, it won't be rolled`)
		table.remove(Ingredients.Data, index)
		continue
	end

	if not ingredient.Chance then
		warn(`Ingredient {ingredient.Id} has no Chance, it won't be rolled`)
		table.remove(Ingredients.Data, index)
		continue
	end

	if not (model and cookedModel) then
		warn(`Ingredient {ingredient.Id} is missing a Raw or Cooked model in Assets.Ingredients, it won't be rolled`)
		table.remove(Ingredients.Data, index)
		continue
	end

	ingredient.Tier = tier
	ingredient.Model = model
	ingredient.CookedModel = cookedModel
end

-- Everything unauthored comes off the tier; weight is the reciprocal of the odds it asked for.
local totalWeight = 0

for _, ingredient in Ingredients.Data do
	local tier = ingredient.Tier

	ingredient.Price = ingredient.Price or tier.Price
	ingredient.CookTime = ingredient.CookTime or tier.CookTime
	ingredient.Weight = 1 / ingredient.Chance

	totalWeight += ingredient.Weight
end

-- Chance is corrected in place to the real odds, then warned about if the config doesn't add up.
for _, ingredient in Ingredients.Data do
	ingredient.Chance *= totalWeight
end

if math.abs(totalWeight - 1) > Ingredients.CHANCE_SUM_TOLERANCE then
	local percent = math.round(totalWeight * 100)
	local direction = if totalWeight > 1 then "rarer" else "commoner"
	local fix = if totalWeight > 1 then "raise" else "lower"

	warn(
		`Ingredient chances add up to {percent}% instead of 100%, so every label reads {math.abs(percent - 100)}% {direction} than authored -- {fix} some Chances to bring them back`
	)
end

-- Pity: gathers each tier's own entries for a forced roll, walked rarest first. See docs/balance.md.
local pityTiers = {}

for index = #Ingredients.Tiers, 1, -1 do
	local tier = Ingredients.Tiers[index]
	local ownWeights = {}

	for _, ingredient in Ingredients.Data do
		if ingredient.Tier == tier then
			table.insert(ownWeights, { ingredient.Id, ingredient.Weight })
		end
	end

	-- A tier with no entries has nothing to force, so it stays untracked until it has some
	if not tier.PityThreshold or #ownWeights == 0 then
		continue
	end

	-- Fine despite the freeze above, which is shallow -- freezing a tier itself would break this
	tier.PityWeights = table.freeze(ownWeights)
	table.insert(pityTiers, tier)
end

-- Chance is deliberately not scaled for pity, so real rates run ahead of the labels -- see docs/balance.md.

-- Rarest first, so two counters due on the same roll pay out the better one
Ingredients.PITY_TIERS = table.freeze(pityTiers)

-- Warns if a rarer tier's threshold would have it arriving more often than the commoner one above it.
local previousTier

for index = #pityTiers, 1, -1 do
	local tier = pityTiers[index]

	if previousTier and tier.PityThreshold <= previousTier.PityThreshold then
		warn(
			`Ingredient tier {tier.Id} pities at {tier.PityThreshold} rolls, no longer than {previousTier.Id} at {previousTier.PityThreshold} -- the rarer tier would be guaranteed at least as often as the commoner one. Raise {tier.Id}'s PityThreshold past {previousTier.PityThreshold}`
		)
	end

	previousTier = tier
end

-- Warns on a tier overlapping the one below it on Chance or Price, which both read as bugs in-game.
local previousTierId, previousHighestChance, previousHighestPrice

for _, tier in Ingredients.Tiers do
	local lowestChance, highestChance
	local lowestPrice, highestPrice

	for _, ingredient in Ingredients.Data do
		if ingredient.Tier == tier then
			lowestChance = math.min(lowestChance or ingredient.Chance, ingredient.Chance)
			highestChance = math.max(highestChance or ingredient.Chance, ingredient.Chance)
			lowestPrice = math.min(lowestPrice or ingredient.Price, ingredient.Price)
			highestPrice = math.max(highestPrice or ingredient.Price, ingredient.Price)
		end
	end

	-- An empty tier is skipped, so the tier below stays what the next populated one is measured against
	if lowestChance then
		if previousHighestChance and lowestChance <= previousHighestChance then
			warn(`Ingredient tier {tier.Id} rolls as often as {previousTierId}, check their Chances`)
		end

		if previousHighestPrice and lowestPrice <= previousHighestPrice then
			warn(`Ingredient tier {tier.Id} costs no more than {previousTierId}, check their Prices`)
		end

		previousTierId = tier.Id
		previousHighestChance, previousHighestPrice = highestChance, highestPrice
	end
end

table.freeze(Ingredients.Data)

-- [id] = ingredient, built once: GetTotalValue runs per customer offer, so a scan would cost the roster
local ingredientsById = {}

for _, ingredient in Ingredients.Data do
	ingredientsById[ingredient.Id] = ingredient
end

table.freeze(ingredientsById)

function Ingredients.GetIngredientFromId(id: string): Ingredient?
	return ingredientsById[id]
end

function Ingredients.GetTierFromId(id: string): Tier?
	return tiersById[id]
end

function Ingredients.GetAllIngredients(): { Ingredient }
	return Ingredients.Data
end

-- The band something costing this many Bux sells in. Ceilings, cheapest first; past the last takes the top.
function Ingredients.GetProductTier(price: number): number
	for tier, ceiling in Ingredients.ProductPriceBands do
		if price <= ceiling then
			return tier
		end
	end

	return #Ingredients.RobuxProductIds
end

-- The Products.luau id for a Robux price band, built in one place so the config and the prompt can't drift.
function Ingredients.GetProductStringId(tier: number): string
	return `Ingredient_T{tier}`
end

-- The product that buys an ingredient at this price outright, banded so a new one needs no id of its own.
function Ingredients.GetProductStringIdForPrice(price: number): string
	return Ingredients.GetProductStringId(Ingredients.GetProductTier(price))
end

-- The dearest ingredient a band sells, for a receipt that found nothing to spend itself on. Nil if empty.
function Ingredients.GetDearestIngredientInProductTier(tier: number): Ingredient?
	local dearest = nil

	for _, ingredient in Ingredients.Data do
		if Ingredients.GetProductTier(ingredient.Price) == tier then
			if not dearest or ingredient.Price > dearest.Price then
				dearest = ingredient
			end
		end
	end

	return dearest
end

-- Total cook seconds for `ids`: the slowest pays full CookTime, every other slot ADDITIONAL_SLOT_FACTOR of its own.
function Ingredients.GetTotalCookTime(ids: { string }): number
	local total = 0
	local longest = 0

	for _, id in ids do
		local ingredient = Ingredients.GetIngredientFromId(id)
		if not ingredient then
			continue
		end

		total += ingredient.CookTime * Ingredients.ADDITIONAL_SLOT_FACTOR
		longest = math.max(longest, ingredient.CookTime)
	end

	return total + longest * (1 - Ingredients.ADDITIONAL_SLOT_FACTOR)
end

-- Sell value for `ids` before haggling. Every copy pays full, scaled by its tier -- no falloff, unlike cook time.
function Ingredients.GetTotalValue(ids: { string }): number
	local total = 0

	for _, id in ids do
		local ingredient = Ingredients.GetIngredientFromId(id)
		if ingredient then
			total += ingredient.Price * ingredient.Tier.ValueMultiplier * Ingredients.SALE_VALUE_MULTIPLIER
		end
	end

	return total
end

return Ingredients
