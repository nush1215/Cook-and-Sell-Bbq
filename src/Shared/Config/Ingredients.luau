--[[
    Every ingredient, and the tiers that price them.

    An entry authors three balance knobs: its Tier (setting the band -- cook time, sale multiplier, label
    colour, fallback price), its Price (where in that band it sits), and its Chance, written as the player
    reads it: 1 in this many rolls.

    Price is both what an ingredient costs off a stand and what its sale value is figured from, so the two
    always move together -- repricing changes how much is riding on a roll, never whether it's a good
    deal. That's ValueMultiplier, which is per tier.

    THE RULE: the chances must add up to 100%, i.e. 1/Chance summed over every ingredient must come to 1.
    At 1.05 there's 5% more promised than a roll can hand out and every ingredient is really 5% rarer than
    its number, so adding one at "1 in 20" means bumping others up to pay for it. Labels render the *real*
    odds (authored Chance scaled by that sum) and a load-time warn says which way to nudge -- Roblox
    requires accurate odds on random items sold for Robux, so this isn't optional.

    Ballpark for a new entry -- Chance: Common 9-51, Uncommon 55-137, Rare 170-450, Epic 700-1.2K,
    Legendary ~2K, Mythic ~10K. Price: Common 75-260, Uncommon 300-750, Rare 900-2K, Epic 3.5K-5K; past
    that, omit Price and take the tier's. Mythic ships empty on purpose -- headroom for the luxurious
    stuff (wagyu, lobster, truffle) that costs nothing to leave sitting there.

    Adding one is never a local edit. Every 1/Chance has to keep summing to 1, so a new entry's share has
    to come out of the others -- in practice that means re-solving the whole column rather than picking a
    number for the newcomer. The tier bands above are what's left once that's done; they'll move again the
    next time the roster grows.
]]

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
	Price: number, -- the tier's anchor price: what an entry costs off a rolling stand if it names no Price
	-- of its own, and roughly what the tier's entries average out to once they've fanned around it
	CookTime: number, -- seconds one of them takes to cook on a griller (see GetTotalCookTime)
	ValueMultiplier: number, -- what it sells for per dollar it cost, on top of SALE_VALUE_MULTIPLIER
	TextColor: Color3, -- not authored below, back-filled from Shared.Colors
	StrokeColor: Color3, -- the label's stroke, likewise back-filled
}

