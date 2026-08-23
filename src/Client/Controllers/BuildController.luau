-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Structures = require(Shared.Config.Structures)
local Plots = require(Shared.Config.Plots)
local GridUtil = require(Shared.GridUtil)

-- Controllers
local PlayerDataController = require(script.Parent.PlayerDataController)

--
local LocalPlayer = Players.LocalPlayer

-- What BuildManager marks its tools with. The tag is on the ones that place a structure and the
-- attribute beside it says which; the demolish tool wears its own attribute instead, being a mode
-- rather than something the player owns any number of.
local STRUCTURE_TOOL_TAG = "StructureTool"
local STRUCTURE_TOOL_ATTRIBUTE = "StructureId"
local REMOVE_TOOL_ATTRIBUTE = "RemoveTool"

local GHOST_TRANSPARENCY = 0.5
local VALID_COLOR = Color3.fromRGB(70, 220, 90)
local INVALID_COLOR = Color3.fromRGB(220, 70, 70)
local REMOVE_COLOR = Color3.fromRGB(220, 70, 70)
-- Kept faint, so the structure about to go is obvious without its own colours being lost -- you're
-- picking one of several near-identical things out of a row.
local REMOVE_FILL_TRANSPARENCY = 0.6

local RAY_LENGTH = 1000
local ROTATE_KEY = Enum.KeyCode.R
-- Higher = the ghost catches up to the cell under the cursor faster. Eased rather than snapped so
-- dragging across the grid glides instead of stepping cell to cell.
local GHOST_FOLLOW_SPEED = 30
-- Seconds between placements the client will send. The server rate-limits and re-checks besides; this
-- is only so holding the button down doesn't spend the whole balance in a frame.
local PLACE_DEBOUNCE = 0.15

-- How long to wait for the backpack on a spawn before giving up on this life's tools.
local BACKPACK_TIMEOUT = 10

--[[
    Placement, client half.

    Equipping a build tool raises a translucent copy of what it builds, which follows the cursor
    snapped to the grid of whichever plot it's over -- green where it fits and red where it doesn't.
    Clicking sends the cell to the server, which decides.

    Nothing here is authoritative. Every check this makes, the server makes again off its own copy of
    the player's build (see BaseManager:PlaceStructureOnBase); the point of making them here at all is
    that the player can see the answer before they pay for it. What crosses the wire is a plot and two
    integers, never a position -- so there's nothing in the message for a hacked client to bend that
    the server doesn't work out for itself.

    Which ground is buildable is the plots the player owns, and it changes under them: buying a plot
    clears it and it becomes buildable in the same moment, without re-equipping. That's what the data
    listener is for.

    The demolish tool rides the same loop pointed the other way -- it raycasts the placed structures
    rather than the floors, and outlines the one under the cursor.
]]

--
local BuildController = {
	PlaceStructureEvent = Network.Event("PlaceStructure"),
	RemoveStructureEvent = Network.Event("RemoveStructure"),

	_floors = {}, -- [BasePart] = plotId, every plot the player owns and so can build on
	_lastPlaceTime = 0,
}

-- The base model the local player owns, once they've been given one.
function BuildController:_getBase(): Model?
	local baseId = LocalPlayer:GetAttribute("BaseId")
	if not baseId then
		return nil
	end

	local baseFolder = workspace:FindFirstChild("Base")

	return baseFolder and baseFolder:FindFirstChild(baseId) :: Model?
end

-- Re-reads which of the base's plots the player owns, and so where they may build. Every owned plot
-- is its own grid, measured off its own floor -- so this is both the raycast target list and the map
-- back from whichever floor was hit to the plot it belongs to.
function BuildController:_refreshFloors()
	local base = self:_getBase()

	if not base then
		table.clear(self._floors)
		return
	end

	local folder = base:FindFirstChild(Plots.FOLDER_NAME)
	if not folder then
		table.clear(self._floors)
		warn(`[Build] {base.Name} has no {Plots.FOLDER_NAME} folder, so there's nowhere to build`)
		return
	end

	-- Read before clearing below, because this yields until the replica lands: emptying the floors
	-- first would blank the ghost for however long that took, on a refresh that mostly ends up putting
	-- back what was already there.
	local unlocked = PlayerDataController:GetKey("Plots") or {}

	table.clear(self._floors)

	local owned = 0

	for _, plotModel in folder:GetChildren() do
		if not Plots.IsOwned(plotModel.Name, unlocked) then
			continue
		end

		owned += 1

		-- Searched rather than indexed, so a floor tucked inside the plot's own structure still counts.
		local floor = plotModel:FindFirstChild(Plots.FLOOR_NAME, true)

		if not floor or not floor:IsA("BasePart") then
			warn(`[Build] plot {plotModel.Name} has no {Plots.FLOOR_NAME} part, so nothing can go on it`)
			continue
		end

		-- The ghost finds its spot by raycasting the floor, so one the ray passes through is ground the
		-- player can see and stand on but never build on. Invisible is fine; unqueryable isn't.
		if not floor.CanQuery then
			warn(`[Build] plot {plotModel.Name}'s {Plots.FLOOR_NAME} has CanQuery off, so it can't be built on`)
			continue
		end

		self._floors[floor] = plotModel.Name
	end

	if owned == 0 then
		warn(`[Build] {base.Name} has no plot named {Plots.START}, so the player owns no ground to build on`)
	end
