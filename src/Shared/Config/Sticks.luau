-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Assets
local Assets = ReplicatedStorage.Assets
local SticksFolder = Assets.Sticks

--
export type Stick = {
	Id: string, -- also the name of the model under Assets.Sticks
	Name: string,
	Price: number, -- what it costs to buy the stick, and what SALE_RETURN_FACTOR credits back on a sale
	Capacity: number, -- how many ingredients this stick can hold
	ValueBoost: number, -- percent added to what a skewer built on this stick sells for (0 = no boost)
	Icon: string, -- rbxassetid for this stick's UI icon
	TextColor: Color3, -- colour for this stick's name label in UI
	StrokeColor: Color3, -- the label's stroke, a darker shade of the text colour
	Restockable: boolean, -- shows in the stick shop and is eligible for the timed restock roll
	RestockChance: number?, -- percent 0-100 the shop rolls to stock this stick each window (nil if not restockable)
	RestockAmount: NumberRange?, -- how many units a successful roll stocks, min..max (nil if not restockable)
	Rarity: string, -- rarity word shown in the shop, keyed into Shared.Colors for its tint
	RobuxProductId: number?, -- Robux dev-product asset id; buying it grants this stick (0 = not sold for Robux yet)
	Model: Model, -- not authored below, back-filled from Assets.Sticks
}

--
local Sticks = {}

-- What slice of a stick's own Price comes back in the sale of the skewer built on it, so the tier a
-- player skewered on shows up in the payout rather than only in how many slots they got. A sale
-- destroys the stick, so this is the stick being liquidated, never a refund.
-- Higher = expensive sticks pay more of themselves off per sale. Past ~0.148 a stick can sell for more
-- than it cost under a lucky haggle, which turns the shop into a money loop.
-- This is the smaller of the two ways a tier reaches the payout: the other is ValueBoost below, which
-- scales the whole skewer rather than crediting back a flat slice, so raise them together with care.
Sticks.SALE_RETURN_FACTOR = 0.1

-- Ordered lowest to highest: array order is the tier, so wooden is the cheapest stick and diamond
-- the best. Id matches the model name under Assets.Sticks.
Sticks.Data = {
	{
		Id = "WoodenStick",
		Name = "Wooden",
		Price = 5,
		Capacity = 2,
		ValueBoost = 0,
		Icon = "rbxassetid://135179026727588",
		TextColor = Color3.fromRGB(255, 170, 0),
		StrokeColor = Color3.fromRGB(80, 53, 0),
		Restockable = true,
		RestockChance = 100,
		RestockAmount = NumberRange.new(20, 30),
		Rarity = "Common",
		RobuxProductId = 3709026132,
	},
	{
		Id = "BambooStick",
		Name = "Bamboo",
		Price = 50,
		Capacity = 3,
		ValueBoost = 0,
		Icon = "rbxassetid://130367453779475",
		TextColor = Color3.fromRGB(140, 200, 75),
		StrokeColor = Color3.fromRGB(42, 60, 22),
		Restockable = true,
		RestockChance = 80,
		RestockAmount = NumberRange.new(6, 12),
		Rarity = "Uncommon",
		RobuxProductId = 3709026151,
	},
	{
		Id = "CopperStick",
		Name = "Copper",
		Price = 500,
		Capacity = 5,
		ValueBoost = 5,
		Icon = "rbxassetid://71422270507233",
		TextColor = Color3.fromRGB(210, 120, 55),
		StrokeColor = Color3.fromRGB(63, 36, 16),
		Restockable = true,
		RestockChance = 60,
		RestockAmount = NumberRange.new(4, 8),
		Rarity = "Rare",
		RobuxProductId = 3709026173,
	},
	{
		Id = "TitaniumStick",
		Name = "Titanium",
		Price = 1_000,
		Capacity = 6,
		ValueBoost = 10,
		Icon = "rbxassetid://139823220671033",
		TextColor = Color3.fromRGB(175, 190, 205),
		StrokeColor = Color3.fromRGB(52, 57, 62),
		Restockable = true,
		RestockChance = 40,
		RestockAmount = NumberRange.new(3, 6),
		Rarity = "Epic",
		RobuxProductId = 3709026211,
	},

	{
		Id = "GoldStick",
		Name = "Gold",
		Price = 2_500,
		Capacity = 7,
		ValueBoost = 20,
		Icon = "rbxassetid://83501186533591",
		TextColor = Color3.fromRGB(255, 215, 0),
		StrokeColor = Color3.fromRGB(77, 64, 0),
		Restockable = true,
		RestockChance = 20,
		RestockAmount = NumberRange.new(1, 3),
		Rarity = "Legendary",
		RobuxProductId = 3709026240,
	},
	{
		Id = "DiamondStick",
		Name = "Diamond",
		Price = 250_000,
		Capacity = 8,
		ValueBoost = 30,
		Icon = "rbxassetid://127215303482669",
		TextColor = Color3.fromRGB(110, 220, 245),
		StrokeColor = Color3.fromRGB(33, 66, 73),
		Restockable = false, -- top tier: never restocks, hidden from the stick shop
		Rarity = "Mythic",
		RobuxProductId = 3709026270, -- the only way to get one: no shop row sells it for currency
	},
}

-- Each entry pulls its own model out of Assets.Sticks, matched on Id. An entry whose model is
-- missing gets dropped rather than left half-built, so a typo'd Id can't be welded onto a tool and
-- then error mid-build.
for index = #Sticks.Data, 1, -1 do
	local stick = Sticks.Data[index]
	local model = SticksFolder:FindFirstChild(stick.Id)

	if not model then
		warn(`Stick {stick.Id} has no model in Assets.Sticks, it won't be given`)
		table.remove(Sticks.Data, index)
		continue
	end

	stick.Model = model
end

table.freeze(Sticks.Data)

function Sticks.GetStickFromId(id: string): Stick?
	for _, v in Sticks.Data do
		if v.Id == id then
			return v
		end
	end

	return nil
end

-- What a skewer built on this stick sells for, as a multiple of its plain value. A stick the config
-- no longer has -- or one carrying no boost -- prices at 1, so callers can multiply unconditionally.
function Sticks.GetValueMultiplier(id: string?): number
	local stick = id and Sticks.GetStickFromId(id)
	return if stick then 1 + stick.ValueBoost / 100 else 1
end

function Sticks.GetAllSticks(): { Stick }
	return Sticks.Data
end

-- The sticks the stick shop can stock and sell, in tier order. Filters out the ones flagged
-- Restockable = false (the diamond), so the shop roll and the client display share one source of truth.
function Sticks.GetRestockableSticks(): { Stick }
	local restockable = {}

	for _, stick in Sticks.Data do
		if stick.Restockable then
			table.insert(restockable, stick)
		end
	end

	return restockable
end

return Sticks
