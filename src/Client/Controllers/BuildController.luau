-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Structures = require(Shared.Config.Structures)
local Plots = require(Shared.Config.Plots)
local GridUtil = require(Shared.GridUtil)

-- Controllers
local PlayerDataController = require(script.Parent.PlayerDataController)
local NotificationController = require(script.Parent.NotificationController)

-- Modules
local Modules = script.Parent.Parent.Modules

-- Required on first use -- on touch it yields at require time, which would hold the client boot
local ContextActionUtility

--
local LocalPlayer = Players.LocalPlayer

-- What BuildManager marks its tools with; the pickup tool wears its own, being a mode not an item
local STRUCTURE_TOOL_TAG = "StructureTool"
local STRUCTURE_TOOL_ATTRIBUTE = "StructureId"
local PICKUP_TOOL_ATTRIBUTE = "PickupTool"

local VALID_COLOR = Color3.fromRGB(0, 255, 0)
local INVALID_COLOR = Color3.fromRGB(220, 70, 70)
-- The ghost keeps its own colours and wears the verdict as an outline, not a tint
local GHOST_FILL_TRANSPARENCY = 0.3
local GHOST_OUTLINE_TRANSPARENCY = 0

-- The calm pass over everything the pickup tool could take back -- faint, so a whole base still reads
local PICKUP_COLOR = Color3.fromRGB(255, 255, 255)
local PICKUP_FILL_TRANSPARENCY = 0.85
local PICKUP_OUTLINE_TRANSPARENCY = 0.25

-- The one under the cursor, between the white and the red, so pointing then picking reads as one action
local HOVER_COLOR = Color3.fromRGB(255, 150, 45)
local HOVER_FILL_TRANSPARENCY = 0.7
local HOVER_OUTLINE_TRANSPARENCY = 0

-- Picked, waiting on a second click. AlwaysOnTop, unlike the passes above -- it must be unmistakable
local ARMED_COLOR = Color3.fromRGB(220, 70, 70)
local ARMED_FILL_TRANSPARENCY = 0.6
local ARMED_OUTLINE_TRANSPARENCY = 0

-- Roblox renders at most 31 Highlights, so the calm pass is capped and given to the nearest structures
local PICKUP_HIGHLIGHT_BUDGET = 24
-- Seconds between re-picking which structures wear them; each pass walks every structure on the base.
local PICKUP_REFRESH_INTERVAL = 0.2

local RAY_LENGTH = 1000
local ROTATE_KEY = Enum.KeyCode.R

-- Which way round a model is built, in quarter-turns from -Z. Turn this for a backwards template
local FACING_FRONT_OFFSET = 0

-- Where a touch ghost sits: clearance is to the near edge, and reach is short enough to thumb-aim
local TOUCH_AIM_CLEARANCE = 5
local TOUCH_AIM_REACH = 40
local TOUCH_AIM_HEIGHT = 12

-- Room a character needs to count as standing in a block, measured out from the block's edges
local PLAYER_CLEARANCE = 2

-- One per reason a ghost goes red. Worded as what to do, since the red already said what went wrong
local REFUSAL_NO_SPOT = "Aim at ground you own"
local REFUSAL_OFF_GROUND = "It won't fit on ground you own"
local REFUSAL_OCCUPIED = "Something's already built there"
local REFUSAL_SELF = "You're standing there"
local REFUSAL_PLAYER = "Someone's standing there"

-- Stands in for a category lock set without a reason of its own (see SetPlaceCategory)
local REFUSAL_LOCKED = "You can't place that right now"

-- Matched to the game's other rejections, so being told no while building lands the same way
local REFUSAL_DURATION = 3
local REFUSAL_SOUND = "Reject"

-- Bound through ContextActionUtility, which is the only way a phone gets a rotate
local PLACE_ACTION = "BuildPlace"
local ROTATE_ACTION = "BuildRotate"

-- The desktop hints, authored in the place file under StarterGui -- these are the names it's found by
local GUIDE_GUI_NAME = "BuildingUI"
local GUIDE_FRAME_NAME = "PCGuide"
local GUIDE_PLACE_ENTRY = "Place"
local GUIDE_ROTATE_ENTRY = "Rotate"
local GUIDE_TIMEOUT = 10

-- Stands in for the guide when there's nowhere to build. Its own frame, so it can show on a phone too
local INVALID_FRAME_NAME = "Invalid"

-- Lifted from UIController's button springs, so a held key presses its hint like any other button
local GUIDE_PRESS_SCALE = 0.93
local GUIDE_NORMAL_SCALE = 1
local GUIDE_DAMPING = 0.45
local GUIDE_FREQUENCY = 6

-- Higher = the guide catches up to the cursor faster.
local GUIDE_FOLLOW_SPEED = 25
-- Higher = the ghost catches the cell faster. Eased, so dragging glides instead of stepping
local GHOST_FOLLOW_SPEED = 30
-- The server rate-limits too; this is only so holding the button down doesn't spend a balance in a frame.
local PLACE_DEBOUNCE = 0.15

