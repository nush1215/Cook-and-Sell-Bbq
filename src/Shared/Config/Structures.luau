-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local GridUtil = require(script.Parent.Parent.GridUtil)

-- Assets
local Assets = ReplicatedStorage.Assets
local StructuresFolder = Assets.Structures

--
export type Footprint = { X: number, Z: number }

export type Structure = {
	Id: string, -- unique, and the name of the model under Assets.Structures[Category] it's cloned from.
	-- This is what player data stores as a structure's Type.
	Name: string, -- how it reads to the player
	Category: string, -- the folder under Assets.Structures, and the CollectionService tag placed copies wear.
	-- Also what the Grill & Stand Shop's category tabs filter its rows by.
	Cost: number, -- what one costs at the Grill & Stand Shop. Paid once, on purchase -- putting one down
	-- is free, and it moves freely between the inventory and the base after that.
	Description: string, -- the shop row's line under the name, or the Cosmetic Shop's Details toast. May carry
	-- RichText <font> markup (both render with RichText on). Use the colour constants below rather than a fresh hex.
	Icon: string, -- rbxassetid for this structure's shop icon
	TextColor: Color3, -- colour for this structure's name label in UI
	StrokeColor: Color3, -- the label's stroke, a darker shade of the text colour
	Rarity: string, -- rarity word shown in the shop, keyed into Shared.Colors for its tint
	Restockable: boolean, -- shows in the shop and is eligible for the timed restock roll
	RestockChance: number?, -- percent 0-100 the shop rolls to stock this structure each window (nil if not restockable)
	RestockAmount: NumberRange?, -- how many units a successful roll stocks, min..max (nil if not restockable)
	RobuxProductId: number?, -- Robux dev-product asset id; buying it grants this structure (0 = not sold for Robux yet)
	Mutation: string?, -- a Mutations id stamped onto whatever finishes cooking here, nil for a plain one.
	-- Kept here so the stamp is read off the grill the cook actually happened on
	MutationChance: number?, -- percent 0-100 that Mutation is stamped, or nil to stamp every time -- what
	-- separates a grill whose mutation is the grill from one where it's a bonus. Rolled server-side
	CookSpeed: number?, -- how many times faster this grill cooks, or nil for the plain rate. Divides the
	-- the whole bar, not one band, so speed is a trade -- the perfect window shrinks with it
	CookEffect: string?, -- the folder under Assets.Particles.Cooking played on the grate while cooking, or
	-- nil for the shared Default. Named, not matched off the Id, so two grills can share one set
	CookSound: string?, -- a looped sound on the grate while cooking, layered ON TOP of the shared sizzle
	-- layered over the sizzle, not replacing it, and riding the same fade
	CookInstability: number?, -- how far this grill's cook rate swings either side of 1, or nil for steady.
	-- Costs no cook time -- it removes the ability to time the window, not to reach it. Held under MAX_INSTABILITY
	CustomerPayoutMultiplier: number?, -- table-only: what a custom order seated here pays, times its graded payout
	RichChanceBonus: number?, -- table-only: added per placed copy to CustomOrderNpc.RICH_CHANCE, out of 100
	Footprint: Footprint?, -- grid cells occupied; derived from the model's Hitbox when absent
	Flat: boolean?, -- lies on the ground like a path: it only blocks other Flat pieces, so anything builds over it
	Model: Model, -- not authored below, back-filled from Assets.Structures
	FootprintX: number, -- not authored below, resolved once at load (see the back-fill loop)
	FootprintZ: number,
	SizeX: number, -- likewise; the template's Hitbox dimensions in studs, where the footprint above is
	SizeZ: number, -- the same thing rounded to whole cells
	Blocks: { [number]: { GridUtil.Rect } }, -- not authored below; [rotation] = the cells it blocks, from its
	-- footprint's min corner. The whole footprint, or only each leg's cells when it has several Hitboxes
	SeatCount: number, -- not authored below; how many children its Seats folder has, 0 for anything without one
}

-- A structure as player data holds it: which kind, and which cell of the base it stands on.
export type PlacedStructure = {
	Type: string,
	CellX: number,
	CellZ: number,
	Rotation: number,
}

