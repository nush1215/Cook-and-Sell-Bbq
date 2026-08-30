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
	-- Kept here rather than in Mutations so the stamp is read off the grill the cook happened on.
	MutationChance: number?, -- percent 0-100 that Mutation is stamped, or nil to stamp every time -- what
	-- separates a grill whose mutation IS the grill from one where it's an occasional bonus. Rolled
	-- server-side as the cook settles, so it's neither predictable nor forgeable.
	CookSpeed: number?, -- how many times faster this grill cooks, or nil for the plain rate. Divides the
	-- whole bar rather than one band (GrillerManager:StartCooking), so speed is a trade: the perfect
	-- window shrinks with it. The burn past the bar doesn't scale -- it's wall-clock seconds in CookStates.
	CookEffect: string?, -- the folder under Assets.Particles.Cooking played on the grate while cooking, or
	-- nil for the shared Default. Named rather than matched off the Id, so two grills can share one set.
	CookSound: string?, -- a looped sound on the grate while cooking, layered ON TOP of the shared sizzle
	-- rather than replacing it. Resolved by name out of SoundService, and rides the same fade as the sizzle.
	CookInstability: number?, -- how far this grill's cook rate swings either side of 1, or nil for steady.
	-- Costs no cook time -- the swing integrates out and the bar fills on the second it always would (see
	-- CookStates.GetBarElapsed) -- so it takes away the ability to TIME the window, not to reach it. Held
	-- under CookStates.MAX_INSTABILITY: at 1 the bar stalls dead, past it it runs backwards.
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

-- Borrowed from the Stick Shop rather than rechosen, so a Grill & Stand row and a Stick Shop row one tab
-- over read as the same kind of line.
local SPEED_COLOR = "#55ff00"
local VALUE_COLOR = "#ffd400"

-- For the one rung whose line is a warning rather than a boast. The red ShopManager already writes by hand.
local WARNING_COLOR = "#ff7272"

-- Matches the [GOLDEN] / [SHOCKED] tag the player later reads on the BBQ itself. Written out rather than
-- required off Config.Mutations -- it's the same colour the grill carries as its TextColor below.
local GOLDEN_COLOR = "#ffcd41" -- Mutations.Golden.Color
local SHOCKED_COLOR = "#78cdff" -- Mutations.Shocked.Color

--
local Structures = {}