end

-- Points the active placement's raycast at the floors the player currently owns. Called again when
-- they buy a plot, so ground that has just been cleared can be built on without re-equipping.
function BuildController:_refreshRaycastParams()
	if not self._raycastParams then
		return
	end

	local floors = {}
	for floor in self._floors do
		table.insert(floors, floor)
	end

	self._raycastParams.FilterDescendantsInstances = floors
end

-- Whether the block of cells under the cursor is clear of everything already built on that plot. The
-- same integer overlap the server runs, so the two agree about what's free.
--
-- The cells each standing structure claimed are read off the models rather than player data, because
-- the models are what every client can see -- data only ever reaches its owner, and the ghost has to
-- be right on a base you're visiting too.
--
-- Walked rather than cached: this runs every frame the ghost moves, so it's written to allocate
-- nothing, and a build is a few dozen models at most. Caching it would mean invalidating on every
-- placement, removal and base handover for no measurable gain.
function BuildController:_isBlockFreeLocally(
	plotId: string,
	cellX: number,
	cellZ: number,
	footprintX: number,
	footprintZ: number
): boolean
	local base = self:_getBase()
	local folder = base and base:FindFirstChild(Structures.FOLDER_NAME)
	if not folder then
		return true
	end

	for _, model in folder:GetChildren() do
		if model:GetAttribute(Structures.PLOT_ATTRIBUTE) ~= plotId then
			continue
		end

		local placedX = model:GetAttribute(Structures.CELL_X_ATTRIBUTE)
		local placedZ = model:GetAttribute(Structures.CELL_Z_ATTRIBUTE)

		-- A structure replicates model-first, so one that's just gone down can be here with its cells
		-- still on the way. Skipping it only reads that spot as free for a frame, and the server would
		-- refuse the placement anyway.
		if not placedX or not placedZ then
			continue
		end

		local placedFootprintX = model:GetAttribute(Structures.FOOTPRINT_X_ATTRIBUTE) or 1
		local placedFootprintZ = model:GetAttribute(Structures.FOOTPRINT_Z_ATTRIBUTE) or 1

		if
			Structures.BlocksOverlap(
				cellX,
				cellZ,
				footprintX,
				footprintZ,
				placedX,
				placedZ,
				placedFootprintX,
				placedFootprintZ
			)
		then
			return false
		end
	end

	return true
end

-- A see-through, inert copy of what the tool builds. Stripped of anything that would make it act like
-- the real thing: it can't be collided with, can't be raycast against (or it'd block its own
-- placement ray), and carries no tag, so no controller mistakes it for a structure that exists.
function BuildController:_createGhost(structure: Structures.Structure): Model
	local ghost = structure.Model:Clone()

	local parts = {}
	for _, descendant in ghost:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		elseif descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		end
	end

	for _, part in parts do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = GHOST_TRANSPARENCY
	end

	self._ghostParts = parts
	ghost.Parent = workspace

	return ghost
end

-- Tints the ghost, and hides it outright when there's nowhere to put it -- a ghost stuck at the last
-- spot the cursor was over reads as a placement that's still on offer.
function BuildController:_paintGhost(transparency: number, color: Color3?)
	if not self._ghostParts then
		return
	end

	for _, part in self._ghostParts do
		part.Transparency = transparency

		if color then
			part.Color = color
		end
	end
end

