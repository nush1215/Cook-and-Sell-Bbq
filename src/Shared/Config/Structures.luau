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
	Category: string, -- the folder under Assets.Structures, and the CollectionService tag placed copies wear
	Cost: number, -- what one costs to buy. Not charged for putting one down: a structure is paid for
	-- once, when it's bought, and moves freely between the inventory and the base after that. Nothing
	-- reads this yet -- it's what a structure shop will price off once there is one.
	Footprint: Footprint?, -- grid cells occupied; derived from the model's size when absent
	Model: Model, -- not authored below, back-filled from Assets.Structures
	FootprintX: number, -- not authored below, resolved once at load (see the back-fill loop)
	FootprintZ: number,
}

-- A structure as player data holds it: which kind, and where on which plot it sits.
export type PlacedStructure = {
	Type: string,
	PlotId: string,
	CellX: number,
	CellZ: number,
	Rotation: number,
}

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

    Where a structure sits is stored as a plot and a grid cell rather than a pose, because that's what
    the client actually sends and the server actually validates -- so data holds exactly what was
    checked, occupancy comes back losslessly on a rejoin, and which plot a structure needs unlocked to
    exist is a lookup rather than something re-derived from a position.
]]
Structures.Data = {
	{
		Id = "BaseGriller",
		Name = "Griller",
		Category = "Grillers",
		Cost = 2_500,
	},
	{
		Id = "BaseStickStand",
		Name = "Stick Stand",
		Category = "StickStands",
		Cost = 1_000,
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
Structures.PLOT_ATTRIBUTE = "PlotId"
Structures.CELL_X_ATTRIBUTE = "CellX"
Structures.CELL_Z_ATTRIBUTE = "CellZ"
Structures.FOOTPRINT_X_ATTRIBUTE = "FootprintX"
Structures.FOOTPRINT_Z_ATTRIBUTE = "FootprintZ"

-- Full size of a structure's template, however it's built.
local function getModelSize(instance: Instance): Vector3?
	if instance:IsA("Model") then
		local _, size = instance:GetBoundingBox()
		return size
	elseif instance:IsA("BasePart") then
		return instance.Size
	end

	return nil
end

-- Each entry pulls its template out of Assets.Structures[Category], matched on Id, and resolves how
-- many cells it takes up while it's there -- measuring a bounding box per placement would be paid for
-- on every frame the ghost moves. A structure whose model is missing gets dropped rather than left
-- half-built, so it can't be placed and then fail to render.
--
-- The footprint is snapped to the NEAREST whole cell rather than rounded up: rounding up would
-- reserve a phantom extra cell for a slightly-oversized bounding box, which makes two flush
-- neighbours read as overlapping.
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

	local authored = structure.Footprint
	if authored then
		structure.FootprintX, structure.FootprintZ = authored.X, authored.Z
	else
		local size = getModelSize(model)

		structure.FootprintX = if size then math.max(1, math.round(size.X / Structures.CELL_SIZE)) else 1
		structure.FootprintZ = if size then math.max(1, math.round(size.Z / Structures.CELL_SIZE)) else 1
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

-- Whether two blocks of cells on the same plot share any cell. Plain integer AABB overlap: this is
-- the whole collision model, so nothing is ever queried against the world and a structure's real
-- shape never matters -- only the cells it claimed.
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

-- Whether an already-placed structure stands in the way of a block on some plot. The placed one's
-- footprint is worked out from its type and rotation rather than stored, so data holds only what the
-- player chose and can never disagree with the config about how big a thing is.
function Structures.Overlaps(
	placed: PlacedStructure,
	plotId: string,
	cellX: number,
	cellZ: number,
	footprintX: number,
	footprintZ: number
): boolean
	if placed.PlotId ~= plotId then
		return false
	end

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

-- The pivot that puts `model` so its bounding-box CENTRE sits on the given surface block-centre,
-- resting on it and turned `rotation` quarter-turns. Centred on the bounding box rather than the
-- model's own pivot, which may be off to one side: that's what keeps a model square on the cells it
-- reserved however it was authored, and in every rotation.
function Structures.GetPlacementPivot(model: Instance, surfaceCFrame: CFrame, rotation: number): CFrame
	local centerCFrame, halfHeight

	if model:IsA("Model") then
		local cframe, size = model:GetBoundingBox()
		centerCFrame, halfHeight = cframe, size.Y / 2
	elseif model:IsA("BasePart") then
		centerCFrame, halfHeight = model.CFrame, model.Size.Y / 2
	else
		centerCFrame, halfHeight = model:GetPivot(), 0
	end

	-- Solve for the pivot whose resulting bounding-box centre lands on the target (bbox = pivot * offset).
	local pivotToCenter = model:GetPivot():ToObjectSpace(centerCFrame)
	local targetCenter = surfaceCFrame * CFrame.Angles(0, math.rad(rotation * 90), 0) * CFrame.new(0, halfHeight, 0)

	return targetCenter * pivotToCenter:Inverse()
end

return Structures