-- Borrowed from the Stick Shop, so a row in either reads as the same kind of line
local SPEED_COLOR = "#55ff00"
local VALUE_COLOR = "#ffd400"

-- For the one rung whose line is a warning rather than a boast. The red ShopManager already writes by hand.
local WARNING_COLOR = "#ff7272"

-- Matches the tag read on the BBQ itself; written out rather than required off Config.Mutations
local GOLDEN_COLOR = "#ffcd41" -- Mutations.Golden.Color
local SHOCKED_COLOR = "#78cdff" -- Mutations.Shocked.Color

-- Shared by each cosmetic family, so every size of one path reads as the same material
local DIRT_TEXT_COLOR = Color3.fromRGB(170, 120, 70)
local DIRT_STROKE_COLOR = Color3.fromRGB(55, 38, 20)
local STONE_TEXT_COLOR = Color3.fromRGB(175, 175, 185)
local STONE_STROKE_COLOR = Color3.fromRGB(50, 50, 58)
local WOOD_TEXT_COLOR = Color3.fromRGB(200, 150, 90)
local WOOD_STROKE_COLOR = Color3.fromRGB(58, 43, 25)

--
local Structures = {}

-- Every placeable structure. The griller ladder buys speed, steadiness or a stamp; see docs/balance.md.
Structures.Data = {
	--------------------- [[[ GRILLERS ]]] ---------------------
	-- A ladder, cheapest first. A rung buys speed, steadiness or a stamp; see docs/balance.md
	{
		Id = "RustyGrill",
		Name = "Rusty Grill",
		Category = "Grillers",
		Cost = 1_000,
		Description = `All rusted up! The fire keeps flickering, so the bar is <font color="{WARNING_COLOR}">hard to time</font>, and it cooks <font color="{WARNING_COLOR}">10% slower</font>`,
		Icon = "rbxassetid://108556890656046",
		TextColor = Color3.fromRGB(170, 95, 55),
		StrokeColor = Color3.fromRGB(55, 30, 16),
		Rarity = "Common",
		Restockable = true,
		RestockChance = 90,
		RestockAmount = NumberRange.new(1, 2),
		RobuxProductId = 3710074789,
		-- The only rung worse than the baseline, so the first thing money buys is a grill that behaves
		CookInstability = 0.5,
		CookSpeed = 0.9,
	},

	{
		Id = "IronGrill",
		Name = "Iron Grill",
		Category = "Grillers",
		Cost = 3_500,
		-- The baseline every other rung is written against; it reads as an upgrade only because Rusty sits under it
		Description = `The good ol' trusted grill! Burns <font color="{SPEED_COLOR}">steady</font> and at <font color="{SPEED_COLOR}">full speed</font>, so the bar is easy to time`,
		Icon = "rbxassetid://118980874997825",
		TextColor = Color3.fromRGB(255, 120, 60),
		StrokeColor = Color3.fromRGB(70, 30, 12),
		Rarity = "Common",
		Restockable = true,
		RestockChance = 75,
		RestockAmount = NumberRange.new(1, 2),
		RobuxProductId = 3710074770,
	},

	{
		Id = "GasGrill",
		Name = "Gas Grill",
		Category = "Grillers",
		Cost = 50_000,
		Description = `Now we're in the big leagues! <font color="{SPEED_COLOR}">25% faster</font> cooking`,
		Icon = "rbxassetid://139507103650602",
		TextColor = Color3.fromRGB(90, 170, 255),
		StrokeColor = Color3.fromRGB(20, 50, 90),
		Rarity = "Rare",
		Restockable = true,
		RestockChance = 50,
		RestockAmount = NumberRange.new(1, 1),
		RobuxProductId = 3710074809,
		CookSpeed = 1.25,
	},

	{
		Id = "SolarGrill",
		Name = "Solar Grill",
		Category = "Grillers",
		Cost = 250_000,
		Description = `Harness the power of the sun! <font color="{SPEED_COLOR}">50% faster</font> cooking`,
		Icon = "rbxassetid://75120638448905",
		TextColor = Color3.fromRGB(255, 235, 120),
		StrokeColor = Color3.fromRGB(95, 80, 20),
		Rarity = "Epic",
		Restockable = true,
		RestockChance = 30,
		RestockAmount = NumberRange.new(1, 1),
		RobuxProductId = 3710074824,
		CookSpeed = 1.5,
	},

	{
		Id = "ElectricGrill",
		Name = "Electric Grill",
		Category = "Grillers",
		Cost = 500_000,
		Description = `I like my BBQ a little zappy! <font color="{SPEED_COLOR}">25% faster</font> cooking, and a chance for a <font color="{SHOCKED_COLOR}">Shocked</font> BBQ worth <font color="{VALUE_COLOR}">1.5x</font>`,
		Icon = "rbxassetid://106240207741508",
		TextColor = Color3.fromRGB(120, 205, 255),
		StrokeColor = Color3.fromRGB(25, 65, 95),
		Rarity = "Legendary",
		Restockable = true,
		RestockChance = 10,
		RestockAmount = NumberRange.new(1, 1),
		RobuxProductId = 3710074849,
		-- Deliberately below the Solar Grill's 1.5 -- this rung isn't bought for pace
		CookSpeed = 1.25,
		-- A chance rather than Golden's promise, so it's priced as the gamble it is
		Mutation = "Shocked",
		MutationChance = 20,
		-- Arcs and smokes instead of the shared sizzle, and hums over the top of it
		CookEffect = "Electric",
		CookSound = "ElectricCooking",
	},

	{
		Id = "GoldenGrill",
		Name = "Golden Grill",
		Category = "Grillers",
		-- Never charged -- Restockable = false keeps it out of the shop, so its dev product is the only way
		Cost = 0,
		Description = `Solid gold! Every BBQ comes off <font color="{GOLDEN_COLOR}">Golden</font>, worth <font color="{VALUE_COLOR}">1.75x</font>`,
		Icon = "",
		TextColor = Color3.fromRGB(255, 205, 65),
		StrokeColor = Color3.fromRGB(90, 66, 10),
		Rarity = "Legendary",
		Restockable = false,
		RobuxProductId = 3709828724,
		Mutation = "Golden",
	},

	--------------------- [[[ STICK STANDS ]]] ---------------------
	{
		Id = "WoodenStickStand",
		Name = "Wooden Stick Stand",
		Category = "StickStands",
		Cost = 1_000,
		Description = "Where the magic starts! Load a stick with ingredients to make a skewer",
		Icon = "rbxassetid://78114165041195",
		TextColor = Color3.fromRGB(200, 150, 90),
		StrokeColor = Color3.fromRGB(58, 43, 25),
		Rarity = "Common",
		Restockable = true,
		RestockChance = 100,
		RestockAmount = NumberRange.new(3, 5),
		RobuxProductId = 3710074872,
	},

	--------------------- [[[ HUTS ]]] ---------------------
	{
		Id = "RepairedHut",
		Name = "Worker Hut",
		Category = "Huts",
		-- The repair hands over the first; more are sold for Gems by Config.CosmeticShop, never the Grill & Stand Shop
		Cost = 0,
		Description = "A new home for 3 more Workers",
		Icon = "rbxassetid://89187948293861",
		TextColor = Color3.fromRGB(200, 150, 90),
		StrokeColor = Color3.fromRGB(58, 43, 25),
		Rarity = "Legendary",
		Restockable = false,
	},

	--------------------- [[[ COSMETICS ]]] ---------------------
	-- Purely visual, so they need no code. Sold for Gems by Config.CosmeticShop, which owns their prices and sets their Rarity by tier; Cost 0 and Restockable false keep them out of the Grill & Stand Shop
	{
		Id = "SmallDirtPath",
		Name = "Small Dirt Path",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A little patch of packed dirt",
		Icon = "rbxassetid://103180626376847",
		TextColor = DIRT_TEXT_COLOR,
		StrokeColor = DIRT_STROKE_COLOR,
		Rarity = "Common",
		Restockable = false,
		Flat = true,
	},

	{
		Id = "MediumDirtPath",
		Name = "Medium Dirt Path",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A trampled trail for hungry Customers",
		Icon = "rbxassetid://73017611534440",
		TextColor = DIRT_TEXT_COLOR,
		StrokeColor = DIRT_STROKE_COLOR,
		Rarity = "Common",
		Restockable = false,
		Flat = true,
	},

	{
		Id = "LongDirtPath",
		Name = "Long Dirt Path",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A long dirt trail straight to your BBQ",
		Icon = "rbxassetid://116742271675853",
		TextColor = DIRT_TEXT_COLOR,
		StrokeColor = DIRT_STROKE_COLOR,
		Rarity = "Common",
		Restockable = false,
		Flat = true,
	},

	{
		Id = "LargeDirtPath",
		Name = "Large Dirt Path",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A wide dirt clearing for a busy stall",
		Icon = "rbxassetid://77082595756760",
		TextColor = DIRT_TEXT_COLOR,
		StrokeColor = DIRT_STROKE_COLOR,
		Rarity = "Common",
		Restockable = false,
		Flat = true,
	},

	{
		Id = "BigDirtPath",
		Name = "Big Dirt Path",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A whole yard of packed dirt",
		Icon = "rbxassetid://127255183244815",
		TextColor = DIRT_TEXT_COLOR,
		StrokeColor = DIRT_STROKE_COLOR,
		Rarity = "Common",
		Restockable = false,
		Flat = true,
	},

	{
		Id = "SmallStonePath",
		Name = "Small Stone Path",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A few stepping stones to get you started",
		Icon = "rbxassetid://89998486066193",
		TextColor = STONE_TEXT_COLOR,
		StrokeColor = STONE_STROKE_COLOR,
		Rarity = "Uncommon",
		Restockable = false,
		Flat = true,
	},

	{
		Id = "MediumStonePath",
		Name = "Medium Stone Path",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A neat stone path, a step up from dirt",
		Icon = "rbxassetid://80696179519246",
		TextColor = STONE_TEXT_COLOR,
		StrokeColor = STONE_STROKE_COLOR,
		Rarity = "Uncommon",
		Restockable = false,
		Flat = true,
	},

	{
		Id = "LongStonePath",
		Name = "Long Stone Path",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A long stone walkway to show Customers the way",
		Icon = "rbxassetid://110710470261099",
		TextColor = STONE_TEXT_COLOR,
		StrokeColor = STONE_STROKE_COLOR,
		Rarity = "Uncommon",
		Restockable = false,
		Flat = true,
	},

	{
		Id = "LargeStonePath",
		Name = "Large Stone Path",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A wide stone patio for your stall",
		Icon = "rbxassetid://132575437449032",
		TextColor = STONE_TEXT_COLOR,
		StrokeColor = STONE_STROKE_COLOR,
		Rarity = "Uncommon",
		Restockable = false,
		Flat = true,
	},

	{
		Id = "BigStonePath",
		Name = "Big Stone Path",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A grand stone plaza fit for a BBQ empire",
		Icon = "rbxassetid://98938983190338",
		TextColor = STONE_TEXT_COLOR,
		StrokeColor = STONE_STROKE_COLOR,
		Rarity = "Uncommon",
		Restockable = false,
		Flat = true,
	},

	{
		Id = "SmallFence",
		Name = "Small Fence",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A short bit of fence to keep your BBQ spot tidy",
		Icon = "rbxassetid://127261560956402",
		TextColor = WOOD_TEXT_COLOR,
		StrokeColor = WOOD_STROKE_COLOR,
		Rarity = "Common",
		Restockable = false,
	},

	{
		Id = "MediumFence",
		Name = "Medium Fence",
		Category = "Cosmetics",
		Cost = 0,
		Description = "Fence off your grill zone in style",
		Icon = "rbxassetid://132594489918568",
		TextColor = WOOD_TEXT_COLOR,
		StrokeColor = WOOD_STROKE_COLOR,
		Rarity = "Common",
		Restockable = false,
	},

	{
		Id = "LongFence",
		Name = "Long Fence",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A long run of fence to wall in your whole base",
		Icon = "rbxassetid://96765050317165",
		TextColor = WOOD_TEXT_COLOR,
		StrokeColor = WOOD_STROKE_COLOR,
		Rarity = "Common",
		Restockable = false,
	},

	{
		Id = "HangingLight",
		Name = "Hanging Light",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A warm glow for late night grilling",
		Icon = "rbxassetid://100423825605708",
		TextColor = Color3.fromRGB(255, 215, 110),
		StrokeColor = Color3.fromRGB(90, 70, 20),
		Rarity = "Uncommon",
		Restockable = false,
	},

	{
		Id = "PicnicParasol",
		Name = "Picnic Parasol",
		Category = "Cosmetics",
		Cost = 0,
		Description = "Shade for your Customers on a sunny day",
		Icon = "rbxassetid://108610278064467",
		TextColor = Color3.fromRGB(255, 120, 120),
		StrokeColor = Color3.fromRGB(80, 30, 30),
		Rarity = "Uncommon",
		Restockable = false,
	},

	{
		Id = "MediumCanopy",
		Name = "Medium Canopy",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A cozy roof for your Customers to dine under",
		Icon = "rbxassetid://108610278064467",
		TextColor = Color3.fromRGB(120, 200, 255),
		StrokeColor = Color3.fromRGB(25, 60, 90),
		Rarity = "Rare",
		Restockable = false,
	},

	{
		Id = "LargeCanopy",
		Name = "Large Canopy",
		Category = "Cosmetics",
		Cost = 0,
		Description = "A big roof for a whole dining area",
		Icon = "rbxassetid://126195896762884",
		TextColor = Color3.fromRGB(120, 200, 255),
		StrokeColor = Color3.fromRGB(25, 60, 90),
		Rarity = "Rare",
		Restockable = false,
	},

	--------------------- [[[ TABLES ]]] ---------------------
	-- Where custom order customers sit to wait and eat; more seats bring them faster. Sold for Gems by Config.CosmeticShop like the cosmetics, see docs/balance.md
	{
		Id = "SmallWoodenTable",
		Name = "Small Wooden Table",
		Category = "Tables",
		Cost = 0,
		Description = "Seats 2 Customers! Tables bring custom orders in faster, and seated Customers tip more Gems",
		Icon = "rbxassetid://137472177697700",
		TextColor = WOOD_TEXT_COLOR,
		StrokeColor = WOOD_STROKE_COLOR,
		Rarity = "Rare",
		Restockable = false,
	},

	{
		Id = "MediumWoodenTable",
		Name = "Medium Wooden Table",
		Category = "Tables",
		Cost = 0,
		Description = "Seats 4 Customers! Tables bring custom orders in faster, and seated Customers tip more Gems",
		Icon = "rbxassetid://137472177697700",
		TextColor = WOOD_TEXT_COLOR,
		StrokeColor = WOOD_STROKE_COLOR,
		Rarity = "Rare",
		Restockable = false,
	},

	{
		Id = "LargeWoodenTable",
		Name = "Large Wooden Table",
		Category = "Tables",
		Cost = 0,
		Description = "Seats 6 Customers! Tables bring custom orders in faster, and seated Customers tip more Gems",
		Icon = "rbxassetid://78634151113048",
		TextColor = WOOD_TEXT_COLOR,
		StrokeColor = WOOD_STROKE_COLOR,
		Rarity = "Rare",
		Restockable = false,
	},

	{
		Id = "CircularTable",
		Name = "Circular Table",
		Category = "Tables",
		Cost = 0,
		Description = "Seats 3 Customers! Tables bring custom orders in faster, and seated Customers tip more Gems",
		Icon = "rbxassetid://127578690612337",
		TextColor = WOOD_TEXT_COLOR,
		StrokeColor = WOOD_STROKE_COLOR,
		Rarity = "Rare",
		Restockable = false,
	},

	{
		Id = "FancyTable",
		Name = "Fancy Table",
		Category = "Tables",
		Cost = 0,
		Description = `Seats 2 Customers and attracts <font color="{VALUE_COLOR}">RICH</font> Customers, who pay more and tip bigger`,
		Icon = "rbxassetid://135077897518284",
		TextColor = Color3.fromRGB(200, 140, 255),
		StrokeColor = Color3.fromRGB(60, 30, 90),
		Rarity = "Epic",
		Restockable = false,
		RichChanceBonus = 15,
	},

	{
		Id = "GoldenTable",
		Name = "Golden Table",
		Category = "Tables",
		Cost = 0,
		Description = `Seats 2 Customers, and every order served here pays <font color="{VALUE_COLOR}">+20%</font>`,
		Icon = "rbxassetid://121029933298597",
		TextColor = Color3.fromRGB(255, 205, 65),
		StrokeColor = Color3.fromRGB(90, 70, 15),
		Rarity = "Epic",
		Restockable = false,
		CustomerPayoutMultiplier = 1.2,
	},
}