-- How long to wait for the backpack on a spawn before giving up on this life's tools.
local BACKPACK_TIMEOUT = 10

-- Placement, client half: a build tool raises a grid-snapped ghost and sends the cell. Nothing here is authoritative.

--
local BuildController = {
	PlaceStructureEvent = Network.Event("PlaceStructure"),
	RemoveStructureEvent = Network.Event("RemoveStructure"),

	_floors = {}, -- the floor of every plot the player owns, which is what the ghost's ray is aimed at
	_ground = nil, -- GridUtil.Ground?, the cells those floors add up to; nil before a base is handed over
	_lastPlaceTime = 0,

	_placeCategory = nil, -- while set, only this category may go down (see SetPlaceCategory)
	_placeRefusal = nil, -- what a ghost held off by that lock says when clicked
}

-- Holds placement to one category, for the tutorial beats asking for a particular structure down. Nil releases it.
function BuildController:SetPlaceCategory(category: string?, refusal: string?)
	self._placeCategory = category
	self._placeRefusal = refusal
end

-- The base model the local player owns, once they've been given one.
function BuildController:_getBase(): Model?
	local baseId = LocalPlayer:GetAttribute("BaseId")
	if not baseId then
		return nil
	end

	local baseFolder = workspace:FindFirstChild("Base")

	return baseFolder and baseFolder:FindFirstChild(baseId) :: Model?
end

-- Re-reads owned plots. The floors are both the raycast targets and what the buildable region is built from.
function BuildController:_refreshGround()
	self._ground = nil

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

	-- Read before the clear, since this yields on the replica and clearing first would blank the ghost
	local unlocked = PlayerDataController:GetKey("Plots") or {}

	table.clear(self._floors)

	local owned = 0
	local startFloor: BasePart? = nil

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

		-- The ghost finds its spot by raycasting the floor, so an unqueryable one can never be built on.
		if not floor.CanQuery then
			warn(`[Build] plot {plotModel.Name}'s {Plots.FLOOR_NAME} has CanQuery off, so it can't be built on`)
			continue
		end

		table.insert(self._floors, floor)

		if plotModel.Name == Plots.START then
			startFloor = floor
		end
	end

	if owned == 0 then
		warn(`[Build] {base.Name} has no plot named {Plots.START}, so the player owns no ground to build on`)
		return
	end

	-- The starting plot's floor anchors the whole base's grid, so without it there are no cells to snap to.
	if not startFloor then
		warn(
			`[Build] {base.Name} has no {Plots.START} {Plots.FLOOR_NAME}, `
				.. `so its grid can't be measured and nothing can be built on it`
		)
		return
	end

	self._ground = GridUtil.BuildGround(startFloor, self._floors, Structures.CELL_SIZE)
end

-- Re-points the placement raycast at owned floors, so a plot bought mid-session needs no re-equip.
function BuildController:_refreshRaycastParams()
	if not self._raycastParams then
		return
	end

	self._raycastParams.FilterDescendantsInstances = self._floors
end

