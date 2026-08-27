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
	Cost: number, -- what one costs to buy at the Grill & Stand Shop. Not charged for putting one down: a
	-- structure is paid for once, when it's bought, and moves freely between the inventory and the base
	-- after that.
	Description: string, -- the line the shop row shows under the name. May carry RichText <font> markup --
	-- the row's label is rendered with RichText on (see GrillStandShopController:_buildRows) so the number
	-- a rung is bought for can be coloured. Use the constants below rather than a fresh hex.
	Icon: string, -- rbxassetid for this structure's shop icon
	TextColor: Color3, -- colour for this structure's name label in UI
	StrokeColor: Color3, -- the label's stroke, a darker shade of the text colour
	Rarity: string, -- rarity word shown in the shop, keyed into Shared.Colors for its tint
	Restockable: boolean, -- shows in the shop and is eligible for the timed restock roll
	RestockChance: number?, -- percent 0-100 the shop rolls to stock this structure each window (nil if not restockable)
	RestockAmount: NumberRange?, -- how many units a successful roll stocks, min..max (nil if not restockable)
	RobuxProductId: number?, -- Robux dev-product asset id; buying it grants this structure (0 = not sold for Robux yet)
	Mutation: string?, -- a Mutations id this structure stamps onto whatever finishes cooking on it, nil
	-- for a plain one. Kept here rather than in Mutations so a mutating grill is one config entry, and
	-- so the stamp is read off the structure the cook actually happened on (see GrillerManager).
	MutationChance: number?, -- percent 0-100 that Mutation is actually stamped, or nil to stamp it every
	-- time. What separates a grill whose mutation IS the grill -- the Golden one, bought for exactly
	-- that -- from one where it's a bonus that turns up now and then. Rolled server-side as the cook
	-- settles, so it's neither predictable nor forgeable.
	CookSpeed: number?, -- how many times faster than normal this grill cooks, or nil for the plain rate.
	-- Divides the whole bar rather than any one band of it (see GrillerManager:StartCooking), so a fast
	-- grill is a real trade and not a free upgrade: the throughput goes up, but the perfect window is
	-- that many times shorter in real seconds and there's proportionally less time to react in it. What
	-- doesn't scale is the burn past the end of the bar -- that's wall-clock seconds in CookStates by
	-- design, so every grill gives the same time to notice a skewer that's filled.
	CookEffect: string?, -- the folder under Assets.Particles.Cooking whose emitters play on this
	-- structure's grate while it's cooking, or nil to use the shared Default set. Named here rather than
	-- matched off the Id so the effect and the model aren't forced to share a name -- an Electric Grill
	-- can burn "Electric" -- and so two grills can share one set without a duplicate folder.
	CookSound: string?, -- a looped sound played on this structure's grate while it's cooking, layered ON
	-- TOP of the shared sizzle rather than replacing it -- so a grill with one sounds like a grill plus
	-- whatever it is. Resolved by name out of SoundService, and it rides the same fade as the sizzle so
	-- the two ramp up and back out together instead of one cracking in under the other.
	CookInstability: number?, -- how far this grill's cook rate swings either side of 1 as the bar runs,
	-- or nil for a steady one. 0.5 is a bar that runs anywhere from half speed to half again, surging
	-- and stalling its way up. It costs no cook time at all -- the swing integrates out and the bar
	-- still fills on the second it always would (see CookStates.GetBarElapsed) -- so what an unstable
	-- grill takes off the player is the ability to TIME the window, not the ability to reach it. Held
	-- under CookStates.MAX_INSTABILITY: at 1 the bar stalls dead, and past it it runs backwards.
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

-- The colours a Description picks a word out in. The first two are the Stick Shop's own, borrowed rather
-- than rechosen -- green for the number a rung is bought for, gold for what the BBQ is worth -- so a
-- Grill & Stand row and a Stick Shop row one tab over read as the same kind of line.
local SPEED_COLOR = "#55ff00"
local VALUE_COLOR = "#ffd400"

-- For the one rung whose line is a warning rather than a boast. The red ShopManager already writes by hand.
local WARNING_COLOR = "#ff7272"