-- Made by the base rather than authored, so adding a base needs nothing done to it
Structures.FOLDER_NAME = "Structures"

-- Studs per grid cell. A coarser grid is easier to place onto and blockier about what fits.
Structures.CELL_SIZE = 1

-- How far above its cell a fresh structure appears before springing down; see docs/balance.md
Structures.PLACE_DROP_HEIGHT = 6

-- How long the server waits before settling its own copy, the drop being the client's to play
Structures.PLACE_SETTLE_TIME = 3

-- The attributes every placed copy wears; type, cells and rotation let a client work out whether a spot is free
Structures.UID_ATTRIBUTE = "Uid"
Structures.OWNER_ATTRIBUTE = "OwnerUserId"

-- Which model this is, where the tag says only the kind. On the model, since data only reaches its owner
Structures.TYPE_ATTRIBUTE = "StructureType"

Structures.CELL_X_ATTRIBUTE = "CellX"
Structures.CELL_Z_ATTRIBUTE = "CellZ"
Structures.ROTATION_ATTRIBUTE = "Rotation"

-- Authored as direct children of a structure template, named here so measurer and reader can't drift
Structures.HITBOX_NAME = "Hitbox"

-- An optional model of parts players walk through rather than bump into, like a canopy
Structures.ROOF_NAME = "Roof"