-- Whether the block under the cursor is clear, read off placed models so it's right on a base you visit.
function BuildController:_isBlockFreeLocally(
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

	-- Only what's streamed in; wrong further off than anyone builds, and Base:IsBlockFree decides
	for _, model in folder:GetChildren() do
		local placedX = model:GetAttribute(Structures.CELL_X_ATTRIBUTE)
		local placedZ = model:GetAttribute(Structures.CELL_Z_ATTRIBUTE)

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

-- Whoever is standing in the block, or nil. The one check the server doesn't repeat -- it would have moved.
function BuildController:_getPlayerInBlock(
	ground: GridUtil.Ground,
	cellX: number,
	cellZ: number,
	footprintX: number,
	footprintZ: number
): Player?
	local minX = cellX * Structures.CELL_SIZE - PLAYER_CLEARANCE
	local minZ = cellZ * Structures.CELL_SIZE - PLAYER_CLEARANCE
	local maxX = (cellX + footprintX) * Structures.CELL_SIZE + PLAYER_CLEARANCE
	local maxZ = (cellZ + footprintZ) * Structures.CELL_SIZE + PLAYER_CLEARANCE

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?

		-- Between dying and respawning there's nobody standing anywhere.
		if not root then
			continue
		end

		local point = ground.Origin:PointToObjectSpace(root.Position)

		if point.X > minX and point.X < maxX and point.Z > minZ and point.Z < maxZ then
			return player
		end
	end

	return nil
end

-- An inert copy of what the tool builds, stripped of collision, raycasts, scripts and tags.
function BuildController:_createGhost(structure: Structures.Structure): Model
	local ghost = structure.Model:Clone()

	local parts = {}
	for _, descendant in ghost:GetDescendants() do
		if descendant:IsA("BasePart") then
			-- Kept so unhiding can restore it: a part authored invisible (a hitbox, a mount) must stay so.
			table.insert(parts, { Part = descendant, Transparency = descendant.Transparency })
		elseif descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		end
	end

	for _, entry in parts do
		entry.Part.Anchored = true
		entry.Part.CanCollide = false
		entry.Part.CanQuery = false
		entry.Part.CanTouch = false
	end

	-- Parented away from what it outlines, like the pickup ones, so it isn't cloned or cleaned with it.
	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = GHOST_FILL_TRANSPARENCY
	highlight.OutlineTransparency = GHOST_OUTLINE_TRANSPARENCY
	highlight.Adornee = ghost
	highlight.Parent = self._highlightHolder

	self._ghostParts = parts
	self._ghostHighlight = self._placementCleaner:Add(highlight)
	ghost.Parent = workspace

	return ghost
end

-- Marks the spot good or bad, or hides the ghost -- one left standing reads as still on offer.
function BuildController:_paintGhost(shown: boolean, valid: boolean?)
	if not self._ghostParts then
		return
	end

	-- Only act on an actual change: this runs every frame the cursor moves, over every part of a model.
	if shown ~= self._ghostShown then
		self._ghostShown = shown

		for _, entry in self._ghostParts do
			entry.Part.Transparency = if shown then entry.Transparency else 1
		end

		if self._ghostHighlight then
			self._ghostHighlight.Enabled = shown
		end

		-- Off the ghost, not the verdict: a red ghost is still something to act on, no ghost isn't.
		self:_setGuideAimed(shown)
	end

	if valid ~= self._ghostValid then
		self._ghostValid = valid

		if self._ghostHighlight then
			local color = if valid then VALID_COLOR else INVALID_COLOR

			self._ghostHighlight.FillColor = color
			self._ghostHighlight.OutlineColor = color
		end
	end
end

-- The closest a touch ghost may sit: a fixed gap plus half the structure's depth along `look`.
function BuildController:_getTouchAimDistance(look: Vector3): number
	local structure = self._structure
	if not structure then
		return TOUCH_AIM_CLEARANCE
	end

	local sizeAlongX, sizeAlongZ = Structures.GetSize(structure, self._rotation)

	-- No grid yet, before a base is handed over: the world's axes are right for any base not turned.
	local ground = self._ground
	local right = if ground then ground.Origin.RightVector else Vector3.xAxis
	local forward = if ground then ground.Origin.LookVector else Vector3.zAxis

	local depth = math.abs(look:Dot(right)) * sizeAlongX + math.abs(look:Dot(forward)) * sizeAlongZ

	return TOUCH_AIM_CLEARANCE + depth / 2
end

-- Where a touch player's camera meets the floor plane, so aiming past the base still yields a direction.
function BuildController:_getCameraAimSpot(root: BasePart): Vector3?
	-- No grid yet, so no floor height: the caller falls back to pointing with the body.
	local ground = self._ground
	if not ground then
		return nil
	end

	local cameraCFrame = workspace.CurrentCamera.CFrame
	local direction = cameraCFrame.LookVector

	-- Flattened; a camera pointing straight up or down flattens to nothing, so the body stands in
	local look = direction * Vector3.new(1, 0, 1)
	look = if look.Magnitude > 0 then look.Unit else root.CFrame.LookVector

	-- What a camera that never meets the floor gets: straight out from it, at the far end of the clamp.
	local offset = look * TOUCH_AIM_REACH

	-- Above the floor and pointing down is what meets the plane ahead rather than behind
	local height = cameraCFrame.Position.Y - ground.Origin.Position.Y

	if direction.Y < 0 and height > 0 then
		-- Capped before use: a camera a hair below level solves to an infinity, then a NaN at .Unit
		local distance = math.min(height / -direction.Y, RAY_LENGTH)
		local toSpot = (cameraCFrame.Position + direction * distance - root.Position) * Vector3.new(1, 0, 1)

		-- Zero only when looking straight down at the player, which leaves no direction to push out along.
		if toSpot.Magnitude > 0 then
			offset = toSpot
		end
	end

	-- Clearance wins over reach -- standing inside the player is the worse end to give way at
	local minimum = self:_getTouchAimDistance(look)
	local reach = math.clamp(offset.Magnitude, minimum, math.max(TOUCH_AIM_REACH, minimum))

	return root.Position + offset.Unit * reach
end

-- The ray the ghost is aimed down. The touch one points straight down, so a level camera doesn't skid.
function BuildController:_getAimRay(): Ray?
	if not UserInputService.TouchEnabled then
		local mouse = self._mouse
		return mouse and mouse.UnitRay
	end

	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	-- Between dying and respawning there's nobody to aim from.
	if not root then
		return nil
	end

	-- Nil under _enterPickup, so this doubles as "should the camera be doing the aiming".
	local spot = if self._structure then self:_getCameraAimSpot(root) else nil

	if not spot then
		-- Flattened, or a root part tipped back in a seat would pull the spot in toward the player.
		local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
		look = if look.Magnitude > 0 then look.Unit else root.CFrame.LookVector

		spot = root.Position + look * self:_getTouchAimDistance(look)
	end

	return Ray.new(spot + Vector3.new(0, TOUCH_AIM_HEIGHT, 0), Vector3.new(0, -1, 0))
end

-- Which quarter-turn faces the structure at the player, in the grid's frame, backed off by FACING_FRONT_OFFSET.
function BuildController:_getFacingRotation(ground: GridUtil.Ground, spot: Vector3): number
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	-- Between dying and respawning there's nobody to face, so it's left however it was.
	if not root then
		return self._rotation
	end

	local toPlayer = ground.Origin:VectorToObjectSpace(root.Position - spot)

	-- Rounded, so a spot on an exact diagonal settles on one turn instead of flickering between two.
	return (math.round(math.atan2(-toPlayer.X, -toPlayer.Z) / (math.pi / 2)) - FACING_FRONT_OFFSET) % 4
end

-- Follows the aim and records the cell for _tryPlace. Only the look is eased; the cell reported is exact.
function BuildController:_updateGhost(deltaTime: number)
	local ghost = self._ghost
	local ray = self:_getAimRay()
	if not (ghost and ray) then
		return
	end

	local result = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, self._raycastParams)
	local ground = self._ground

	-- Off every owned plot, or on a base with no grid, so there's nothing to snap to.
	if not (result and ground) then
		self._refusal = REFUSAL_NO_SPOT
		self:_paintGhost(false)
		return
	end

	-- Turned to face the player only on the first frame with a spot -- a later turn is theirs to keep
	if not self._ghostCFrame then
		self._rotation = self:_getFacingRotation(ground, result.Position)
	end

	local structure = self._structure
	local footprintX, footprintZ = Structures.GetFootprint(structure, self._rotation)
	local cellX, cellZ =
		GridUtil.WorldToCenteredAnchor(ground.Origin, result.Position, footprintX, footprintZ, Structures.CELL_SIZE)

	-- Clamped to the plots' bounding box, not the plots, so an L-shaped notch reads red instead of jumping
	local maxAnchorX, maxAnchorZ = ground.MaxX - footprintX, ground.MaxZ - footprintZ
	if maxAnchorX >= ground.MinX then
		cellX = math.clamp(cellX, ground.MinX, maxAnchorX)
	end
	if maxAnchorZ >= ground.MinZ then
		cellZ = math.clamp(cellZ, ground.MinZ, maxAnchorZ)
	end

	-- A reason, not a boolean, so a refused click can name the check; re-deriving it would test a later frame
	local refusal = nil

	-- Ahead of the aim checks: a structure that isn't allowed down at all is the real reason, wherever it's pointed
	if self._placeCategory and structure.Category ~= self._placeCategory then
		refusal = self._placeRefusal or REFUSAL_LOCKED
	elseif not GridUtil.IsBlockOnGround(ground, cellX, cellZ, footprintX, footprintZ) then
		refusal = REFUSAL_OFF_GROUND
	elseif not self:_isBlockFreeLocally(cellX, cellZ, footprintX, footprintZ) then
		refusal = REFUSAL_OCCUPIED
	else
		local blockingPlayer = self:_getPlayerInBlock(ground, cellX, cellZ, footprintX, footprintZ)

		if blockingPlayer then
			refusal = if blockingPlayer == LocalPlayer then REFUSAL_SELF else REFUSAL_PLAYER
		end
	end

	self._targetCellX = cellX
	self._targetCellZ = cellZ
	self._refusal = refusal

	local surface =
		GridUtil.CellToSurfaceCFrame(ground.Origin, cellX, cellZ, footprintX, footprintZ, Structures.CELL_SIZE)
	local target = Structures.GetPlacementPivot(ghost, surface, self._rotation)

	-- Eased toward the snapped spot so dragging glides; math.exp keeps it framerate-independent.
	if self._ghostCFrame then
		self._ghostCFrame = self._ghostCFrame:Lerp(target, 1 - math.exp(-GHOST_FOLLOW_SPEED * deltaTime))
	else
		self._ghostCFrame = target
	end

	ghost:PivotTo(self._ghostCFrame)
	self:_paintGhost(true, refusal == nil)