-- Follows the cursor: raycast the owned floors, snap to the cell the footprint would sit on, and
-- record it for _tryPlace. Only how the ghost looks is eased -- the cell it reports is exact, so what
-- gets sent is never a frame behind what was shown.
function BuildController:_updateGhost(deltaTime: number)
	local ghost = self._ghost
	local mouse = self._mouse
	if not (ghost and mouse) then
		return
	end

	local ray = mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, self._raycastParams)

	-- Off every plot they own, so there's nothing to snap to.
	if not result then
		self._valid = false
		self:_paintGhost(1)
		return
	end

	local floor = result.Instance
	local plotId = self._floors[floor]

	if not plotId then
		self._valid = false
		self:_paintGhost(1)
		return
	end

	local structure = self._structure
	local footprintX, footprintZ = Structures.GetFootprint(structure, self._rotation)
	local countX, countZ = GridUtil.GetDimensions(floor, Structures.CELL_SIZE)
	local cellX, cellZ =
		GridUtil.WorldToCenteredAnchor(floor, result.Position, footprintX, footprintZ, Structures.CELL_SIZE)

	-- Pull the anchor back inside the plot so the whole footprint stays on it, rather than letting it
	-- hang off the edge and simply read as invalid. Something bigger than the plot can't fit either
	-- way, so it's left under the cursor to be refused.
	local maxAnchorX, maxAnchorZ = countX - footprintX, countZ - footprintZ
	if maxAnchorX >= 0 then
		cellX = math.clamp(cellX, 0, maxAnchorX)
	end
	if maxAnchorZ >= 0 then
		cellZ = math.clamp(cellZ, 0, maxAnchorZ)
	end

	local valid = GridUtil.IsBlockInBounds(floor, cellX, cellZ, footprintX, footprintZ, Structures.CELL_SIZE)
		and self:_isBlockFreeLocally(plotId, cellX, cellZ, footprintX, footprintZ)

	self._targetPlotId = plotId
	self._targetCellX = cellX
	self._targetCellZ = cellZ
	self._valid = valid

	local surface = GridUtil.CellToSurfaceCFrame(floor, cellX, cellZ, footprintX, footprintZ, Structures.CELL_SIZE)
	local target = Structures.GetPlacementPivot(ghost, surface, self._rotation)

	-- Eased toward the snapped spot, so dragging glides. The first frame snaps outright, and math.exp
	-- keeps the glide the same speed whatever the framerate.
	if self._ghostCFrame then
		self._ghostCFrame = self._ghostCFrame:Lerp(target, 1 - math.exp(-GHOST_FOLLOW_SPEED * deltaTime))
	else
		self._ghostCFrame = target
	end

	ghost:PivotTo(self._ghostCFrame)
	self:_paintGhost(GHOST_TRANSPARENCY, if valid then VALID_COLOR else INVALID_COLOR)
end

-- Follows the cursor with the demolish tool up: outlines whichever of the player's structures is
-- under it, and remembers its uid for _tryRemove.
function BuildController:_updateRemoveTarget()
	local mouse = self._mouse
	if not mouse then
		return
	end

	local ray = mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, self._raycastParams)

	-- The ray lands on some part deep inside a structure, so climb to the structure itself. Climbing to
	-- the folder's own child rather than to the nearest Model: a structure has models inside it (a
	-- griller's GrillModel, for one), and the nearest one up is one of those rather than the thing that
	-- was built.
	local model = result and result.Instance
	while model and model.Parent ~= self._structureFolder do
		model = model.Parent
	end

	local uid = model and model:GetAttribute(Structures.UID_ATTRIBUTE)

	self._removeUid = uid
	self._removeHighlight.Adornee = if uid then model else nil
end

-- Sends the cell under the cursor to be built on. Refused placements come back as nothing happening,
-- which is what the ghost turning red is there to prevent -- so anything reaching here has already
-- been shown to the player as buildable.
function BuildController:_tryPlace()
	if not (self._structure and self._valid) then
		return
	end

	local now = os.clock()
	if now - self._lastPlaceTime < PLACE_DEBOUNCE then
		return
	end
	self._lastPlaceTime = now

	self.PlaceStructureEvent:FireServer(
		self._structure.Id,
		self._targetPlotId,
		self._targetCellX,
		self._targetCellZ,
		self._rotation
	)
end

-- Takes down whichever structure is under the cursor.
function BuildController:_tryRemove()
	if not self._removeUid then
		return
	end

	local now = os.clock()
	if now - self._lastPlaceTime < PLACE_DEBOUNCE then
		return
	end
	self._lastPlaceTime = now

	self.RemoveStructureEvent:FireServer(self._removeUid)
end