-- A table's folder of Seats, each one a customer's place at it
Structures.SEATS_NAME = "Seats"

-- Slack in cells, so a leg flush with a cell edge doesn't spill into the next cell off float noise
local LEG_EDGE_SLACK = 1e-3

-- Every Hitbox directly under a structure. Several are legs: each blocks its own cells, and their combined box is the footprint.
function Structures.GetHitboxes(instance: Instance): { BasePart }
	local hitboxes = {}

	for _, child in instance:GetChildren() do
		if child.Name == Structures.HITBOX_NAME and child:IsA("BasePart") then
			table.insert(hitboxes, child)
		end
	end

	return hitboxes
end

-- A part's centre and half-size along `frame`'s axes, so a part turned inside the model still measures right.
local function getExtentsIn(frame: CFrame, part: BasePart): (Vector3, Vector3)
	local relative = frame:ToObjectSpace(part.CFrame)
	local size = part.Size

	local half = Vector3.new(
		math.abs(relative.XVector.X) * size.X + math.abs(relative.YVector.X) * size.Y + math.abs(relative.ZVector.X) * size.Z,
		math.abs(relative.XVector.Y) * size.X + math.abs(relative.YVector.Y) * size.Y + math.abs(relative.ZVector.Y) * size.Z,
		math.abs(relative.XVector.Z) * size.X + math.abs(relative.YVector.Z) * size.Y + math.abs(relative.ZVector.Z) * size.Z
	) / 2

	return relative.Position, half