end

-- The calm pass's Highlight pool, fixed in size since Roblox renders a limited number at a time.
function BuildController:_createPickupHighlights(): { Highlight }
	local highlights = table.create(PICKUP_HIGHLIGHT_BUDGET)

	for _ = 1, PICKUP_HIGHLIGHT_BUDGET do
		local highlight = Instance.new("Highlight")
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.FillColor = PICKUP_COLOR
		highlight.OutlineColor = PICKUP_COLOR
		highlight.FillTransparency = PICKUP_FILL_TRANSPARENCY
		highlight.OutlineTransparency = PICKUP_OUTLINE_TRANSPARENCY
		highlight.Enabled = false
		highlight.Parent = self._highlightHolder

		table.insert(highlights, self._placementCleaner:Add(highlight))
	end

	return highlights
end

-- Hands the pool to the nearest structures, so the outlines follow the part of the base being looked at.
function BuildController:_refreshPickupHighlights()
	local origin = workspace.CurrentCamera.CFrame.Position
	local models = {}

	for _, model in self._structureFolder:GetChildren() do
		local uid = model:GetAttribute(Structures.UID_ATTRIBUTE)

		-- The hovered and armed ones wear their own -- two Highlights on one adornee is undefined
		if uid and uid ~= self._armedUid and uid ~= self._hoverUid then
			table.insert(models, model)
		end
	end

	-- Only worth ordering when there are more structures than highlights.
	if #models > PICKUP_HIGHLIGHT_BUDGET then
		local distances = {}
		for _, model in models do
			distances[model] = (model:GetPivot().Position - origin).Magnitude
		end

		table.sort(models, function(a, b)
			return distances[a] < distances[b]
		end)
	end

	-- Disabled, not just unadorned, so a spare doesn't hold a slot in Roblox's active-highlight pool.
	for index, highlight in self._pickupHighlights do
		local model = models[index]

		highlight.Adornee = model
		highlight.Enabled = model ~= nil
	end
