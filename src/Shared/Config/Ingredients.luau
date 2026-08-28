--[[
    Every ingredient in the game, and the tiers that price them.

    An ingredient authors three things about its balance: the tier it's in, its Chance, and its Price.
    The tier sets the band -- cook time, sale multiplier, label colour, and the price an entry falls back
    to if it doesn't name one; Price is where in that band this particular one sits. Chance is the odds
    you want on its label, written the way the player reads it -- 1 in this many rolls. Put 20 and it
    says "1 in 20".

    Price climbs with rarity inside a tier, so the rarest common costs more than the commonest one. It's
    both what the ingredient costs off a rolling stand and what its sale value is figured from, which
    means the two always move together -- repricing an entry changes how much is riding on rolling it,
    never whether it's a good deal. What decides that is ValueMultiplier, and that's per tier.

    The one rule: the chances have to add up to 100%. Every roll lands on something, so 1/Chance
    summed over every ingredient has to come to 1 -- if it comes to 1.05, there's 5% more promised than
    a roll can hand out, and every ingredient is really 5% rarer than its number. Adding an ingredient
    at "1 in 20" is 5% of rolls that has to come from somewhere, so bump a few others up to pay for it.

    Labels never lie about it. What renders is the real odds -- the authored Chance scaled by that
    sum -- which is exactly the number written here whenever the config adds up, and a load-time warn
    says by how much and which way to nudge whenever it doesn't. Roblox requires the odds shown on
    random items to be accurate, and currency is sold for Robux, so this isn't optional.

    Ballpark for a new entry -- Chance: Common 7-25, Uncommon 30-80, Rare 150-500, Epic 1K-3K,
    Legendary ~10K, Mythic ~100K. Price: Common 75-180, Uncommon 320-580, Rare 1.3K-2K, and past
    that the tier's own Price, since those tiers are too thin to have a band yet. Leave Price off
    entirely and it takes the tier's, which is the right call for a tier with one entry in it.

    Legendary and Mythic ship empty on purpose -- headroom for the genuinely luxurious stuff (wagyu,
    lobster, truffle) that costs nothing to leave sitting there.
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

-- The global economy dial, applied on top of every tier's ValueMultiplier. Raise it to make selling
-- more lucrative across the board; retier or retune ValueMultiplier to change how steeply rarity pays.
Ingredients.SALE_VALUE_MULTIPLIER = 1.25

-- What every slot past the slowest one adds to the cook, as a fraction of its own CookTime. The skewer
-- goes on the grill in one piece, so what sets the length is the thing on it that needs the longest --
-- the rest ride along, adding heat to shift rather than a cook of their own. That's what makes capacity
-- worth paying for: a full stick isn't a full stick's worth of waiting.
--
-- Short of 1 so filling a stick is worth doing, and well clear of 0 so it still costs something: value
-- has no falloff at all (see GetTotalValue), and at 0 an empty slot would be free money.
Ingredients.ADDITIONAL_SLOT_FACTOR = 0.75

-- How far the chances can add up to short of or past 100% before the load-time warn fires. Small drift
-- rounds away on the labels (a 1% miss turns "1 in 20" into "1 in 20.2", which still prints 20), so
-- this is set to where it would start to show rather than at zero.
Ingredients.CHANCE_SUM_TOLERANCE = 0.02

-- The Robux dev products an ingredient can be bought outright with when the player hasn't the Bux for
-- it, cheapest first. These are keyed by *band* rather than by the thing they buy: there are eighteen
-- ingredients and more coming, against ten products, so a product is a price band and whichever
-- ingredient falls into it is what that band sells.
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

-- ProductPriceBands[n] is the most Bux band n covers. An ingredient is sold in the first band its Price
-- fits under, and anything dearer than the last threshold takes the top band -- so this list is one
-- shorter than RobuxProductIds, and a tier past Mythic doesn't have to mean touching it.
--
-- Thresholds rather than a tier named per entry, because a new ingredient then places itself: author its
-- Price and it's already sellable for Robux at whatever the ladder says something that dear goes for.
-- The gaps are deliberate -- T7 and T9 are the headroom Legendary and Mythic are waiting to be filled in
-- around, the same way those tiers ship empty.
Ingredients.ProductPriceBands = {
	100, -- T1: Corn - Jalapeno
	200, -- T2: Tomato - Chicken
	500, -- T3: Pineapple - Strawberry
	1_000, -- T4: Grape
	2_500, -- T5: Beef, Shrimp
	6_000, -- T6: Salmon
	15_000, -- T7: headroom
	60_000, -- T8: Legendary's anchor
	150_000, -- T9: headroom
	-- T10 is everything above, which is where Mythic's 400k anchor lands
}

table.freeze(Ingredients.RobuxProductIds)
table.freeze(Ingredients.ProductPriceBands)

-- Ordered commonest first. ValueMultiplier climbs with rarity so chasing rares pays a better return per
-- dollar spent, not just a bigger number per skewer slot. Price is the anchor the tier's entries are
-- priced around rather than the price they all pay -- move it to shift a whole tier, and reprice the
-- entries to change how far apart the cheapest and dearest of them sit.
--
-- CookTime and ValueMultiplier climb together on purpose, and steeply: the good stuff is the slow stuff,
-- so what a rare buys is a longer wait for a much better return rather than a strictly better ingredient.
-- Common is the one that doesn't move -- it's the whole of the opening loop (near enough nine rolls in
-- ten land there), so it stays quick and stays the baseline everything else is measured against. The
-- climb past it is what a player is actually chasing.
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

-- Each tier takes its label colour from Shared.Colors, keyed on its own Id -- the same palette the
-- sticks tier themselves out of, so a Rare ingredient and a Rare stick read the same colour.
local tiersById = {}

for _, tier in Ingredients.Tiers do
	tier.TextColor = Colors[tier.Id].TextColor
	tier.StrokeColor = Colors[tier.Id].StrokeColor
	tiersById[tier.Id] = tier
end

table.freeze(Ingredients.Tiers)
table.freeze(tiersById)

-- Grouped by tier, commonest first -- config order is the order the Index grid lays them out in, and
-- nothing else. Tiering is loosely how the real thing ranks: garden veg and the cheapest meat, then
-- the fruit and everyday cuts you'd actually throw on a barbecue, then the ones you'd save for. The
-- chances below add up to 99.997%, so every label reads exactly the number written on it.
--
-- Price rises with rarity down a tier as well as across them, so the Index reads as one ladder from
-- corn to salmon rather than a set of flat blocks. Prices repeating (the two peppers, onion and garlic)
-- is fine and wanted -- round numbers a tier apart read better than eighteen forced-unique ones.
-- Salmon names no Price because it's alone in Epic, so there's nothing to fan it out against.
Ingredients.Data = {
	--
	{
		Id = "Corn",
		Name = "Corn",
		Tier = "Common",
		Chance = 7,
		Price = 75,
		Color = Color3.fromRGB(255, 214, 71),
		Icon = "rbxassetid://100285505624996",
	},
	{
		Id = "Onion",
		Name = "Onion",
		Tier = "Common",
		Chance = 8,
		Price = 80,
		Color = Color3.fromRGB(216, 206, 224),
		Icon = "rbxassetid://98242838233542",
	},
	{
		Id = "Garlic",
		Name = "Garlic",
		Tier = "Common",
		Chance = 9,
		Price = 80,
		Color = Color3.fromRGB(235, 227, 209),
		Icon = "rbxassetid://116516365048951",
	},
	{
		Id = "RedBellPepper",
		Name = "Red Bell Pepper",
		Tier = "Common",
		Chance = 10,
		Price = 90,
		Color = Color3.fromRGB(206, 62, 53),
		Icon = "rbxassetid://77712961773231",
	},
	{
		Id = "YellowBellPepper",
		Name = "Yellow Bell Pepper",
		Tier = "Common",
		Chance = 11,
		Price = 90,
		Color = Color3.fromRGB(240, 196, 62),
		Icon = "rbxassetid://72467817521534",
	},
	{
		Id = "Jalapeno",
		Name = "Jalapeno",
		Tier = "Common",
		Chance = 12,
		Price = 95,
		Color = Color3.fromRGB(58, 138, 62),
		Icon = "rbxassetid://74090150295164",
	},
	{
		Id = "Tomato",
		Name = "Tomato",
		Tier = "Common",
		Chance = 15,
		Price = 110,
		Color = Color3.fromRGB(228, 65, 55),
		Icon = "rbxassetid://136870243322899",
	},
	{
		Id = "Zucchini",
		Name = "Zucchini",
		Tier = "Common",
		Chance = 16,
		Price = 115,
		Color = Color3.fromRGB(109, 166, 70),
		Icon = "rbxassetid://72438289618144",
	},
	{
		Id = "Mushroom",
		Name = "Mushroom",
		Tier = "Common",
		Chance = 19,
		Price = 140,
		Color = Color3.fromRGB(198, 170, 132),
		Icon = "rbxassetid://120620478711696",
	},
	{
		Id = "Chicken",
		Name = "Chicken",
		Tier = "Common",
		Chance = 24,
		Price = 180,
		Color = Color3.fromRGB(238, 208, 156),
		Icon = "rbxassetid://85763737510059",
	},

	--
	{
		Id = "Pork",
		Name = "Pork",
		Tier = "Uncommon",
		Chance = 30,
		Price = 320,
		Color = Color3.fromRGB(241, 157, 157),
		Icon = "rbxassetid://79245029595159",
	},
	{
		Id = "Pineapple",
		Name = "Pineapple",
		Tier = "Uncommon",
		Chance = 35,
		Price = 300,
		Color = Color3.fromRGB(245, 203, 54),
		Icon = "rbxassetid://104408088619027",
	},
	{
		Id = "Melon",
		Name = "Melon",
		Tier = "Uncommon",
		Chance = 45,
		Price = 430,
		Color = Color3.fromRGB(243, 163, 96),
		Icon = "rbxassetid://71556666204567",
	},
	{
		Id = "Strawberry",
		Name = "Strawberry",
		Tier = "Uncommon",
		Chance = 60,
		Price = 500,
		Color = Color3.fromRGB(240, 84, 110),
		Icon = "rbxassetid://76710810752276",
	},
	{
		Id = "Grape",
		Name = "Grape",
		Tier = "Uncommon",
		Chance = 80,
		Price = 580,
		Color = Color3.fromRGB(150, 92, 196),
		Icon = "rbxassetid://111929211427017",
	},

	--
	{
		Id = "Beef",
		Name = "Beef",
		Tier = "Rare",
		Chance = 150,
		Price = 1_300,
		Color = Color3.fromRGB(156, 66, 53),
		Icon = "rbxassetid://95071209025169",
	},
	{
		Id = "Shrimp",
		Name = "Shrimp",
		Tier = "Rare",
		Chance = 400,
		Price = 2_000,
		Color = Color3.fromRGB(255, 133, 112),
		Icon = "rbxassetid://83047236472578",
	},

	--
	{
		Id = "Salmon",
		Name = "Salmon",
		Tier = "Epic",
		Chance = 1_200,
		Color = Color3.fromRGB(250, 142, 110),
		Icon = "rbxassetid://115449184910204",
	},
}

-- Each entry resolves the tier it names and pulls its raw + cooked models out of
-- Assets.Ingredients.Raw / .Cooked, matched on Id. An entry missing either model, naming a tier that
-- doesn't exist, or authored without a Chance gets dropped rather than left half-built, so a typo'd
-- entry can't be rolled (or cooked) and then error mid-animation. This runs before anything is
-- weighted on purpose: a dropped entry must not count toward the sum, or every label would be off by
-- the share of a thing that can never roll.
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

-- The roller normalises, so what an ingredient really rolls at is its authored odds scaled by that
-- sum -- exactly its number when the config adds up to 100%, and honestly off it when it doesn't.
-- Chance is corrected in place so every label in the game shows the real odds. Then say so, loudly:
-- an ingredient added at "1 in 20" without paying for it elsewhere is the mistake this catches.
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