end

-- The box a structure is measured against: its Hitbox, the box around all of them, else its bounding box. See docs/balance.md.
local function getStructureBounds(instance: Instance): (CFrame, Vector3)
	local hitboxes = Structures.GetHitboxes(instance)

	if #hitboxes == 1 then
		return hitboxes[1].CFrame, hitboxes[1].Size
	elseif #hitboxes > 1 then
		-- Along the first leg's axes, the others being authored square to it
		local frame = hitboxes[1].CFrame
		local minCorner = Vector3.one * math.huge
		local maxCorner = -Vector3.one * math.huge

		for _, hitbox in hitboxes do
			local centre, half = getExtentsIn(frame, hitbox)
			minCorner = minCorner:Min(centre - half)
			maxCorner = maxCorner:Max(centre + half)
		end

		return frame * CFrame.new((minCorner + maxCorner) / 2), maxCorner - minCorner
	end

	if instance:IsA("Model") then
		return instance:GetBoundingBox()
	elseif instance:IsA("BasePart") then
		return instance.CFrame, instance.Size
	end

	return instance:GetPivot(), Vector3.zero
end

-- The cells a leg touches, from the unturned footprint's min corner. Nil for one wholly outside it.
local function getLegRect(boundsCFrame: CFrame, leg: BasePart, footprintX: number, footprintZ: number): GridUtil.Rect?
	local centre, half = getExtentsIn(boundsCFrame, leg)

	local centreX = centre.X / Structures.CELL_SIZE + footprintX / 2
	local centreZ = centre.Z / Structures.CELL_SIZE + footprintZ / 2
	local cellsX = half.X / Structures.CELL_SIZE
	local cellsZ = half.Z / Structures.CELL_SIZE

	-- Outward, so any cell a leg reaches into is blocked
	local rect = {
		MinX = math.max(0, math.floor(centreX - cellsX + LEG_EDGE_SLACK)),
		MinZ = math.max(0, math.floor(centreZ - cellsZ + LEG_EDGE_SLACK)),
		MaxX = math.min(footprintX, math.ceil(centreX + cellsX - LEG_EDGE_SLACK)),
		MaxZ = math.min(footprintZ, math.ceil(centreZ + cellsZ - LEG_EDGE_SLACK)),
	}

	if rect.MaxX <= rect.MinX or rect.MaxZ <= rect.MinZ then
		return nil
	end

	return rect