end

-- Switches a structure's own outlines off and back, since two Highlights on one adornee is undefined.
function BuildController:_refreshSuppressedHighlights()
	for _, highlight in self._suppressedHighlights do
		highlight.Enabled = true
	end
	table.clear(self._suppressedHighlights)

	local painted = {}
	if self._armedHighlight.Adornee then
		table.insert(painted, self._armedHighlight.Adornee)
	end
	if self._hoverHighlight.Adornee then
		table.insert(painted, self._hoverHighlight.Adornee)
	end

	for _, model in painted do
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("Highlight") and descendant.Enabled then
				descendant.Enabled = false
				table.insert(self._suppressedHighlights, descendant)
			end
		end
	end
end

-- Whichever structure is under the cursor, and its uid. Nil for one whose uid hasn't replicated yet.
function BuildController:_getStructureUnderCursor(): (Model?, string?)
	local ray = self._mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, self._raycastParams)

	-- The folder's own child, not the nearest Model -- a structure has models inside it
	local model = result and result.Instance
	while model and model.Parent ~= self._structureFolder do
		model = model.Parent
	end

	local uid = model and model:GetAttribute(Structures.UID_ATTRIBUTE)
	if not uid then
		return nil, nil
	end

	return model, uid
end

-- Warms whatever is under the cursor, so what a click would pick is visible. The armed one is skipped.
function BuildController:_updateHoverTarget()
	local model, uid = self:_getStructureUnderCursor()

	if uid == self._armedUid then
		model, uid = nil, nil
	end

	-- Runs every frame and both refreshes below are real work, so an unchanged hover costs nothing.
	if uid == self._hoverUid then
		return
	end

	self._hoverUid = uid
	self._hoverHighlight.Adornee = model
	self._hoverHighlight.Enabled = model ~= nil

	self:_refreshSuppressedHighlights()
	self:_refreshPickupHighlights()
end

-- Picks what a second click would take back. Takes model and uid: one is outlined, one crosses the wire.
function BuildController:_armPickup(model: Model?, uid: string?)
	if self._armedUid == uid then
		return
	end

	self._armedUid = uid
	self._armedHighlight.Adornee = model
	self._armedHighlight.Enabled = model ~= nil

	-- Red takes it off the hover pass: two of our own outlines on one adornee fight the same way.
	if self._hoverUid == uid then
		self._hoverUid = nil
		self._hoverHighlight.Adornee = nil
		self._hoverHighlight.Enabled = false
	end

	if model then
		NotificationController:NotifyNormal({
			Text = "Click again to pick it up",
		})
	end

	-- Straight away, so the picked structure leaves the other passes in the same frame as the click
	self:_refreshSuppressedHighlights()
	self:_refreshPickupHighlights()
end

-- Sends the cell to be built on, or says why not -- the notification is for the player who clicked anyway.
function BuildController:_tryPlace()
	if not self._structure then
		return
	end

	-- Ahead of the refusal, so mashing at a red ghost doesn't shake the notification once per click
	local now = os.clock()
	if now - self._lastPlaceTime < PLACE_DEBOUNCE then
		return
	end
	self._lastPlaceTime = now

	local refusal = self._refusal
	if refusal then
		NotificationController:NotifyNormal({
			Text = refusal,
			Duration = REFUSAL_DURATION,
			Sound = REFUSAL_SOUND,
			Effect = "Error",
		})

		return
	end

	self.PlaceStructureEvent:FireServer(self._structure.Id, self._targetCellX, self._targetCellZ, self._rotation)
end

-- The pickup click: first picks, second sends, anything else moves the pick. Never taken by one click.
function BuildController:_tryPickup()
	-- Nothing to point with, so the tool was equipped before the player had a base.
	if not self._mouse then
		return
	end

	-- Raycast afresh -- on touch the tap and the cursor move aren't ordered, so a remembered target lags
	local model, uid = self:_getStructureUnderCursor()

	if uid ~= self._armedUid then
		self:_armPickup(model, uid)
		return
	end

	-- Nothing under the cursor and nothing picked: the click was at empty ground twice over.
	if not uid then
		return
	end

	local now = os.clock()
	if now - self._lastPlaceTime < PLACE_DEBOUNCE then
		return
	end
	self._lastPlaceTime = now

	self.RemoveStructureEvent:FireServer(uid)
	self:_armPickup(nil, nil)
