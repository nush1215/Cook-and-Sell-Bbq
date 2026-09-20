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
Ingredients.SALE_VALUE_MULTIPLIER = 1

-- What each slot past the slowest adds, as a fraction of its own CookTime. Short of 1 so filling a stick pays
Ingredients.ADDITIONAL_SLOT_FACTOR = 0.95

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
	100, -- T1: Corn - Lettuce
	200, -- T2: Carrot - Chicken
	500, -- T3: Cauliflower - Eggplant
	1_000, -- T4: Pineapple
	2_500, -- T5: ChickenFeet - Lemon
	6_000, -- T6: Orange - Kiwi
	15_000, -- T7: Asparagus - Turkey
	60_000, -- T8: Pumpkin - Durian
	150_000, -- T9: DragonFruit - GoatLeg
	-- T10 is everything above, which is where Mythic sits: MangoCaviar - Caviar
}

table.freeze(Ingredients.RobuxProductIds)
table.freeze(Ingredients.ProductPriceBands)

-- Commonest first. Price and CookTime are anchors an entry fans around; see docs/balance.md for the ladder
Ingredients.Tiers = {
	{
		Id = "Common",
		Price = 100,
		CookTime = 13,
		ValueMultiplier = 1.5,
	},
	{
		Id = "Uncommon",
		Price = 3_000,
		CookTime = 40,
		ValueMultiplier = 1.25,
	},
	{
		Id = "Rare",
		Price = 18_000,
		CookTime = 82,
		ValueMultiplier = 1.2,
		PityThreshold = 65,
	},
	{
		Id = "Epic",
		Price = 65_000,
		CookTime = 150,
		ValueMultiplier = 1.2,
		PityThreshold = 350,
	},
	{
		Id = "Legendary",
		Price = 100_000,
		CookTime = 225,
		ValueMultiplier = 1.2,
		PityThreshold = 650,
	},
	{
		Id = "Mythic",
		Price = 400_000,
		CookTime = 300,
		ValueMultiplier = 1.18,
		-- The steepest lean on pity: against a 1-in-10,000 band, the counter is what delivers a Mythic
		PityThreshold = 3_000,
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
		Chance = 10,
		Price = 75,
		CookTime = 8,
		Color = Color3.fromRGB(255, 214, 71),
		Icon = "rbxassetid://138967242632937",
	},
	{
		Id = "Onion",
		Name = "Onion",
		Tier = "Common",
		Chance = 12,
		Price = 80,
		CookTime = 10,
		Color = Color3.fromRGB(216, 206, 224),
		Icon = "rbxassetid://98242838233542",
	},
	{
		Id = "YellowOnion",
		Name = "Yellow Onion",
		Tier = "Common",
		Chance = 13,
		Price = 80,
		CookTime = 10,
		Color = Color3.fromRGB(226, 183, 92),
		Icon = "rbxassetid://82825005117464",
	},
	{
		Id = "Garlic",
		Name = "Garlic",
		Tier = "Common",
		Chance = 14,
		Price = 80,
		CookTime = 11,
		Color = Color3.fromRGB(235, 227, 209),
		Icon = "rbxassetid://116516365048951",
	},
	{
		Id = "Potato",
		Name = "Potato",
		Tier = "Common",
		Chance = 16,
		Price = 85,
		CookTime = 12,
		Color = Color3.fromRGB(205, 170, 118),
		Icon = "rbxassetid://117339991702527",
	},
	{
		Id = "RedBellPepper",
		Name = "Red Bell Pepper",
		Tier = "Common",
		Chance = 17,
		Price = 90,
		CookTime = 11,
		Color = Color3.fromRGB(206, 62, 53),
		Icon = "rbxassetid://77712961773231",
	},
	{
		Id = "YellowBellPepper",
		Name = "Yellow Bell Pepper",
		Tier = "Common",
		Chance = 18,
		Price = 90,
		CookTime = 12,
		Color = Color3.fromRGB(240, 196, 62),
		Icon = "rbxassetid://72467817521534",
	},
	{
		Id = "Jalapeno",
		Name = "Jalapeno",
		Tier = "Common",
		Chance = 20,
		Price = 95,
		CookTime = 13,
		Color = Color3.fromRGB(58, 138, 62),
		Icon = "rbxassetid://74090150295164",
	},
	{
		Id = "Lettuce",
		Name = "Lettuce",
		Tier = "Common",
		Chance = 24,
		Price = 100,
		CookTime = 8,
		Color = Color3.fromRGB(130, 200, 90),

		Icon = "rbxassetid://83916454398538",
	},
	{
		Id = "Carrot",
		Name = "Carrot",
		Tier = "Common",
		Chance = 26,
		Price = 105,
		CookTime = 14,
		Color = Color3.fromRGB(235, 122, 46),
		Icon = "rbxassetid://123200499909407",
	},
	{
		Id = "Tomato",
		Name = "Tomato",
		Tier = "Common",
		Chance = 30,
		Price = 110,
		CookTime = 14,
		Color = Color3.fromRGB(228, 65, 55),
		Icon = "rbxassetid://136870243322899",
	},
	{
		Id = "Zucchini",
		Name = "Zucchini",
		Tier = "Common",
		Chance = 33,
		Price = 115,
		CookTime = 15,
		Color = Color3.fromRGB(109, 166, 70),
		Icon = "rbxassetid://72438289618144",
	},
	{
		Id = "Garbanzo",
		Name = "Garbanzo",
		Tier = "Common",
		Chance = 35,
		Price = 120,
		CookTime = 14,
		Color = Color3.fromRGB(222, 196, 138),
		Icon = "rbxassetid://73451543324298",
	},
	{
		Id = "Radish",
		Name = "Radish",
		Tier = "Common",
		Chance = 37,
		Price = 125,
		CookTime = 13,
		Color = Color3.fromRGB(220, 60, 90),
		Icon = "rbxassetid://79803961511295",
	},
	{
		Id = "Mushroom",
		Name = "Mushroom",
		Tier = "Common",
		Chance = 41,
		Price = 140,
		CookTime = 16,
		Color = Color3.fromRGB(198, 170, 132),
		Icon = "rbxassetid://120620478711696",
	},
	{
		Id = "Broccoli",
		Name = "Broccoli",
		Tier = "Common",
		Chance = 46,
		Price = 150,
		CookTime = 16,
		Color = Color3.fromRGB(74, 140, 61),
		Icon = "rbxassetid://102620202132074",
	},
	{
		Id = "Chicken",
		Name = "Chicken",
		Tier = "Common",
		Chance = 53,
		Price = 180,
		CookTime = 17,
		Color = Color3.fromRGB(238, 208, 156),
		Icon = "rbxassetid://85763737510059",
	},
	{
		Id = "Cauliflower",
		Name = "Cauliflower",
		Tier = "Common",
		Chance = 58,
		Price = 210,
		CookTime = 18,
		Color = Color3.fromRGB(238, 232, 214),
		Icon = "rbxassetid://123187358827349",
	},
	{
		Id = "Eggplant",
		Name = "Eggplant",
		Tier = "Common",
		Chance = 64,
		Price = 260,
		CookTime = 18,
		Color = Color3.fromRGB(108, 62, 140),
		Icon = "rbxassetid://88534976012906",
	},

	{
		Id = "Pineapple",
		Name = "Pineapple",
		Tier = "Uncommon",
		Chance = 122,
		Price = 1_000,
		CookTime = 25,
		Color = Color3.fromRGB(245, 203, 54),
		Icon = "rbxassetid://104408088619027",
	},
	{
		Id = "ChickenFeet",
		Name = "Chicken Feet",
		Tier = "Uncommon",
		Chance = 125,
		Price = 1_050,
		CookTime = 28,
		Color = Color3.fromRGB(242, 210, 202),
		Icon = "rbxassetid://74099031211556",
	},
	{
		Id = "Celery",
		Name = "Celery",
		Tier = "Uncommon",
		Chance = 131,
		Price = 1_100,
		CookTime = 30,
		Color = Color3.fromRGB(150, 200, 110),
		Icon = "rbxassetid://82147479985277",
	},
	{
		Id = "Cucumber",
		Name = "Cucumber",
		Tier = "Uncommon",
		Chance = 135,
		Price = 1_200,
		CookTime = 32,
		Color = Color3.fromRGB(70, 140, 70),
		Icon = "rbxassetid://140583916633483",
	},
	{
		Id = "Pork",
		Name = "Pork",
		Tier = "Uncommon",
		Chance = 140,
		Price = 1_300,
		CookTime = 34,
		Color = Color3.fromRGB(241, 157, 157),
		Icon = "rbxassetid://79245029595159",
	},
	{
		Id = "Egg",
		Name = "Egg",
		Tier = "Uncommon",
		Chance = 145,
		Price = 1_450,
		CookTime = 33,
		Color = Color3.fromRGB(245, 240, 225),
		Icon = "rbxassetid://137510661682422",
	},
	{
		Id = "Bread",
		Name = "Bread",
		Tier = "Uncommon",
		Chance = 150,
		Price = 1_550,
		CookTime = 30,
		Color = Color3.fromRGB(215, 160, 90),
		Icon = "rbxassetid://96806423786498",
	},
	{
		Id = "Apple",
		Name = "Apple",
		Tier = "Uncommon",
		Chance = 160,
		Price = 1_700,
		CookTime = 36,
		Color = Color3.fromRGB(214, 61, 58),
		Icon = "rbxassetid://120797045727521",
	},
	{
		Id = "Hotdog",
		Name = "Hotdog",
		Tier = "Uncommon",
		Chance = 165,
		Price = 1_950,
		CookTime = 37,
		Color = Color3.fromRGB(200, 100, 70),
		Icon = "rbxassetid://133700841064226",
	},
	{
		Id = "Banana",
		Name = "Banana",
		Tier = "Uncommon",
		Chance = 175,
		Price = 2_200,
		CookTime = 39,
		Color = Color3.fromRGB(245, 219, 91),
		Icon = "rbxassetid://85163764338788",
	},
	{
		Id = "Lemon",
		Name = "Lemon",
		Tier = "Uncommon",
		Chance = 180,
		Price = 2_500,
		CookTime = 32,
		Color = Color3.fromRGB(250, 230, 70),
		Icon = "rbxassetid://125303815096165",
	},
	{
		Id = "Orange",
		Name = "Orange",
		Tier = "Uncommon",
		Chance = 185,
		Price = 2_650,
		CookTime = 34,
		Color = Color3.fromRGB(250, 152, 36),
		Icon = "rbxassetid://129859197877374",
	},
	{
		Id = "Melon",
		Name = "Melon",
		Tier = "Uncommon",
		Chance = 190,
		Price = 2_800,
		CookTime = 41,
		Color = Color3.fromRGB(243, 163, 96),
		Icon = "rbxassetid://71556666204567",
	},
	{
		Id = "Squash",
		Name = "Squash",
		Tier = "Uncommon",
		Chance = 200,
		Price = 3_100,
		CookTime = 45,
		Color = Color3.fromRGB(235, 180, 60),
		Icon = "rbxassetid://117021596909761",
	},
	{
		Id = "Peach",
		Name = "Peach",
		Tier = "Uncommon",
		Chance = 210,
		Price = 3_400,
		CookTime = 44,
		Color = Color3.fromRGB(250, 176, 124),
		Icon = "rbxassetid://131315537607177",
	},
	{
		Id = "Pear",
		Name = "Pear",
		Tier = "Uncommon",
		Chance = 225,
		Price = 3_700,
		CookTime = 45,
		Color = Color3.fromRGB(190, 210, 90),
		Icon = "rbxassetid://104697816211879",
	},
	{
		Id = "Strawberry",
		Name = "Strawberry",
		Tier = "Uncommon",
		Chance = 235,
		Price = 4_100,
		CookTime = 46,
		Color = Color3.fromRGB(240, 84, 110),
		Icon = "rbxassetid://76710810752276",
	},
	{
		Id = "Okra",
		Name = "Okra",
		Tier = "Uncommon",
		Chance = 245,
		Price = 4_500,
		CookTime = 40,
		Color = Color3.fromRGB(100, 150, 70),
		Icon = "rbxassetid://89855304917458",
	},
	{
		Id = "Grape",
		Name = "Grape",
		Tier = "Uncommon",
		Chance = 255,
		Price = 5_000,
		CookTime = 50,
		Color = Color3.fromRGB(150, 92, 196),
		Icon = "rbxassetid://111929211427017",
	},
	{
		Id = "Kiwi",
		Name = "Kiwi",
		Tier = "Uncommon",
		Chance = 265,
		Price = 6_000,
		CookTime = 52,
		Color = Color3.fromRGB(143, 191, 74),
		Icon = "rbxassetid://127403783130431",
	},
	{
		Id = "Asparagus",
		Name = "Asparagus",
		Tier = "Uncommon",
		Chance = 285,
		Price = 7_000,
		CookTime = 55,
		Color = Color3.fromRGB(106, 158, 84),
		Icon = "rbxassetid://101470358908580",
	},

	{
		Id = "Mango",
		Name = "Mango",
		Tier = "Rare",
		Chance = 365,
		Price = 10_500,
		CookTime = 65,
		Color = Color3.fromRGB(247, 168, 51),
		Icon = "rbxassetid://82309715085228",
	},
	{
		Id = "SweetPotato",
		Name = "Sweet Potato",
		Tier = "Rare",
		Chance = 404,
		Price = 11_500,
		CookTime = 88,
		Color = Color3.fromRGB(210, 110, 60),
		Icon = "rbxassetid://94807931172686",
	},
	{
		Id = "Tofu",
		Name = "Tofu",
		Tier = "Rare",
		Chance = 460,
		Price = 12_500,
		CookTime = 75,
		Color = Color3.fromRGB(240, 235, 215),
		Icon = "rbxassetid://86515494024186",
	},
	{
		Id = "Turkey",
		Name = "Turkey",
		Tier = "Rare",
		Chance = 520,
		Price = 14_000,
		CookTime = 79,
		Color = Color3.fromRGB(214, 168, 110),
		Icon = "rbxassetid://135131325322026",
	},
	{
		Id = "Pumpkin",
		Name = "Pumpkin",
		Tier = "Rare",
		Chance = 580,
		Price = 15_500,
		CookTime = 96,
		Color = Color3.fromRGB(235, 130, 40),
		Icon = "rbxassetid://94474675831027",
	},
	{
		Id = "Sausage",
		Name = "Sausage",
		Tier = "Rare",
		Chance = 650,
		Price = 17_000,
		CookTime = 82,
		Color = Color3.fromRGB(170, 80, 60),
		Icon = "rbxassetid://92221898310572",
	},
	{
		Id = "Beef",
		Name = "Beef",
		Tier = "Rare",
		Chance = 730,
		Price = 18_000,
		CookTime = 86,
		Color = Color3.fromRGB(156, 66, 53),
		Icon = "rbxassetid://95071209025169",
	},
	{
		Id = "Watermelon",
		Name = "Watermelon",
		Tier = "Rare",
		Chance = 820,
		Price = 20_000,
		CookTime = 80,
		Color = Color3.fromRGB(230, 70, 80),
		Icon = "rbxassetid://88734586290289",
	},
	{
		Id = "Bacon",
		Name = "Bacon",
		Tier = "Rare",
		Chance = 925,
		Price = 23_000,
		CookTime = 93,
		Color = Color3.fromRGB(206, 92, 84),
		Icon = "rbxassetid://122800616171926",
	},
	{
		Id = "Sirloin",
		Name = "Sirloin",
		Tier = "Rare",
		Chance = 980,
		Price = 24_500,
		CookTime = 88,
		Color = Color3.fromRGB(176, 72, 66),
		Icon = "rbxassetid://116351005472689",
	},
	{
		Id = "Avocado",
		Name = "Avocado",
		Tier = "Rare",
		Chance = 1_025,
		Price = 26_000,
		CookTime = 90,
		Color = Color3.fromRGB(120, 160, 60),
		Icon = "rbxassetid://122595170030208",
	},
	{
		Id = "Shrimp",
		Name = "Shrimp",
		Tier = "Rare",
		Chance = 1_175,
		Price = 30_000,
		CookTime = 100,
		Color = Color3.fromRGB(255, 133, 112),
		Icon = "rbxassetid://83047236472578",
	},

	-- Duck is postponed until its assets land; restoring it means re-solving the chances around it
	--[==[
	{
		Id = "Duck",
		Name = "Duck",
		Tier = "Epic",
		Chance = 700,
		Price = 50_000,
		CookTime = 105,
		Color = Color3.fromRGB(150, 88, 66),
		Icon = "rbxassetid://0",
	},
	]==]
	{
		Id = "Cheese",
		Name = "Cheese",
		Tier = "Epic",
		Chance = 1_350,
		Price = 55_000,
		CookTime = 115,
		Color = Color3.fromRGB(250, 210, 90),
		Icon = "rbxassetid://117930188363989",
	},
	{
		Id = "Durian",
		Name = "Durian",
		Tier = "Epic",
		Chance = 1_470,
		Price = 60_000,
		CookTime = 130,
		Color = Color3.fromRGB(158, 160, 70),
		Icon = "rbxassetid://70822788180255",
	},
	{
		Id = "DragonFruit",
		Name = "Dragon Fruit",
		Tier = "Epic",
		Chance = 1_600,
		Price = 65_000,
		CookTime = 125,
		Color = Color3.fromRGB(230, 60, 140),
		Icon = "rbxassetid://110364045821396",
	},
	{
		Id = "Ribeye",
		Name = "Ribeye",
		Tier = "Epic",
		Chance = 1_766,
		Price = 70_000,
		CookTime = 165,
		Color = Color3.fromRGB(188, 64, 58),
		Icon = "rbxassetid://71552586185568",
	},
	{
		Id = "Ham",
		Name = "Ham",
		Tier = "Epic",
		Chance = 1_950,
		Price = 75_000,
		CookTime = 170,
		Color = Color3.fromRGB(235, 140, 140),
		Icon = "rbxassetid://92987042124515",
	},
	{
		Id = "CrocodileMeat",
		Name = "Crocodile Meat",
		Tier = "Epic",
		Chance = 2_163,
		Price = 80_000,
		CookTime = 210,
		Color = Color3.fromRGB(150, 175, 130),
		Icon = "rbxassetid://125456596370234",
	},
	{
		Id = "Salmon",
		Name = "Salmon",
		Tier = "Epic",
		Chance = 2_400,
		Price = 85_000,
		CookTime = 200,
		Color = Color3.fromRGB(250, 142, 110),
		Icon = "rbxassetid://115449184910204",
	},

	{
		Id = "Lamb",
		Name = "Lamb",
		Tier = "Legendary",
		Chance = 3_550,
		Price = 100_000,
		CookTime = 225,
		Color = Color3.fromRGB(176, 96, 88),
		Icon = "rbxassetid://84226839644571",
	},
	{
		Id = "BeefShank",
		Name = "Beef Shank",
		Tier = "Legendary",
		Chance = 3_788,
		Price = 110_000,
		CookTime = 240,
		Color = Color3.fromRGB(132, 56, 62),
		Icon = "rbxassetid://105125742934272",
	},
	{
		Id = "RibRack",
		Name = "Rib Rack",
		Tier = "Legendary",
		Chance = 4_041,
		Price = 125_000,
		CookTime = 250,
		Color = Color3.fromRGB(172, 74, 40),
		Icon = "rbxassetid://77920164635859",
	},
	{
		Id = "GoatLeg",
		Name = "Goat Leg",
		Tier = "Legendary",
		Chance = 4_600,
		Price = 150_000,
		CookTime = 280,
		Color = Color3.fromRGB(160, 90, 70),
		Icon = "rbxassetid://96822391326811",
	},

	{
		Id = "MangoCaviar",
		Name = "Mango Caviar",
		Tier = "Mythic",
		Chance = 17_000,
		Price = 300_000,
		CookTime = 550,
		Color = Color3.fromRGB(252, 194, 110),
		Icon = "rbxassetid://130276513727147",
	},
	{
		Id = "Caviar",
		Name = "Caviar",
		Tier = "Mythic",
		Chance = 24_000,
		Price = 500_000,
		CookTime = 600,
		Color = Color3.fromRGB(58, 54, 72),
		Icon = "rbxassetid://108873530586095",
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