-- Raises the ghost and starts it following the cursor. Everything it sets up hangs off the placement
-- cleaner, so unequipping puts the world back exactly as it was.
-- Says so once, on equip, when this structure cannot fit on any ground the player owns. Without it
-- that case is silent and indistinguishable from bad aim: the ghost just reads red wherever it's put,
-- because the block never fits inside the grid however it's positioned.
--
-- Almost always a setup problem rather than a game state -- a plot floor too small for the thing being
-- put on it, or Structures.CELL_SIZE set coarser than the floors were built for.
function BuildController:_warnIfUnplaceable(structure: Structures.Structure)
	if not next(self._floors) then
		warn(`[Build] no {Plots.FLOOR_NAME} to build on -- see the warnings above`)
		return
	end

	local footprintX, footprintZ = Structures.GetFootprint(structure, 0)

	for floor, plotId in self._floors do
		local countX, countZ = GridUtil.GetDimensions(floor, Structures.CELL_SIZE)

		-- Either way round, since the player can turn it a quarter-turn to fit the other way.
		if
			(footprintX <= countX and footprintZ <= countZ)
			or (footprintZ <= countX and footprintX <= countZ)
		then
			return
		end

		warn(
			`[Build] {structure.Name} is {footprintX}x{footprintZ} cells and plot {plotId} is only `
				.. `{countX}x{countZ} ({Structures.CELL_SIZE} studs each), so it can't fit`
		)
	end
end

-- Deliberately doesn't re-read which plots are owned: _floors is kept current by the listeners in
-- OnStart, and reading it here would yield on the replica -- long enough for an unequip to land
-- between the teardown above and the ghost below, leaving a ghost with nothing left to clean it up.
function BuildController:_enterPlacement(structure: Structures.Structure, mouse: Mouse)
	self:_exitPlacement()

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include

	self._structure = structure
	self._mouse = mouse
	self._rotation = 0
	self._raycastParams = raycastParams
	self._ghostCFrame = nil
	self._valid = false

	self:_refreshRaycastParams()
	self:_warnIfUnplaceable(structure)

	self._ghost = self._placementCleaner:Add(self:_createGhost(structure))

	self._placementCleaner:Connect(RunService.RenderStepped, function(deltaTime: number)
		self:_updateGhost(deltaTime)
	end)

	-- Rotation carries across placements until the tool is put away, so laying out a row of things all
	-- facing the same way is one keypress rather than one per copy.
	self._placementCleaner:Connect(UserInputService.InputBegan, function(input: InputObject, gameProcessed: boolean)
		if not gameProcessed and input.KeyCode == ROTATE_KEY then
			self._rotation = (self._rotation + 1) % 4
		end
	end)
end

-- Starts the demolish tool following the cursor, pointed at the structures rather than the floors.
function BuildController:_enterRemoval(mouse: Mouse)
	self:_exitPlacement()

	local base = self:_getBase()
	local folder = base and base:FindFirstChild(Structures.FOLDER_NAME)

	-- Nothing built yet, so there's nothing this tool can do.
	if not folder then
		return
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.FilterDescendantsInstances = { folder }

	local highlight = Instance.new("Highlight")
	highlight.FillColor = REMOVE_COLOR
	highlight.OutlineColor = REMOVE_COLOR
	highlight.FillTransparency = REMOVE_FILL_TRANSPARENCY
	highlight.OutlineTransparency = 0
	highlight.Parent = self._highlightHolder

	self._mouse = mouse
	self._raycastParams = raycastParams
	self._structureFolder = folder
	self._removeHighlight = self._placementCleaner:Add(highlight)

	self._placementCleaner:Connect(RunService.RenderStepped, function()
		self:_updateRemoveTarget()
	end)
end

-- Drops the ghost (or the demolish outline) and everything driving it.
function BuildController:_exitPlacement()
	self._placementCleaner:Clean()

	self._structure = nil
	self._activeTool = nil
	self._mouse = nil
	self._ghost = nil
	self._ghostParts = nil
	self._rotation = 0
	self._raycastParams = nil
	self._ghostCFrame = nil
	self._targetPlotId = nil
	self._targetCellX = nil
	self._targetCellZ = nil
	self._valid = false
	self._structureFolder = nil
	self._removeUid = nil
	self._removeHighlight = nil
end