end

-- Warns on equip when a structure fits nowhere, which the ghost alone can't distinguish from bad aim.
function BuildController:_warnIfUnplaceable(structure: Structures.Structure)
	local ground = self._ground

	if not ground then
		warn(`[Build] no {Plots.FLOOR_NAME} to build on -- see the warnings above`)
		return
	end

	local footprintX, footprintZ = Structures.GetFootprint(structure, 0)
	local countX, countZ = ground.MaxX - ground.MinX, ground.MaxZ - ground.MinZ

	-- Either way round, since the player can turn it a quarter-turn to fit the other way.
	if (footprintX <= countX and footprintZ <= countZ) or (footprintZ <= countX and footprintX <= countZ) then
		return
	end

	warn(
		`[Build] {structure.Name} is {footprintX}x{footprintZ} cells and the ground the player owns is only `
			.. `{countX}x{countZ} ({Structures.CELL_SIZE} studs each), so it can't fit`
	)
end

-- The guide frame, re-resolved because ResetOnSpawn rebuilds the ScreenGui with every character.
function BuildController:_getGuide(): Frame?
	if self._guide and self._guide.Parent then
		return self._guide
	end

	self._guide = self.UI and self.UI:FindFirstChild(GUIDE_FRAME_NAME)

	return self._guide
end

-- The invalid badge, or nil if the place file hasn't got one. Re-resolved for the same reason as the guide.
function BuildController:_getInvalid(): GuiObject?
	if self._invalid and self._invalid.Parent then
		return self._invalid
	end

	self._invalid = self.UI and self.UI:FindFirstChild(INVALID_FRAME_NAME)

	return self._invalid
end

-- One entry of the guide, by name.
function BuildController:_getGuideScale(entryName: string): UIScale?
	local guide = self:_getGuide()
	local entry = guide and guide:FindFirstChild(entryName)

	return entry and entry:FindFirstChildOfClass("UIScale")
end

-- Puts up the guide or the invalid badge, never both. Desktop only -- a phone has the touch buttons.
function BuildController:_refreshGuide()
	local placing = self._guidePlacing and not UserInputService.TouchEnabled
	local guide = self:_getGuide()
	local invalid = self:_getInvalid()

	if guide then
		guide.Visible = placing and self._guideAimed
	end

	if invalid then
		invalid.Visible = placing and not self._guideAimed
	end

	-- Dropped once neither is up, but kept across the swap, since they take turns at the same spot
	if not placing then
		self._guidePosition = nil
	end
end

-- Whether the ghost has somewhere to sit this frame, which is what decides between the two frames above.
function BuildController:_setGuideAimed(aimed: boolean)
	self._guideAimed = aimed

	self:_refreshGuide()
end

-- Squashes one guide entry while its input is held, using the same spring UIController puts on buttons.
function BuildController:_pressGuideEntry(entryName: string, pressed: boolean)
	local uiScale = self:_getGuideScale(entryName)

	-- No guide up: no frame in the place file, a phone, or the tool put away mid-press.
	if not uiScale then
		return
	end

	Spr.target(uiScale, GUIDE_DAMPING, GUIDE_FREQUENCY, {
		Scale = if pressed then GUIDE_PRESS_SCALE else GUIDE_NORMAL_SCALE,
	})
end

-- Hands the guide and badge to the placement, forcing both down after -- either may be authored visible.
function BuildController:_showGuide(shown: boolean)
	-- Reset on the way up, or a spring left running on a hidden frame is still settling on a fast swap
	if shown then
		for _, entryName in { GUIDE_PLACE_ENTRY, GUIDE_ROTATE_ENTRY } do
			local uiScale = self:_getGuideScale(entryName)

			if uiScale then
				Spr.stop(uiScale, "Scale")
				uiScale.Scale = GUIDE_NORMAL_SCALE
			end
		end
	end

	self._guidePlacing = shown

	-- Opens on the badge and swaps to the guide on the first frame that finds a cell.
	self._guideAimed = false

	self:_refreshGuide()
end

-- Glides whichever frame is up to the cursor. Both share one position, so the swap happens in place.
function BuildController:_updateGuide(deltaTime: number)
	local frame = self:_getGuide()

	if not (frame and frame.Visible) then
		frame = self:_getInvalid()
	end

	if not (frame and frame.Visible) then
		return
	end

	local mouse = UserInputService:GetMouseLocation()

	-- GetMouseLocation and a ScreenGui's origin both exclude the topbar inset, unless the gui ignores it
	local target = if self.UI.IgnoreGuiInset then mouse else mouse + GuiService:GetGuiInset()

	-- Same framerate-independent easing the ghost uses over the grid; the first frame snaps.
	if self._guidePosition then
		self._guidePosition = self._guidePosition:Lerp(target, 1 - math.exp(-GUIDE_FOLLOW_SPEED * deltaTime))
	else
		self._guidePosition = target
	end

	-- Position only: the authored anchor point is what places the frame relative to the pointer.
	frame.Position = UDim2.fromOffset(self._guidePosition.X, self._guidePosition.Y)