end

-- Turns an unturned footprint's rect `rotation` quarter-turns, the same way GetPlacementPivot turns the model.
local function rotateRect(rect: GridUtil.Rect, footprintX: number, footprintZ: number, rotation: number): GridUtil.Rect
	if rotation == 1 then
		return { MinX = rect.MinZ, MinZ = footprintX - rect.MaxX, MaxX = rect.MaxZ, MaxZ = footprintX - rect.MinX }
	elseif rotation == 2 then
		return {
			MinX = footprintX - rect.MaxX,
			MinZ = footprintZ - rect.MaxZ,
			MaxX = footprintX - rect.MinX,
			MaxZ = footprintZ - rect.MinZ,
		}
	elseif rotation == 3 then
		return { MinX = footprintZ - rect.MaxZ, MinZ = rect.MinX, MaxX = footprintZ - rect.MinZ, MaxZ = rect.MaxX }
	end

	return rect
end

-- Resolves each entry's template and cell footprint once. Snaps to the nearest whole cell, not up.
for index = #Structures.Data, 1, -1 do
	local structure = Structures.Data[index]
	local folder = StructuresFolder:FindFirstChild(structure.Category)
	local model = folder and folder:FindFirstChild(structure.Id)

	if not model then
		warn(`Structure {structure.Id} has no model in Assets.Structures.{structure.Category}, it can't be built`)
		table.remove(Structures.Data, index)
		continue
	end

	structure.Model = model

	local seats = model:FindFirstChild(Structures.SEATS_NAME)
	structure.SeatCount = if seats then #seats:GetChildren() else 0

	local hitboxes = Structures.GetHitboxes(model)

	if #hitboxes == 0 then
		warn(`Structure {structure.Id} has no {Structures.HITBOX_NAME} part, falling back to its bounding box`)
	end

	-- The unrounded dimensions, for anything measuring against the world rather than the grid
	local boundsCFrame, size = getStructureBounds(model)

	structure.SizeX = size.X
	structure.SizeZ = size.Z

	local authored = structure.Footprint
	if authored then
		structure.FootprintX, structure.FootprintZ = authored.X, authored.Z
	else
		structure.FootprintX = math.max(1, math.round(structure.SizeX / Structures.CELL_SIZE))
		structure.FootprintZ = math.max(1, math.round(structure.SizeZ / Structures.CELL_SIZE))
	end

	local rects = {}

	-- Legs block only their own cells, so the space between them stays buildable
	if #hitboxes > 1 then
		for _, leg in hitboxes do
			local rect = getLegRect(boundsCFrame, leg, structure.FootprintX, structure.FootprintZ)
			if rect then
				table.insert(rects, rect)
			end
		end
	end

	if #rects == 0 then
		rects = { { MinX = 0, MinZ = 0, MaxX = structure.FootprintX, MaxZ = structure.FootprintZ } }
	end

	structure.Blocks = {}

	for rotation = 0, 3 do
		local rotated = {}

		for _, rect in rects do
			table.insert(rotated, rotateRect(rect, structure.FootprintX, structure.FootprintZ, rotation))
		end

		structure.Blocks[rotation] = rotated
	end