--[[
    The things a player can build on their base. One template per structure under Assets.Structures,
    cloned wherever the player puts it -- so a base's contents are entirely their build rather than a
    level on an unlock ladder (see Config.BaseUnlocks, which still drives the rolling stands).

    Every placed copy wears its *Category* as a CollectionService tag, plus Uid and OwnerUserId
    attributes, and that tag is the whole discovery mechanism on both realms -- so a structure placed
    mid-session wires itself up with nothing having to be told about it. The tag is the category rather
    than the id because managers bind a kind of thing: a second griller is a config entry and a model.

    The Uid keys everything about a placed structure (data.Structures[uid], data.Grillers[uid], ...) and
    is minted once at placement, so it outlives the model being rebuilt on a rejoin.

    Position is stored as a grid cell rather than a pose, because that's what the client sends and the
    server validates -- so data holds exactly what was checked. The cell is the base's, not a plot's, so
    a structure over the seam between two plots is an ordinary block (see Shared.GridUtil).

    IMPORTANT: array order is the Grill & Stand Shop's row order *and* the order its stock roll draws
    through. Every server rolls the same seed, so reordering this reorders what each server stocks.
]]
Structures.Data = {
	--------------------- [[[ GRILLERS ]]] ---------------------
	-- A ladder, cheapest first. A rung buys one of three things: speed, steadiness, or what it stamps on
	-- the result. A grill carrying none of them is the baseline.
	{
		Id = "RustyGrill",
		Name = "Rusty Grill",
		Category = "Grillers",
		Cost = 1_000,
		Description = `All rusted up! The fire keeps flickering, so the bar is <font color="{WARNING_COLOR}">hard to time</font>`,
		Icon = "rbxassetid://108556890656046",
		TextColor = Color3.fromRGB(170, 95, 55),
		StrokeColor = Color3.fromRGB(55, 30, 16),
		Rarity = "Common",
		Restockable = true,
		RestockChance = 90,
		RestockAmount = NumberRange.new(1, 2),
		RobuxProductId = 3710074789,
		-- As fast as an Iron Grill; what it costs is being able to time the window. Cheapest rung, so the
		-- first thing money buys is a grill that behaves.
		CookInstability = 0.5,
	},

	{
		Id = "IronGrill",
		Name = "Iron Grill",
		Category = "Grillers",
		Cost = 2_500,
		Description = "The good ol' trusted grill! Turns your skewers into juicy BBQ",
		Icon = "rbxassetid://118980874997825",
		TextColor = Color3.fromRGB(255, 120, 60),
		StrokeColor = Color3.fromRGB(70, 30, 12),
		Rarity = "Common",
		Restockable = true,
		RestockChance = 75,
		RestockAmount = NumberRange.new(2, 4),
		RobuxProductId = 3710074770,
	},

	{
		Id = "GasGrill",
		Name = "Gas Grill",
		Category = "Grillers",
		Cost = 25_000,
		Description = `Now we're in the big leagues! <font color="{SPEED_COLOR}">25% faster</font> cooking`,
		Icon = "rbxassetid://139507103650602",
		TextColor = Color3.fromRGB(90, 170, 255),
		StrokeColor = Color3.fromRGB(20, 50, 90),
		Rarity = "Rare",
		Restockable = true,
		RestockChance = 50,
		RestockAmount = NumberRange.new(1, 3),
		RobuxProductId = 3710074809,
		CookSpeed = 1.25,
	},

	{
		Id = "SolarGrill",
		Name = "Solar Grill",
		Category = "Grillers",
		Cost = 100_000,
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
		-- Deliberately below the Solar Grill's 1.5 -- this rung isn't bought for pace.
		CookSpeed = 1.25,
		-- A chance rather than the Golden Grill's promise, so it's priced as the gamble it is, and Shocked
		-- is worth less than Golden to match.
		Mutation = "Shocked",
		MutationChance = 20,
		-- Arcs and smokes instead of the shared sizzle, and hums over the top of it.
		CookEffect = "Electric",
		CookSound = "ElectricCooking",
	},

	{
		Id = "GoldenGrill",
		Name = "Golden Grill",
		Category = "Grillers",
		-- Never charged: Restockable = false keeps it out of the shop entirely, so its dev product is the
		-- only way to get one.
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

-- Made by the base rather than authored, so adding a base to the place file needs nothing done to it.
Structures.FOLDER_NAME = "Structures"

-- Studs per grid cell. A coarser grid is easier to place onto and blockier about what fits.
Structures.CELL_SIZE = 4

-- How far above its cell a fresh structure appears before springing down. From above at full size, the
-- opposite of a bought unlock rising out of the ground (see BaseUnlocks.LAYOUT_RISE); the spring is
-- shared, so only the start differs. Higher = a longer fall.
Structures.PLACE_DROP_HEIGHT = 6

-- How long the server waits before settling its own copy and dropping the spawn flash. The drop is the
-- client's to play and the server has no signal for when the spring landed, so it waits it out and stops
-- lying about where the structure is -- which is also what makes a late-arriving client spring from the
-- settled pose (a no-op) rather than replay the drop on a structure built minutes ago.
Structures.PLACE_SETTLE_TIME = 3

-- The attributes every placed copy wears, named here so writers and readers can't drift apart. The cell
-- four let a client work out whether a spot is free: they're on models, which replicate to everyone,
-- unlike the owner's data.
Structures.UID_ATTRIBUTE = "Uid"
Structures.OWNER_ATTRIBUTE = "OwnerUserId"

-- Which model of structure this is, where the tag says only which kind -- for what differs between two
-- grillers rather than between a griller and a stand. On the model, since data only reaches its owner
-- and a visitor has to render someone else's grill right too.
Structures.TYPE_ATTRIBUTE = "StructureType"

Structures.CELL_X_ATTRIBUTE = "CellX"
Structures.CELL_Z_ATTRIBUTE = "CellZ"
Structures.FOOTPRINT_X_ATTRIBUTE = "FootprintX"
Structures.FOOTPRINT_Z_ATTRIBUTE = "FootprintZ"

-- Authored as a direct child of a structure template. Named here so what measures it and what reads it
-- can't drift apart.
Structures.HITBOX_NAME = "Hitbox"

-- The box a structure is measured against: its Hitbox, else the model's bounding box. A Hitbox is how a
-- model *states* what it occupies rather than having it guessed, which is what lets a chimney hang off
-- the side without reserving a phantom cell. A direct child, not a descendant search -- a griller has
-- models inside it and shouldn't inherit one of their hitboxes.
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

-- Pulls each entry's template out of Assets.Structures[Category] and resolves its cell footprint once --
-- measuring per placement would be paid on every frame the ghost moves. A structure whose model is
-- missing is dropped, so it can't be placed and then fail to render; one missing only its Hitbox is kept
-- and measured the old way.
--
-- The footprint snaps to the NEAREST whole cell, not rounded up: rounding up reserves a phantom cell for
-- a slightly-oversized box, which makes two flush neighbours read as overlapping.
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

	-- The unrounded dimensions, kept alongside the whole-cell footprint below: what anything measuring a
	-- structure against the world rather than the grid wants (see BuildController's touch aim).
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

-- The structures the Grill & Stand Shop can stock and sell, in config order -- one source of truth for
-- the server's stock roll and the client's rows. Config order is the roll's draw sequence.
function Structures.GetRestockableStructures(): { Structure }
	local restockable = {}

	for _, structure in Structures.Data do
		if structure.Restockable then
			table.insert(restockable, structure)
		end
	end

	return restockable
end

-- Whether a structure type is a given kind. What the managers key off, since they own a category rather
-- than one model of it, and an id off a remote can be anything.
function Structures.IsCategory(typeId: string, category: string): boolean
	local structure = Structures.GetStructureFromId(typeId)
	return structure ~= nil and structure.Category == category
end

-- How many cells the structure takes up once it's been turned, which is what actually gets reserved.
-- A quarter-turn swaps the two.
function Structures.GetFootprint(structure: Structure, rotation: number): (number, number)
	return GridUtil.RotateFootprint(structure.FootprintX, structure.FootprintZ, rotation)
end

-- The structure's box in studs, turned with it -- the unrounded counterpart to GetFootprint above,
-- and going through the same swap so there's one idea of what a quarter-turn does to a pair of axes.
-- For measuring a structure against the world; the footprint is for measuring it against the grid.
function Structures.GetSize(structure: Structure, rotation: number): (number, number)
	return GridUtil.RotateFootprint(structure.SizeX, structure.SizeZ, rotation)
end

-- Whether two blocks share any cell. Plain integer AABB overlap, and the whole collision model: nothing
-- is ever queried against the world, so only the cells a structure claimed matter.
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

-- Whether an already-placed structure blocks a set of cells. Its footprint is derived from type and
-- rotation rather than stored, so data holds only what the player chose and can't disagree with the
-- config about how big a thing is.
function Structures.Overlaps(
	placed: PlacedStructure,
	cellX: number,
	cellZ: number,
	footprintX: number,
	footprintZ: number
): boolean
	local structure = Structures.GetStructureFromId(placed.Type)

	-- Dropped from the config at load, so older data can name it. It has no model in the world either, so
	-- it isn't standing in anyone's way.
	if not structure then
		return false
	end

	local placedX, placedZ = Structures.GetFootprint(structure, placed.Rotation)

	return Structures.BlocksOverlap(cellX, cellZ, footprintX, footprintZ, placed.CellX, placed.CellZ, placedX, placedZ)
end

-- The pivot placing `model` so its bounds box centres on the surface block-centre with its bottom face
-- resting on it, turned `rotation` quarter-turns. By the box rather than the model's own pivot, which may
-- be off to one side -- which is also where a Hitbox earns what a footprint number can't: geometry
-- hanging off one side still sits centred, and something dangling below the base still sits flush.
function Structures.GetPlacementPivot(model: Instance, surfaceCFrame: CFrame, rotation: number): CFrame
	local boundsCFrame, boundsSize = getStructureBounds(model)

	-- Solve for the pivot whose resulting box centre lands on the target (box = pivot * offset).
	local pivotToBounds = model:GetPivot():ToObjectSpace(boundsCFrame)
	local targetBounds = surfaceCFrame
		* CFrame.Angles(0, math.rad(rotation * 90), 0)
		* CFrame.new(0, boundsSize.Y / 2, 0)

	return targetBounds * pivotToBounds:Inverse()
end

return Structures