export type Ingredient = {
	Id: string, -- also the name of the model under Assets.Ingredients.Raw / .Cooked
	Name: string,
	Tier: Tier, -- authored as a tier id (a string) below, back-filled to the tier itself
	Chance: number, -- the odds on its label, 1 in this many rolls. Authored as the number you want; corrected
	-- at load to the real odds, which are exactly that number whenever the config adds up to 100%
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

-- The global economy dial, on top of every tier's ValueMultiplier. Raise it to make selling more
-- lucrative across the board; retune ValueMultiplier to change how steeply rarity pays.
--
-- It also sets the floor under a sale, and that is the constraint to keep: a skewer has to sell for
-- more than its ingredients cost even when everything goes wrong, or a bad cook is a loss and the
-- player is working to stand still. The worst case is the cheapest ingredients cooked to Charred and
-- offered the minimum, so what has to stay above 1 is
--
--     SALE_VALUE_MULTIPLIER * the Charred Multiplier * its OfferMin (both on CookStates.Data)
--
-- which is 1.5 * 0.8 * 1 = 1.2 today. At the 1.25 this used to read it came to exactly 1.0, and the
-- stick under the ingredients tipped it negative -- a charred common skewer sold for less than it
-- cost to build. Lower this, or lower Charred, and check that product first.
Ingredients.SALE_VALUE_MULTIPLIER = 1.4

-- What each slot past the slowest adds, as a fraction of its own CookTime. The skewer cooks in one piece,
-- so the slowest ingredient sets the length and the rest only add heat to shift -- which is what makes
-- capacity worth paying for: a full stick isn't a full stick's worth of waiting.
--
-- Short of 1 so filling a stick pays, and clear of 0 so it still costs something -- value has no falloff
-- at all (GetTotalValue), so at 0 an extra slot would be free money.
Ingredients.ADDITIONAL_SLOT_FACTOR = 0.8

-- How far off 100% the chances may sum before the load-time warn fires. Set to where drift would start to
-- show rather than at zero -- a 1% miss turns "1 in 20" into "1 in 20.2", which still prints 20.
Ingredients.CHANCE_SUM_TOLERANCE = 0.02

-- The Robux products an ingredient can be bought outright with, cheapest first. Keyed by *band* rather
-- than by the thing they buy: thirty-three ingredients and more coming, against ten products.
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

-- ProductPriceBands[n] is the most Bux band n covers. An ingredient sells in the first band its Price fits
-- under, and anything dearer takes the top band -- so this list is one shorter than RobuxProductIds.
--
-- Thresholds rather than a band named per entry, so a new ingredient places itself from its Price alone.
-- The gaps are deliberate: T7 and T9 are headroom, and every one of the fifteen ingredients added most
-- recently placed itself here without this list being touched -- which is the whole point of it.
Ingredients.ProductPriceBands = {
	100, -- T1: Corn - Jalapeno
	200, -- T2: Carrot - Chicken
	500, -- T3: Cauliflower - Strawberry
	1_000, -- T4: Grape - Mango
	2_500, -- T5: Turkey - Shrimp
	6_000, -- T6: Duck, Salmon
	15_000, -- T7: headroom
	60_000, -- T8: Legendary's anchor, where Lamb lands
	150_000, -- T9: headroom
	-- T10 is everything above, which is where Mythic's 400k anchor lands
}

table.freeze(Ingredients.RobuxProductIds)
table.freeze(Ingredients.ProductPriceBands)

-- Commonest first. ValueMultiplier climbs with rarity, so chasing rares pays a better return per dollar
-- rather than just a bigger number. Price is the anchor a tier's entries are priced *around* -- move it to
-- shift a whole tier, reprice the entries to change how far apart they sit.
--
-- CookTime and ValueMultiplier climb together, steeply: the good stuff is the slow stuff, so a rare buys a
-- longer wait for a much better return rather than a strictly better ingredient. Common doesn't move --
-- near enough nine rolls in ten land there, so it stays the quick baseline everything else is measured against.
--
-- CookTime is an anchor the same way Price is, not a flat rate every entry pays: each one names its own,
-- fanned around this number by what the food actually is -- dense things that have to cook through at the
-- top of the band, small wet things at the bottom. What it still is, is the fallback, so an entry added
-- without one lands on its tier's rate rather than nothing. Keep the bands from overlapping when retuning:
-- them touching but not crossing is what keeps the slow thing and the valuable thing the same thing.
Ingredients.Tiers = {
	{
		Id = "Common",
		Price = 100,
		CookTime = 10,
		ValueMultiplier = 1,
	},
	{
		Id = "Uncommon",
		Price = 450,
		CookTime = 24,
		ValueMultiplier = 1.35,
	},
	{
		Id = "Rare",
		Price = 1_700,
		CookTime = 40,
		ValueMultiplier = 1.8,
	},
	{
		Id = "Epic",
		Price = 5_000,
		CookTime = 60,
		ValueMultiplier = 2.4,
	},
	{
		Id = "Legendary",
		Price = 60_000,
		CookTime = 85,
		ValueMultiplier = 3.2,
	},
	{
		Id = "Mythic",
		Price = 400_000,
		CookTime = 110,
		ValueMultiplier = 4.2,
	},
}

-- Keyed on tier Id into Shared.Colors -- the same palette the sticks use, so a Rare ingredient and a Rare
-- stick read the same colour.
local tiersById = {}

for _, tier in Ingredients.Tiers do
	tier.TextColor = Colors[tier.Id].TextColor
	tier.StrokeColor = Colors[tier.Id].StrokeColor
	tiersById[tier.Id] = tier
end

table.freeze(Ingredients.Tiers)
table.freeze(tiersById)

-- Grouped by tier, commonest first. Config order is the Index grid's layout order and nothing else. The
-- chances add up to 99.9998%, so every label reads exactly the number written on it.
--
-- Price rises with rarity down a tier as well as across them, so the Index reads as one ladder rather than
-- flat blocks. Repeating prices (the two peppers, onion and garlic) are wanted -- round numbers a tier
-- apart read better than thirty-three forced-unique ones. Lamb names none, being alone in Legendary.
--
-- A tier's price band is wider than the cheapest thing in it: the dearest common costs more than three
-- times the cheapest, which is what lets a common still be a decision rather than a shrug. What the bands
-- can't do is touch -- the load-time check below wants every tier strictly dearer and strictly rarer than
-- the one under it, so the room to fan an entry out is whatever sits between its tier and the next.
Ingredients.Data = {
	--
	{
		Id = "Corn",
		Name = "Corn",
		Tier = "Common",
		Chance = 9,
		Price = 75,
		CookTime = 14,
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
		CookTime = 7,
		Color = Color3.fromRGB(235, 227, 209),
		Icon = "rbxassetid://116516365048951",
	},
	{
		Id = "Potato",
		Name = "Potato",
		Tier = "Common",
		Chance = 12,
		Price = 85,
		CookTime = 16,
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
		CookTime = 8,
		Color = Color3.fromRGB(58, 138, 62),
		Icon = "rbxassetid://74090150295164",
	},
	{
		Id = "Carrot",
		Name = "Carrot",
		Tier = "Common",
		Chance = 19,
		Price = 105,
		CookTime = 15,
		Color = Color3.fromRGB(235, 122, 46),
		Icon = "rbxassetid://123200499909407",
	},
	{
		Id = "Tomato",
		Name = "Tomato",
		Tier = "Common",
		Chance = 21,
		Price = 110,
		CookTime = 7,
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
		CookTime = 8,
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
		CookTime = 14,
		Color = Color3.fromRGB(238, 208, 156),
		Icon = "rbxassetid://85763737510059",
	},
	{
		Id = "Cauliflower",
		Name = "Cauliflower",
		Tier = "Common",
		Chance = 44,
		Price = 210,
		CookTime = 13,
		Color = Color3.fromRGB(238, 232, 214),
		Icon = "rbxassetid://123187358827349",
	},
	{
		Id = "Eggplant",
		Name = "Eggplant",
		Tier = "Common",
		Chance = 51,
		Price = 260,
		CookTime = 12,
		Color = Color3.fromRGB(108, 62, 140),
		Icon = "rbxassetid://88534976012906",
	},

	--
	{
		Id = "Pineapple",
		Name = "Pineapple",
		Tier = "Uncommon",
		Chance = 55,
		Price = 300,
		CookTime = 28,
		Color = Color3.fromRGB(245, 203, 54),
		Icon = "rbxassetid://104408088619027",
	},
	{
		Id = "Pork",
		Name = "Pork",
		Tier = "Uncommon",
		Chance = 61,
		Price = 320,
		CookTime = 32,
		Color = Color3.fromRGB(241, 157, 157),
		Icon = "rbxassetid://79245029595159",
	},
	{
		Id = "Apple",
		Name = "Apple",
		Tier = "Uncommon",
		Chance = 67,
		Price = 350,
		CookTime = 26,
		Color = Color3.fromRGB(214, 61, 58),
		Icon = "rbxassetid://120797045727521",
	},
	{
		Id = "Banana",
		Name = "Banana",
		Tier = "Uncommon",
		Chance = 75,
		Price = 390,
		CookTime = 21,
		Color = Color3.fromRGB(245, 219, 91),
		Icon = "rbxassetid://85163764338788",
	},
	{
		Id = "Melon",
		Name = "Melon",
		Tier = "Uncommon",
		Chance = 83,
		Price = 430,
		CookTime = 24,
		Color = Color3.fromRGB(243, 163, 96),
		Icon = "rbxassetid://71556666204567",
	},
	{
		Id = "Peach",
		Name = "Peach",
		Tier = "Uncommon",
		Chance = 91,
		Price = 470,
		CookTime = 22,
		Color = Color3.fromRGB(250, 176, 124),
		Icon = "rbxassetid://131315537607177",
	},
	{
		Id = "Strawberry",
		Name = "Strawberry",
		Tier = "Uncommon",
		Chance = 101,
		Price = 500,
		CookTime = 19,
		Color = Color3.fromRGB(240, 84, 110),
		Icon = "rbxassetid://76710810752276",
	},
	{
		Id = "Grape",
		Name = "Grape",
		Tier = "Uncommon",
		Chance = 112,
		Price = 580,
		CookTime = 19,
		Color = Color3.fromRGB(150, 92, 196),
		Icon = "rbxassetid://111929211427017",
	},
	{
		Id = "Kiwi",
		Name = "Kiwi",
		Tier = "Uncommon",
		Chance = 124,
		Price = 640,
		CookTime = 20,
		Color = Color3.fromRGB(143, 191, 74),
		Icon = "rbxassetid://127403783130431",
	},
	{
		Id = "Asparagus",
		Name = "Asparagus",
		Tier = "Uncommon",
		Chance = 137,
		Price = 750,
		CookTime = 23,
		Color = Color3.fromRGB(106, 158, 84),
		Icon = "rbxassetid://101470358908580",
	},

	--
	{
		Id = "Mango",
		Name = "Mango",
		Tier = "Rare",
		Chance = 170,
		Price = 900,
		CookTime = 34,
		Color = Color3.fromRGB(247, 168, 51),
		Icon = "rbxassetid://82309715085228",
	},
	{
		Id = "Turkey",
		Name = "Turkey",
		Tier = "Rare",
		Chance = 220,
		Price = 1_100,
		CookTime = 44,
		Color = Color3.fromRGB(214, 168, 110),
		Icon = "rbxassetid://135131325322026",
	},
	{
		Id = "Beef",
		Name = "Beef",
		Tier = "Rare",
		Chance = 280,
		Price = 1_300,
		CookTime = 50,
		Color = Color3.fromRGB(156, 66, 53),
		Icon = "rbxassetid://95071209025169",
	},
	{
		Id = "Bacon",
		Name = "Bacon",
		Tier = "Rare",
		Chance = 350,
		Price = 1_600,
		CookTime = 39,
		Color = Color3.fromRGB(206, 92, 84),
		Icon = "rbxassetid://122800616171926",
	},
	{
		Id = "Shrimp",
		Name = "Shrimp",
		Tier = "Rare",
		Chance = 450,
		Price = 2_000,
		CookTime = 35,
		Color = Color3.fromRGB(255, 133, 112),
		Icon = "rbxassetid://83047236472578",
	},

	--
	{
		Id = "Duck",
		Name = "Duck",
		Tier = "Epic",
		Chance = 700,
		Price = 3_500,
		CookTime = 68,
		Color = Color3.fromRGB(150, 88, 66),
		-- TODO: real icon. This id is a placeholder and renders nothing -- and a blank icon on an
		-- undiscovered Index cell looks exactly like the locked state, so it won't announce itself.
		Icon = "rbxassetid://0",
	},
	{
		Id = "Salmon",
		Name = "Salmon",
		Tier = "Epic",
		Chance = 1_200,
		Price = 5_000,
		CookTime = 54,
		Color = Color3.fromRGB(250, 142, 110),
		Icon = "rbxassetid://115449184910204",
	},

	--
	{
		Id = "Lamb",
		Name = "Lamb",
		Tier = "Legendary",
		Chance = 2_200,
		Color = Color3.fromRGB(176, 96, 88),
		Icon = "rbxassetid://84226839644571",
	},
}

-- Resolves each entry's tier and pulls its raw + cooked models out of Assets.Ingredients, matched on Id.
-- An entry missing either model, naming an unknown tier, or lacking a Chance is dropped rather than left
-- half-built. Runs before anything is weighted: a dropped entry must not count toward the sum, or every
-- label would be off by the share of something that can never roll.
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

-- Everything an entry didn't author comes off its tier, and its roll weight is just the reciprocal of
-- the odds it asked for. Summed, those reciprocals are how much of a roll the config has promised out.
local totalWeight = 0

for _, ingredient in Ingredients.Data do
	local tier = ingredient.Tier

	ingredient.Price = ingredient.Price or tier.Price
	ingredient.CookTime = ingredient.CookTime or tier.CookTime
	ingredient.Weight = 1 / ingredient.Chance

	totalWeight += ingredient.Weight
end

-- The roller normalises, so an ingredient really rolls at its authored odds scaled by the sum. Chance is
-- corrected in place, so every label shows the real odds -- then warned about, since an ingredient added
-- at "1 in 20" without paying for it elsewhere is the mistake this catches.
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

-- The other two ways to mis-author the ladder, both of them a tier overlapping the one below it. A
-- Chance that has a tier's rarest member rolling as often as the next tier's commonest -- a Common
-- typed at 1 in 40 next to an Uncommon at 1 in 30 -- reads as a bug to anyone who sees a "rare" turn up
-- more than an uncommon. A Price does the same the moment entries set their own: a Common at $600 sat
-- next to an Uncommon at $400 makes the cheaper thing the rarer one. Both checked here rather than left
-- to be noticed in-game.
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

	-- An empty tier has nothing to be out of order with, so it's skipped and the tier below it stays
	-- the one the next populated tier is measured against
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

-- [id] = ingredient, built once at load. GetIngredientFromId is called per ingredient inside
-- GetTotalCookTime and GetTotalValue -- and GetTotalValue runs on every customer offer and every
-- held-skewer estimate -- so a scan there would cost the whole roster on each one.
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

-- The Robux price band something costing this many Bux is sold in. The bands are ceilings, cheapest
-- first, so the first one it fits under is its own and anything past the last takes the top band.
function Ingredients.GetProductTier(price: number): number
	for tier, ceiling in Ingredients.ProductPriceBands do
		if price <= ceiling then
			return tier
		end
	end

	return #Ingredients.RobuxProductIds
end

-- The Products.luau string id for one of the Robux price bands. Built in one place so the config that
-- generates the product and the code that prompts it can't drift apart.
function Ingredients.GetProductStringId(tier: number): string
	return `Ingredient_T{tier}`
end

-- The string id of the product that buys an ingredient at this price outright. The band comes off what
-- it costs in Bux, so a new ingredient is priced by the ladder rather than needing an id of its own.
function Ingredients.GetProductStringIdForPrice(price: number): string
	return Ingredients.GetProductStringId(Ingredients.GetProductTier(price))
end

-- The dearest ingredient a band sells, for paying out a receipt that found nothing on the stands to
-- spend itself on. Nil for a band nothing has grown into yet -- T7 and T9 both sit empty today.
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

-- Total seconds to cook a skewer holding `ids`. The slowest ingredient on it counts its full CookTime --
-- it's the one that has to be cooked through, so it decides when the skewer is done -- and every other
-- slot adds ADDITIONAL_SLOT_FACTOR of its own. So a stick of five corn isn't five times as slow as one,
-- and neither is a stick of five different things. An id the config no longer has contributes nothing.
--
-- Discounting every slot including the slowest and then topping that one back up, rather than working
-- out which slot is the slowest first and running a second pass to add the others: same answer, one
-- pass, and nothing that breaks if two ingredients tie for longest.
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

-- What a skewer holding `ids` is worth to sell, before a customer's offer haggles around it. Every copy pays
-- full value (unlike cook time's falloff) because every copy cost full price to buy, and each one is scaled by
-- its tier -- so a skewer of rares returns more per dollar it cost than a skewer of commons, not just more
-- money. An id the config no longer has contributes nothing.
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