end

table.freeze(Structures.Data)

function Structures.GetStructureFromId(id: string): Structure?
	for _, structure in Structures.Data do
		if structure.Id == id then
			return structure
		end
	end

	return nil
end

-- What the Grill & Stand Shop can stock, in config order, which is also the roll's draw sequence.
function Structures.GetRestockableStructures(): { Structure }
	local restockable = {}

	for _, structure in Structures.Data do
		if structure.Restockable then
			table.insert(restockable, structure)
		end
	end

	return restockable
end

-- Whether a type is a given kind -- what the managers key off, since an id off a remote can be anything.
function Structures.IsCategory(typeId: string, category: string): boolean
	local structure = Structures.GetStructureFromId(typeId)
	return structure ~= nil and structure.Category == category
end

-- Cells taken once turned, which is what actually gets reserved. A quarter-turn swaps the two.
function Structures.GetFootprint(structure: Structure, rotation: number): (number, number)
	return GridUtil.RotateFootprint(structure.FootprintX, structure.FootprintZ, rotation)
end

-- The box in studs, turned with it: the unrounded counterpart to GetFootprint, for world measurements.
function Structures.GetSize(structure: Structure, rotation: number): (number, number)
	return GridUtil.RotateFootprint(structure.SizeX, structure.SizeZ, rotation)