-- Each mutation in its own colour, so the word in the description matches the [GOLDEN] / [SHOCKED] tag the
-- player later reads on the BBQ itself. Written out rather than required off Config.Mutations: it's the
-- same colour the grill already carries as its TextColor a few lines under each description.
local GOLDEN_COLOR = "#ffcd41" -- Mutations.Golden.Color
local SHOCKED_COLOR = "#78cdff" -- Mutations.Shocked.Color

--
local Structures = {}

--[[
    The things a player can build on their base.

    A structure isn't authored into the place file per base -- there's one template under
    Assets.Structures and the base clones it wherever the player puts it, so how many of a thing a base
    has and where they sit is entirely the player's build rather than a level on an unlock ladder (see
    Config.BaseUnlocks, which still drives the rolling stands).

    Every placed copy carries the structure's *Category* as a CollectionService tag, plus a Uid and an
    OwnerUserId attribute, and that tag is the whole discovery mechanism: GrillerManager and
    StickStandManager on the server, and their controllers on the client, bind on the tag's added and
    removed signals rather than walking a folder of numbered slots. So a structure placed mid-session
    wires itself up on both sides with nothing having to be told about it.

    The tag is the category and not the id on purpose. A category is a kind of thing -- everything in
    Grillers is a griller and cooks the same way -- while the id names one particular model of it. So a
    second griller added later is a config entry and a model in the same folder, and GrillerManager
    picks it up without being told: it binds the kind, not the model.

    The Uid is what everything about a placed structure is keyed by -- data.Structures[uid] is the
    structure itself, data.Grillers[uid] / data.StickStands[uid] whatever is sitting on it -- and it's
    minted once, at placement, so it outlives the model being rebuilt on a rejoin.

    Where a structure sits is stored as a grid cell rather than a pose, because that's what the client
    actually sends and the server actually validates -- so data holds exactly what was checked, and
    occupancy comes back losslessly on a rejoin. The cell is the base's, not any one plot's (see
    Shared.GridUtil): one lattice runs across the whole base, so a structure standing over the seam
    between two plots is an ordinary block of cells rather than a case anything has to handle.

    Array order is the order the Grill & Stand Shop's rows appear in and, more importantly, the order
    its stock roll draws through (see GrillStandShopManager). Every server rolls the same seed, so the
    draw sequence has to be the same everywhere -- reordering this reorders what each server stocks.
]]
Structures.Data = {
	--------------------- [[[ GRILLERS ]]] ---------------------
	-- The grillers run as a ladder, cheapest first, and the three fields below are the three things a
	-- rung can buy: how fast it cooks, how steady it holds that rate, and what it stamps on the result.
	-- A grill that carries none of them is the baseline the others are measured against.
	{
		Id = "RustyGrill",
		Name = "Rusty Grill",
		Category = "Grillers",
		Cost = 500,
		Description = `All rusted up! The fire keeps flickering, so the bar is <font color="{WARNING_COLOR}">hard to time</font>`,
		Icon = "rbxassetid://108556890656046",
		TextColor = Color3.fromRGB(170, 95, 55),
		StrokeColor = Color3.fromRGB(55, 30, 16),
		Rarity = "Common",
		Restockable = true,
		RestockChance = 100,
		RestockAmount = NumberRange.new(4, 6),
		RobuxProductId = 3710074789,
		-- It cooks a skewer in exactly as long as an Iron Grill does; what it costs is being able to
		-- time the window, since the bar surges and stalls its way there. The cheapest rung on the
		-- ladder, so the first thing money buys is a grill that behaves.
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
		RestockChance = 100,
		RestockAmount = NumberRange.new(2, 4),
		RobuxProductId = 3710074770,
	},

	{
		Id = "GasGrill",
		Name = "Gas Grill",
		Category = "Grillers",
		Cost = 12_000,
		Description = `Now we're in the big leagues! <font color="{SPEED_COLOR}">25% faster</font> cooking`,
		Icon = "rbxassetid://139507103650602",
		TextColor = Color3.fromRGB(90, 170, 255),
		StrokeColor = Color3.fromRGB(20, 50, 90),
		Rarity = "Rare",
		Restockable = true,
		RestockChance = 90,
		RestockAmount = NumberRange.new(2, 3),
		RobuxProductId = 3710074809,
		CookSpeed = 1.25,
	},

	{
		Id = "SolarGrill",
		Name = "Solar Grill",
		Category = "Grillers",
		Cost = 45_000,
		Description = `Harness the power of the sun! <font color="{SPEED_COLOR}">50% faster</font> cooking`,
		Icon = "rbxassetid://75120638448905",
		TextColor = Color3.fromRGB(255, 235, 120),
		StrokeColor = Color3.fromRGB(95, 80, 20),
		Rarity = "Epic",
		Restockable = true,
		RestockChance = 70,
		RestockAmount = NumberRange.new(1, 2),
		RobuxProductId = 3710074824,
		CookSpeed = 1.5,
	},

	{
		Id = "ElectricGrill",
		Name = "Electric Grill",
		Category = "Grillers",
		Cost = 150_000,
		Description = `I like my BBQ a little zappy! <font color="{SPEED_COLOR}">25% faster</font> cooking, and a chance for a <font color="{SHOCKED_COLOR}">Shocked</font> BBQ worth <font color="{VALUE_COLOR}">1.5x</font>`,
		Icon = "rbxassetid://106240207741508",
		TextColor = Color3.fromRGB(120, 205, 255),
		StrokeColor = Color3.fromRGB(25, 65, 95),
		Rarity = "Legendary",
		Restockable = true,
		RestockChance = 50,
		RestockAmount = NumberRange.new(1, 1),
		RobuxProductId = 3710074849,
		-- Deliberately below the Solar Grill's 1.5: this rung isn't bought for pace. The speed is a nudge on
		-- top, and the Shocked chance below is what the price is actually for.
		CookSpeed = 1.25,
		-- Where the Golden Grill below stamps its mutation every time and is bought for exactly that, this
		-- one throws Shocked now and then -- a chance rather than a promise, so it's priced as the gamble
		-- it is, and Shocked is worth less than Golden to match.
		Mutation = "Shocked",
		MutationChance = 20,
		-- Arcs and smokes on the grate instead of the shared sizzle, and hums over the top of it, for as
		-- long as the stove is lit.
		CookEffect = "Electric",
		CookSound = "ElectricCooking",
	},

	{
		Id = "GoldenGrill",
		Name = "Golden Grill",
		Category = "Grillers",
		-- Never charged: Restockable = false keeps it out of the shop's rows and out of
		-- GrillStandShopManager:PurchaseStructure, so its dev product is the only way to get one.
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

-- The folder on a base its placed structures live under. Made by the base rather than authored, so
-- adding a base to the place file needs nothing done to it.
Structures.FOLDER_NAME = "Structures"

-- Studs per grid cell. Placement snaps to this, and it's what a footprint is measured in -- so a
-- coarser grid is both easier to place onto and blockier about what fits. Tunable on its own.
Structures.CELL_SIZE = 4

-- How far above its cell a freshly-placed structure appears before springing down onto it. Building
-- reads as setting something down, so it comes from above at full size -- deliberately the opposite of
-- a bought unlock, which rises up out of the ground and pops to size (see BaseUnlocks.LAYOUT_RISE).
-- The spring itself is shared with those, so it lands with the same weight; only where it starts
-- differs. Higher = a longer fall, since the spring covers whatever distance it's given.
Structures.PLACE_DROP_HEIGHT = 6

-- The attributes every placed copy wears. Named here so the server that writes them and the managers
-- and controllers that read them can't drift apart. The cell four are what let a client work out
-- whether a spot is free without being told: they're on the models, which replicate to everyone,
-- unlike the owner's data.
Structures.UID_ATTRIBUTE = "Uid"
Structures.OWNER_ATTRIBUTE = "OwnerUserId"

-- Which structure this is, as a Structures id. The tag a placed copy wears says what KIND of thing it
-- is and that's what every manager binds on; this says which model of that kind, and it's for the
-- handful of things that differ between two grillers rather than between a griller and a stand -- the
-- cook effect on the grate, for one. On the model for the same reason the cells below are: data only
-- reaches its owner, and a visitor stood at someone else's grill has to render it right too.
Structures.TYPE_ATTRIBUTE = "StructureType"

Structures.CELL_X_ATTRIBUTE = "CellX"
Structures.CELL_Z_ATTRIBUTE = "CellZ"
Structures.FOOTPRINT_X_ATTRIBUTE = "FootprintX"
Structures.FOOTPRINT_Z_ATTRIBUTE = "FootprintZ"

-- The part a structure template is built against, authored as a direct child of the model. Named here
-- rather than spelled out at each use for the same reason the attributes above are: what measures it
-- and what reads it can't drift apart.
Structures.HITBOX_NAME = "Hitbox"

-- The box a structure is built against: its Hitbox when one is authored, otherwise the model's own
-- bounding box. Both the cells it reserves and where it ends up standing are measured off this, so a
-- Hitbox is how a model states what it occupies rather than having it guessed from its geometry --
-- which is what lets a lid handle or a chimney hang off the side without reserving a phantom cell or
-- shoving the thing off-centre from the cells it did reserve.
--
-- A direct child and not a descendant search: a griller has models inside it (its Grill, for one) and
-- shouldn't be able to inherit one of their hitboxes by accident.
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

-- Each entry pulls its template out of Assets.Structures[Category], matched on Id, and resolves how
-- many cells it takes up while it's there -- measuring the model per placement would be paid for on
-- every frame the ghost moves. A structure whose model is missing gets dropped rather than left
-- half-built, so it can't be placed and then fail to render. One missing only its Hitbox is kept: it
-- still renders and still sells, it just measures the old way, so a template that hasn't been given
-- one yet doesn't vanish out of the shop.
--
-- The footprint is snapped to the NEAREST whole cell rather than rounded up: rounding up would
-- reserve a phantom extra cell for a slightly-oversized box, which makes two flush neighbours read
-- as overlapping.
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

	-- The box's dimensions, kept alongside the footprint below rather than only being used to derive it.
	-- The footprint is what gets reserved on the grid and is rounded to whole cells; this is the same
	-- thing unrounded, which is what anything measuring a structure against the world rather than
	-- against the grid wants (see BuildController's touch aim).
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

-- The structures the Grill & Stand Shop can stock and sell, in config order. Filters out the ones
-- flagged Restockable = false, so the server's stock roll and the client's rows share one source of
-- truth about what's for sale. Config order is the roll's draw sequence -- see the note on Structures.Data.
function Structures.GetRestockableStructures(): { Structure }
	local restockable = {}

	for _, structure in Structures.Data do
		if structure.Restockable then
			table.insert(restockable, structure)
		end
	end

	return restockable
end

-- Whether a structure type is a kind of thing -- a griller, a stick stand. What the managers key off,
-- since they own a category rather than one model of it, and an id off a remote can be anything.
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

-- Whether two blocks of cells share any cell. Plain integer AABB overlap: this is the whole collision
-- model, so nothing is ever queried against the world and a structure's real shape never matters --
-- only the cells it claimed.
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

-- Whether an already-placed structure stands in the way of a block of cells. The placed one's
-- footprint is worked out from its type and rotation rather than stored, so data holds only what the
-- player chose and can never disagree with the config about how big a thing is.
--
-- Every structure on a base is measured in the same cells whichever plot it happens to stand over, so
-- two of them meeting across a seam collide like any other pair.
function Structures.Overlaps(
	placed: PlacedStructure,
	cellX: number,
	cellZ: number,
	footprintX: number,
	footprintZ: number
): boolean
	local structure = Structures.GetStructureFromId(placed.Type)

	-- A structure whose template went missing is dropped from the config at load, so data written
	-- before that can name one that isn't there any more. It has no model in the world either, so it
	-- isn't standing in anyone's way.
	if not structure then
		return false
	end

	local placedX, placedZ = Structures.GetFootprint(structure, placed.Rotation)

	return Structures.BlocksOverlap(cellX, cellZ, footprintX, footprintZ, placed.CellX, placed.CellZ, placedX, placedZ)
end

-- The pivot that puts `model` so the CENTRE of the box it's built against sits on the given surface
-- block-centre, that box's bottom face resting on the surface, turned `rotation` quarter-turns.
-- Placed by that box rather than by the model's own pivot, which may be off to one side: that's what
-- keeps a structure square on the cells it reserved however it was authored, and in every rotation.
--
-- Since the box is the Hitbox where there is one, this is also where a Hitbox earns the two things a
-- footprint number alone can't buy -- a model whose geometry hangs off one side still sits centred,
-- and one with something dangling below its base still sits flush instead of floating.
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
