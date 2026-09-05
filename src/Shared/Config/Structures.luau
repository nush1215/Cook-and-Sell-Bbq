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
	Description: string, -- the shop row's line under the name. May carry RichText <font> markup (the row
	-- renders with RichText on). Use the colour constants below rather than a fresh hex.
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
	Footprint: Footprint?, -- grid cells occupied; derived from the model's Hitbox when absent
	Model: Model, -- not authored below, back-filled from Assets.Structures
	FootprintX: number, -- not authored below, resolved once at load (see the back-fill loop)
	FootprintZ: number,
	SizeX: number, -- likewise; the template's Hitbox dimensions in studs, where the footprint above is
	SizeZ: number, -- the same thing rounded to whole cells
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
}

-- Made by the base rather than authored, so adding a base needs nothing done to it
Structures.FOLDER_NAME = "Structures"

-- Studs per grid cell. A coarser grid is easier to place onto and blockier about what fits.
Structures.CELL_SIZE = 4

-- How far above its cell a fresh structure appears before springing down; see docs/balance.md
Structures.PLACE_DROP_HEIGHT = 6

-- How long the server waits before settling its own copy, the drop being the client's to play
Structures.PLACE_SETTLE_TIME = 3

-- The attributes every placed copy wears; the cell four let a client work out whether a spot is free
Structures.UID_ATTRIBUTE = "Uid"
Structures.OWNER_ATTRIBUTE = "OwnerUserId"

-- Which model this is, where the tag says only the kind. On the model, since data only reaches its owner
Structures.TYPE_ATTRIBUTE = "StructureType"

Structures.CELL_X_ATTRIBUTE = "CellX"
Structures.CELL_Z_ATTRIBUTE = "CellZ"
Structures.FOOTPRINT_X_ATTRIBUTE = "FootprintX"
Structures.FOOTPRINT_Z_ATTRIBUTE = "FootprintZ"

-- Authored as a direct child of a structure template, named here so measurer and reader can't drift
Structures.HITBOX_NAME = "Hitbox"

-- The box a structure is measured against: its Hitbox, else its bounding box. See docs/balance.md.
local function getStructureBounds(instance: Instance): (CFrame, Vector3)
	local hitbox = instance:FindFirstChild(Structures.HITBOX_NAME)
	if hitbox and hitbox:IsA("BasePart") then
		return hitbox.CFrame, hitbox.Size
	end

	if instance:IsA("Model") then
		return instance:GetBoundingBox()
	elseif instance:IsA("BasePart") then
		return instance.CFrame, instance.Size
	end

	return instance:GetPivot(), Vector3.zero
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

	if not model:FindFirstChild(Structures.HITBOX_NAME) then
		warn(`Structure {structure.Id} has no {Structures.HITBOX_NAME} part, falling back to its bounding box`)
	end

	-- The unrounded dimensions, for anything measuring against the world rather than the grid
	local _, size = getStructureBounds(model)

	structure.SizeX = size.X
	structure.SizeZ = size.Z

	local authored = structure.Footprint
	if authored then
		structure.FootprintX, structure.FootprintZ = authored.X, authored.Z
	else
		structure.FootprintX = math.max(1, math.round(structure.SizeX / Structures.CELL_SIZE))
		structure.FootprintZ = math.max(1, math.round(structure.SizeZ / Structures.CELL_SIZE))
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

-- Whether a placed structure blocks these cells, its footprint derived from type and rotation.
function Structures.Overlaps(
	placed: PlacedStructure,
	cellX: number,
	cellZ: number,
	footprintX: number,
	footprintZ: number
): boolean
	local structure = Structures.GetStructureFromId(placed.Type)

	-- Dropped at load, so older data can name it; it has no model either, so it blocks nothing
	if not structure then
		return false
	end

	local placedX, placedZ = Structures.GetFootprint(structure, placed.Rotation)

	return Structures.BlocksOverlap(cellX, cellZ, footprintX, footprintZ, placed.CellX, placed.CellZ, placedX, placedZ)
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