end

-- Binds place and rotate for the placement's length, each with a touch button. Only rotate takes a key.
function BuildController:_bindPlacementActions()
	ContextActionUtility = ContextActionUtility or require(Modules.ContextActionUtlity)

	-- Touch buttons report press, drag and release alike, so without the Begin check a tap counts twice.
	local function onPlace(_actionName: string, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			self:_tryPlace()
		end
	end

	-- Rotation carries across placements, so a row facing one way is one press. End only releases the hint
	local function onRotate(_actionName: string, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			self._rotation = (self._rotation + 1) % 4
			self:_pressGuideEntry(GUIDE_ROTATE_ENTRY, true)
		elseif inputState == Enum.UserInputState.End then
			self:_pressGuideEntry(GUIDE_ROTATE_ENTRY, false)
		end
	end

	-- Rotate first, so it takes the touch slot nearest the jump button.
	ContextActionUtility:BindAction(ROTATE_ACTION, onRotate, true, ROTATE_KEY)
	ContextActionUtility:SetTitle(ROTATE_ACTION, "Rotate")

	ContextActionUtility:BindAction(PLACE_ACTION, onPlace, true)
	ContextActionUtility:SetTitle(PLACE_ACTION, "Place")

	self._placementCleaner:Add(function()
		ContextActionUtility:UnbindAction(PLACE_ACTION)
		ContextActionUtility:UnbindAction(ROTATE_ACTION)
	end)
end

-- Raises the ghost and starts it following. Doesn't re-read plots -- yielding here could strand it.
function BuildController:_enterPlacement(structure: Structures.Structure, mouse: Mouse)
	self:_exitPlacement()

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include

	self._structure = structure
	self._mouse = mouse
	self._rotation = 0
	self._raycastParams = raycastParams
	self._ghostCFrame = nil
	-- A refusal, not nil -- nil means the spot is good, and a click on the equip frame shouldn't build.
	self._refusal = REFUSAL_NO_SPOT

	self:_refreshRaycastParams()
	self:_warnIfUnplaceable(structure)

	self._ghost = self._placementCleaner:Add(self:_createGhost(structure))

	self._placementCleaner:Connect(RunService.RenderStepped, function(deltaTime: number)
		self:_updateGhost(deltaTime)
		self:_updateGuide(deltaTime)
	end)

	self:_bindPlacementActions()

	-- Building only: the pickup tool has nothing to rotate, so _enterPickup leaves the guide down.
	self:_showGuide(true)

	-- On the cleaner rather than in _exitPlacement, so it also runs when the tool is destroyed.
	self._placementCleaner:Add(function()
		self:_showGuide(false)
	end)
end

-- Raises the calm pass over everything removable, all on the placement cleaner so unequipping restores it.
function BuildController:_enterPickup(mouse: Mouse)
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

	-- Occluded like the calm pass: what's under the cursor is by definition visible.
	local hoverHighlight = Instance.new("Highlight")
	hoverHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
	hoverHighlight.FillColor = HOVER_COLOR
	hoverHighlight.OutlineColor = HOVER_COLOR
	hoverHighlight.FillTransparency = HOVER_FILL_TRANSPARENCY
	hoverHighlight.OutlineTransparency = HOVER_OUTLINE_TRANSPARENCY
	hoverHighlight.Enabled = false
	hoverHighlight.Parent = self._highlightHolder

	local armedHighlight = Instance.new("Highlight")
	armedHighlight.FillColor = ARMED_COLOR
	armedHighlight.OutlineColor = ARMED_COLOR
	armedHighlight.FillTransparency = ARMED_FILL_TRANSPARENCY
	armedHighlight.OutlineTransparency = ARMED_OUTLINE_TRANSPARENCY
	armedHighlight.Enabled = false
	armedHighlight.Parent = self._highlightHolder

	self._mouse = mouse
	self._raycastParams = raycastParams
	self._structureFolder = folder
	self._suppressedHighlights = {}
	self._hoverHighlight = self._placementCleaner:Add(hoverHighlight)
	self._armedHighlight = self._placementCleaner:Add(armedHighlight)
	self._pickupHighlights = self:_createPickupHighlights()

	-- On the cleaner rather than in _exitPlacement, so it also runs when the tool is destroyed.
	self._placementCleaner:Add(function()
		for _, highlight in self._suppressedHighlights do
			highlight.Enabled = true
		end
	end)

	self:_refreshPickupHighlights()

	-- Hover runs every frame; the calm pass under it is throttled, since it walks the whole base
	local sinceRefresh = 0

	self._placementCleaner:Connect(RunService.RenderStepped, function(deltaTime: number)
		self:_updateHoverTarget()

		sinceRefresh += deltaTime

		if sinceRefresh >= PICKUP_REFRESH_INTERVAL then
			sinceRefresh = 0
			self:_refreshPickupHighlights()
		end
	end)
end

-- Drops the ghost (or the pickup outlines) and everything driving it.
function BuildController:_exitPlacement()
	self._placementCleaner:Clean()

	self._structure = nil
	self._activeTool = nil
	self._mouse = nil
	self._ghost = nil
	self._ghostParts = nil
	self._ghostHighlight = nil
	self._ghostShown = nil
	self._ghostValid = nil
	self._rotation = 0
	self._raycastParams = nil
	self._ghostCFrame = nil
	self._targetCellX = nil
	self._targetCellZ = nil
	-- Left as a refusal rather than nil'd with the rest, for the reason given in _enterPlacement.
	self._refusal = REFUSAL_NO_SPOT
	self._structureFolder = nil
	self._hoverUid = nil
	self._hoverHighlight = nil
	self._armedUid = nil
	self._armedHighlight = nil
	self._pickupHighlights = nil
	self._suppressedHighlights = nil
end

-- Hooks one build tool. Anything else in the backpack isn't ours and is left alone.
function BuildController:_hookTool(tool: Tool)
	local isPickup = tool:GetAttribute(PICKUP_TOOL_ATTRIBUTE) == true

	if not isPickup and not tool:HasTag(STRUCTURE_TOOL_TAG) then
		return
	end

	if self._hookedTools[tool] then
		return
	end
	self._hookedTools[tool] = true

	-- Resolved once -- a tool never changes what it places. Nil leaves it inert rather than erroring
	local structure = Structures.GetStructureFromId(tool:GetAttribute(STRUCTURE_TOOL_ATTRIBUTE))

	self._characterCleaner:Connect(tool.Equipped, function(mouse: Mouse)
		if isPickup then
			self:_enterPickup(mouse)
		elseif structure then
			self:_enterPlacement(structure, mouse)
		else
			return
		end

		-- So the Destroying below can tell this tool running out from any other tool going away.
		self._activeTool = tool
	end)

	self._characterCleaner:Connect(tool.Unequipped, function()
		self:_exitPlacement()
	end)

	-- Placing the last of something destroys the tool, so the ghost must not outlive it
	self._characterCleaner:Connect(tool.Destroying, function()
		self._hookedTools[tool] = nil

		if self._activeTool == tool then
			self:_exitPlacement()
		end
	end)

	self._characterCleaner:Connect(tool.Activated, function()
		if isPickup then
			self:_tryPickup()
			return
		end

		-- On a phone any tap fires this, so placing belongs to the Place button alone
		if UserInputService.TouchEnabled then
			return
		end

		self:_tryPlace()
		self:_pressGuideEntry(GUIDE_PLACE_ENTRY, true)
	end)

	-- Off the tool rather than ContextActionService, which would swallow clicks game-wide
	self._characterCleaner:Connect(tool.Deactivated, function()
		if not isPickup then
			self:_pressGuideEntry(GUIDE_PLACE_ENTRY, false)
		end
	end)
end

-- Watches the backpack for each life's build tools, waited on since a respawn's arrives late.
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

	-- Timed out rather than waited on -- the guide is decoration, and building shouldn't hang on it
	self.UI = LocalPlayer.PlayerGui:WaitForChild(GUIDE_GUI_NAME, GUIDE_TIMEOUT)

	if not self.UI then
		warn(`[Build] PlayerGui.{GUIDE_GUI_NAME} is missing, so there's no on-screen build guide`)
	end
end

function BuildController:OnStart()
	-- A Highlight points by Adornee, so it needs a parent the outlined structure can't take down with it.
	self._highlightHolder = self._cleaner:Add(Instance.new("Folder"))
	self._highlightHolder.Name = "BuildHighlights"
	self._highlightHolder.Parent = LocalPlayer.PlayerGui

	self._cleaner:Connect(LocalPlayer.CharacterAdded, function()
		self:_watchCharacter()
	end)

	self._cleaner:Connect(LocalPlayer.CharacterRemoving, function()
		self:_exitPlacement()
	end)

	-- Covers characters already spawned, off the start thread since watching yields on the backpack
	if LocalPlayer.Character then
		task.spawn(function()
			self:_watchCharacter()
		end)
	end

	-- Both can happen with a tool in hand, so floors are re-read. Off the start thread, since it yields
	self._cleaner:Connect(LocalPlayer:GetAttributeChangedSignal("BaseId"), function()
		self:_refreshGround()
		self:_refreshRaycastParams()
	end)

	task.spawn(function()
		self._cleaner:Add(PlayerDataController:ListenForChange("Plots", function()
			self:_refreshGround()
			self:_refreshRaycastParams()
		end))

		self:_refreshGround()
		self:_refreshRaycastParams()
	end)
end

return BuildController