end

-- Whether two blocks share a cell. Plain integer AABB, and the whole collision model.
function Structures.BlocksOverlap(
	aX: number,
	aZ: number,
	aFootprintX: number,
	aFootprintZ: number,
	bX: number,
	bZ: number,
	bFootprintX: number,
	bFootprintZ: number
): boolean
	return aX < bX + bFootprintX and bX < aX + aFootprintX and aZ < bZ + bFootprintZ and bZ < aZ + aFootprintZ
end

-- Whether two placed structures block a shared cell, block by block. Flat pieces only ever meet other Flat pieces.
function Structures.Overlaps(a: PlacedStructure, b: PlacedStructure): boolean
	local structureA = Structures.GetStructureFromId(a.Type)
	local structureB = Structures.GetStructureFromId(b.Type)

	-- Dropped at load, so older data can name it; it has no model either, so it blocks nothing
	if not structureA or not structureB then
		return false
	end

	if (structureA.Flat == true) ~= (structureB.Flat == true) then
		return false
	end

	for _, rectA in structureA.Blocks[a.Rotation] do
		for _, rectB in structureB.Blocks[b.Rotation] do
			if
				Structures.BlocksOverlap(
					a.CellX + rectA.MinX,
					a.CellZ + rectA.MinZ,
					rectA.MaxX - rectA.MinX,
					rectA.MaxZ - rectA.MinZ,
					b.CellX + rectB.MinX,
					b.CellZ + rectB.MinZ,
					rectB.MaxX - rectB.MinX,
					rectB.MaxZ - rectB.MinZ
				)
			then
				return true
			end
		end
	end

	return false
end

-- The pivot seating `model` centred and flush on the block, turned `rotation` quarter-turns, by its box.
function Structures.GetPlacementPivot(model: Instance, surfaceCFrame: CFrame, rotation: number): CFrame
	local boundsCFrame, boundsSize = getStructureBounds(model)

	-- Solve for the pivot whose resulting box centre lands on the target (box = pivot * offset)
	local pivotToBounds = model:GetPivot():ToObjectSpace(boundsCFrame)
	local targetBounds = surfaceCFrame
		* CFrame.Angles(0, math.rad(rotation * 90), 0)
		* CFrame.new(0, boundsSize.Y / 2, 0)

	return targetBounds * pivotToBounds:Inverse()
end

return Structures