-- Hooks one build tool, so equipping it starts placement and using it commits. Anything else in the
-- backpack -- sticks, ingredients, crates -- isn't ours and is left alone.
function BuildController:_hookTool(tool: Tool)
	local isRemover = tool:GetAttribute(REMOVE_TOOL_ATTRIBUTE) == true

	if not isRemover and not tool:HasTag(STRUCTURE_TOOL_TAG) then
		return
	end

	if self._hookedTools[tool] then
		return
	end
	self._hookedTools[tool] = true

	-- Which structure this tool places, resolved once: a tool is built for one kind and never changes
	-- kind, only how many of it are left. Nil for the demolish tool, and for a tool naming a structure
	-- the config dropped for want of a model -- which leaves it inert in the hand rather than erroring.
	local structure = Structures.GetStructureFromId(tool:GetAttribute(STRUCTURE_TOOL_ATTRIBUTE))

	self._characterCleaner:Connect(tool.Equipped, function(mouse: Mouse)
		if isRemover then
			self:_enterRemoval(mouse)
		elseif structure then
			self:_enterPlacement(structure, mouse)
		else
			return
		end

		-- Which tool the ghost belongs to, so the Destroying below can tell "the thing I'm placing has
		-- run out" from any other tool going away.
		self._activeTool = tool
	end)

	self._characterCleaner:Connect(tool.Unequipped, function()
		self:_exitPlacement()
	end)

	-- Putting down the last of something takes the tool out of the player's hands, since the server
	-- rebuilds the backpack from what they own and they no longer own one. Watched as well as
	-- Unequipped so the ghost can't outlive the tool it belongs to and hang there unplaceable.
	self._characterCleaner:Connect(tool.Destroying, function()
		self._hookedTools[tool] = nil

		if self._activeTool == tool then
			self:_exitPlacement()
		end
	end)

	self._characterCleaner:Connect(tool.Activated, function()
		if isRemover then
			self:_tryRemove()
		else
			self:_tryPlace()
		end
	end)
end

-- Watches the backpack for this life's build tools. They're handed out fresh on every spawn, so the
-- hooks are dropped and re-made with the character rather than kept.
--
-- Waited on rather than found: the backpack is replaced with the character, so on a respawn it can
-- still be on its way here -- and the server fills it from its own side, which lands later again.
-- That's what the ChildAdded below is for.
function BuildController:_watchCharacter()
	self._characterCleaner:Clean()
	self:_exitPlacement()

	self._hookedTools = {}

	local backpack = LocalPlayer:WaitForChild("Backpack", BACKPACK_TIMEOUT)
	if not backpack then
		return
	end

	self._characterCleaner:Connect(backpack.ChildAdded, function(child: Instance)
		if child:IsA("Tool") then
			self:_hookTool(child)
		end
	end)

	for _, child in backpack:GetChildren() do
		if child:IsA("Tool") then
			self:_hookTool(child)
		end
	end
end

function BuildController:OnInit()
	self._cleaner = Trove.new()
	self._characterCleaner = self._cleaner:Construct(Trove)
	self._placementCleaner = self._cleaner:Construct(Trove)
	self._hookedTools = {}
end

function BuildController:OnStart()
	-- A Highlight is pointed by its Adornee rather than by where it lives, so it needs a parent that
	-- isn't the structure it's outlining -- one the structure being taken down can't take with it.
	self._highlightHolder = self._cleaner:Add(Instance.new("Folder"))
	self._highlightHolder.Name = "BuildHighlights"
	self._highlightHolder.Parent = LocalPlayer.PlayerGui

	self._cleaner:Connect(LocalPlayer.CharacterAdded, function()
		self:_watchCharacter()
	end)

	self._cleaner:Connect(LocalPlayer.CharacterRemoving, function()
		self:_exitPlacement()
	end)

	-- Already spawned by the time this controller started, so they'd otherwise wait for a death.
	-- Watching yields on the backpack, so keep it off the start thread.
	if LocalPlayer.Character then
		task.spawn(function()
			self:_watchCharacter()
		end)
	end

	-- Being given a base is what makes any ground buildable, and buying a plot adds to it. Both can
	-- happen with a tool already in hand, so the floors are re-read rather than resolved once.
	--
	-- Listening yields on the replica, so keep it off the start thread.
	self._cleaner:Connect(LocalPlayer:GetAttributeChangedSignal("BaseId"), function()
		self:_refreshFloors()
		self:_refreshRaycastParams()
	end)

	task.spawn(function()
		self._cleaner:Add(PlayerDataController:ListenForChange("Plots", function()
			self:_refreshFloors()
			self:_refreshRaycastParams()
		end))

		self:_refreshFloors()
		self:_refreshRaycastParams()
	end)
end

return BuildController
