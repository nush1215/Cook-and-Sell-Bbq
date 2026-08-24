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

-- Required on first use rather than at the top of the file. On a touch device this module yields at
-- require time waiting on Roblox's TouchGui, which doesn't exist until the player's touch controls are
-- up -- later than the Loader requires its controllers. A top-level require would therefore hold the
-- whole client boot behind it on mobile. By the time a build tool is equipped there's a character, so
-- the wait is already over and this resolves instantly.
local ContextActionUtility

--
local LocalPlayer = Players.LocalPlayer

-- What BuildManager marks its tools with. The tag is on the ones that place a structure and the
-- attribute beside it says which; the pickup tool wears its own attribute instead, being a mode
-- rather than something the player owns any number of.
local STRUCTURE_TOOL_TAG = "StructureTool"
local STRUCTURE_TOOL_ATTRIBUTE = "StructureId"
local PICKUP_TOOL_ATTRIBUTE = "PickupTool"

local VALID_COLOR = Color3.fromRGB(0, 255, 0)
local INVALID_COLOR = Color3.fromRGB(220, 70, 70)
-- The ghost keeps its own colours and wears the verdict as an outline around them, so what the player
-- is judging the fit of is the structure itself rather than a tinted silhouette of one. The fill only
-- takes the flatness off the outline.
local GHOST_FILL_TRANSPARENCY = 0.3
local GHOST_OUTLINE_TRANSPARENCY = 0

-- The calm pass the pickup tool puts over every structure it could take back. Faint on purpose, and
-- occluded rather than drawn through walls: a whole base outlined at once should read as outlined,
-- not washed white.
local PICKUP_COLOR = Color3.fromRGB(255, 255, 255)
local PICKUP_FILL_TRANSPARENCY = 0.85
local PICKUP_OUTLINE_TRANSPARENCY = 0.25

-- The one under the cursor. Sits between the white above and the red below on the way to warm, so
-- pointing at a structure and then picking it reads as one action getting closer rather than as two
-- unrelated colours -- and stronger than the calm pass, because there's only ever one of these.
local HOVER_COLOR = Color3.fromRGB(255, 150, 45)
local HOVER_FILL_TRANSPARENCY = 0.7
local HOVER_OUTLINE_TRANSPARENCY = 0

-- The one that's been picked and is waiting on a second click. Left at a Highlight's default
-- AlwaysOnTop, unlike the two passes above: the structure a click would take down has to be
-- unmistakable even with something standing in front of it. The fill is kept faint so its own colours
-- still show through -- you're picking one of several near-identical things out of a row.
local ARMED_COLOR = Color3.fromRGB(220, 70, 70)
local ARMED_FILL_TRANSPARENCY = 0.6
local ARMED_OUTLINE_TRANSPARENCY = 0

-- Roblox renders at most 31 Highlights at once and silently drops the rest, so a big enough base would
-- otherwise push the red one out of the pool and leave the click that matters unmarked. The calm pass
-- is therefore a fixed number of highlights handed to whichever structures are nearest the camera,
-- with headroom left for the game's own outlines (BreathingHighlight, PromptSubjectHighlight).
local PICKUP_HIGHLIGHT_BUDGET = 24
-- Seconds between re-picking which structures wear them. Lower = the pass keeps up with a fast camera
-- more closely; each one walks every structure on the base.
local PICKUP_REFRESH_INTERVAL = 0.2

local RAY_LENGTH = 1000
local ROTATE_KEY = Enum.KeyCode.R

-- Where a touch player's ghost sits, there being no cursor to point with: this far ahead of them, and
-- aimed at from this far above so the ray comes down onto the floor rather than into their own back.
-- Distance wants tuning on a real device -- too close and the character's own body hides the ghost,
-- too far and it's hard to tell which cell it's on.
local TOUCH_AIM_DISTANCE = 8
local TOUCH_AIM_HEIGHT = 12

-- The two actions a player drives placement with. Both are bound through ContextActionUtility, which
-- pairs the binding with an on-screen button on touch devices and does nothing extra anywhere else --
-- so these are what gives a phone a way to rotate at all, there being no key to press.
local PLACE_ACTION = "BuildPlace"
local ROTATE_ACTION = "BuildRotate"

-- The guide telling a desktop player what to press while they're placing -- the counterpart to the
-- touch buttons above, since on a keyboard the controls exist but nothing on screen says so. Authored
-- in the place file under StarterGui, so these are the names it's found by.
local GUIDE_GUI_NAME = "BuildingUI"
local GUIDE_FRAME_NAME = "PCGuide"
local GUIDE_PLACE_ENTRY = "Place"
local GUIDE_ROTATE_ENTRY = "Rotate"
local GUIDE_TIMEOUT = 10

-- Lifted from UIController's own button springs, so holding a key presses its hint exactly the way
-- clicking presses a button anywhere else in the game, rather than in a second, nearly-identical way.
local GUIDE_PRESS_SCALE = 0.93
local GUIDE_NORMAL_SCALE = 1
local GUIDE_DAMPING = 0.45
local GUIDE_FREQUENCY = 6

-- Higher = the guide catches up to the cursor faster.
local GUIDE_FOLLOW_SPEED = 25
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

    The pickup tool is the other half of that, and works by pointing rather than dragging. Equipping it
    outlines every structure on the base as something that can be taken back; the one under the cursor
    warms to orange; and it takes two clicks on one to send it -- the first picks it and turns it red,
    the second commits. So a structure says it can go, then that it's the one being aimed at, then that
    it's about to, and the click that removes something is never the click that found it -- which
    matters, because a griller's contents don't come back with it.
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

-- An inert copy of what the tool builds, left looking exactly as it will once it's down. Whether the
-- spot is any good is said by a Highlight around it rather than by recolouring it, so the player is
-- always looking at the real thing.
--
-- Stripped of anything that would make it act like that real thing: it can't be collided with, can't
-- be raycast against (or it'd block its own placement ray), and carries no tag, so no controller
-- mistakes it for a structure that exists.
function BuildController:_createGhost(structure: Structures.Structure): Model
	local ghost = structure.Model:Clone()

	local parts = {}
	for _, descendant in ghost:GetDescendants() do
		if descendant:IsA("BasePart") then
			-- Kept alongside the part so hiding the ghost can put it back: one authored invisible on
			-- purpose (a hitbox, a mount) has to stay invisible when the ghost returns.
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

	-- Parented away from the thing it outlines, like the pickup ones, so it can be pointed at the
	-- ghost without living inside it.
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

-- Marks the spot under the cursor good or bad, or takes the ghost out of sight entirely when there's
-- nowhere to put it at all -- one left standing at the last spot the cursor was over reads as a
-- placement that's still on offer.
function BuildController:_paintGhost(shown: boolean, valid: boolean?)
	if not self._ghostParts then
		return
	end

	-- Both halves only act on an actual change. This runs every frame the cursor moves, and a ghost is
	-- a whole model of parts -- so a verdict that hasn't flipped shouldn't cost a write per part.
	if shown ~= self._ghostShown then
		self._ghostShown = shown

		for _, entry in self._ghostParts do
			entry.Part.Transparency = if shown then entry.Transparency else 1
		end

		if self._ghostHighlight then
			self._ghostHighlight.Enabled = shown
		end
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

-- The ray the ghost is aimed down. On a desktop that's the cursor; a phone hasn't got one, so it's a
-- fixed spot in front of the player instead -- they aim by walking and turning, which also means the
-- ghost is always somewhere they could stand rather than across the base from them.
--
-- The touch ray points straight down rather than forward, so where the ghost lands doesn't shift with
-- how the camera happens to be tilted, and so it comes down onto the floor through the same
-- owned-plots filter the cursor ray already goes through. Facing off the edge of a plot simply misses,
-- which the caller already reads as nowhere to put it.
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

	local origin = root.Position
		+ root.CFrame.LookVector * TOUCH_AIM_DISTANCE
		+ Vector3.new(0, TOUCH_AIM_HEIGHT, 0)

	return Ray.new(origin, Vector3.new(0, -1, 0))
end

-- Follows whatever is being aimed at: raycast the owned floors, snap to the cell the footprint would
-- sit on, and record it for _tryPlace. Only how the ghost looks is eased -- the cell it reports is
-- exact, so what gets sent is never a frame behind what was shown.
function BuildController:_updateGhost(deltaTime: number)
	local ghost = self._ghost
	local ray = self:_getAimRay()
	if not (ghost and ray) then
		return
	end

	local result = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, self._raycastParams)

	-- Off every plot they own, so there's nothing to snap to.
	if not result then
		self._valid = false
		self:_paintGhost(false)
		return
	end

	local floor = result.Instance
	local plotId = self._floors[floor]

	if not plotId then
		self._valid = false
		self:_paintGhost(false)
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
	self:_paintGhost(true, valid)
end

-- The pool the calm pass is drawn from, made once per equip. Fixed in size rather than one highlight
-- per structure, because Roblox renders a limited number of them at a time -- see the budget above.
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

-- Hands the pool to the structures nearest the camera, which is what keeps the outlines on the part of
-- the base the player is actually looking at once there are more structures than highlights to go
-- round. Walked rather than cached: it runs a few times a second against a few dozen models, and
-- caching would mean invalidating on every placement, pickup and camera move for no measurable gain.
function BuildController:_refreshPickupHighlights()
	local origin = workspace.CurrentCamera.CFrame.Position
	local models = {}

	for _, model in self._structureFolder:GetChildren() do
		local uid = model:GetAttribute(Structures.UID_ATTRIBUTE)

		-- The hovered and armed ones wear their own highlights instead. Two Highlights sharing an adornee
		-- is undefined -- Roblox renders one of them and there's no saying which -- so the calm pass has
		-- to leave those two be rather than layer over them.
		if uid and uid ~= self._armedUid and uid ~= self._hoverUid then
			table.insert(models, model)
		end
	end

	-- Only worth ordering when there are more structures than highlights; below that every one gets an
	-- outline whatever order they come out in.
	if #models > PICKUP_HIGHLIGHT_BUDGET then
		local distances = {}
		for _, model in models do
			distances[model] = (model:GetPivot().Position - origin).Magnitude
		end

		table.sort(models, function(a, b)
			return distances[a] < distances[b]
		end)
	end

	-- Disabled rather than merely unadorned past the end of the list, so a spare doesn't sit in Roblox's
	-- limited pool of active highlights while showing nothing.
	for index, highlight in self._pickupHighlights do
		local model = models[index]

		highlight.Adornee = model
		highlight.Enabled = model ~= nil
	end
end

-- Turns off the own outlines of whichever structures this tool is painting, and puts back the ones it
-- no longer is. A structure's own Highlight and ours would otherwise fight over the adornee -- Roblox
-- renders one of them and there's no saying which -- and a griller with a cooked skewer on it is
-- breathing gold exactly when you'd want to take it down. So without this, hover and the red confirm
-- would both be a coin toss against the very structures they matter most on.
--
-- Recomputed from scratch on every change rather than patched: there are at most two of them, and the
-- alternative is remembering which of the pair each suppressed highlight belonged to.
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

-- Whichever of the player's structures is under the cursor, and its uid.
--
-- Both come back nil when the cursor is off the base, and also for a structure that's just gone down
-- whose uid hasn't replicated yet: there'd be nothing to send for it, so marking it would promise a
-- click that couldn't be honoured.
function BuildController:_getStructureUnderCursor(): (Model?, string?)
	local ray = self._mouse.UnitRay
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
	if not uid then
		return nil, nil
	end

	return model, uid
end

-- Follows the cursor: warms whichever structure is under it, so what a click would pick is visible
-- before one is spent finding out. The armed structure is deliberately left out -- it's already been
-- picked and is wearing red, and pointing at it again says nothing new.
function BuildController:_updateHoverTarget()
	local model, uid = self:_getStructureUnderCursor()

	if uid == self._armedUid then
		model, uid = nil, nil
	end

	-- Runs every frame, and both refreshes below are real work -- so a cursor that hasn't left the
	-- structure it was on shouldn't cost anything.
	if uid == self._hoverUid then
		return
	end

	self._hoverUid = uid
	self._hoverHighlight.Adornee = model
	self._hoverHighlight.Enabled = model ~= nil

	self:_refreshSuppressedHighlights()
	self:_refreshPickupHighlights()
end

-- Picks the structure a second click would take back, or drops the pick when given nothing. Passing
-- the model as well as its uid rather than looking it up: the caller has just raycast it, and the uid
-- is what crosses the wire while the model is what gets outlined.
function BuildController:_armPickup(model: Model?, uid: string?)
	if self._armedUid == uid then
		return
	end

	self._armedUid = uid
	self._armedHighlight.Adornee = model
	self._armedHighlight.Enabled = model ~= nil

	-- Red takes the structure off the hover pass. Two of our own outlines on one adornee would fight
	-- exactly the way a structure's own does, and having just been clicked it's plainly the one meant.
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

	-- Straight away rather than at the next tick, so the structure just picked leaves the other two
	-- passes (or the one just dropped rejoins them) in the same frame as the click.
	self:_refreshSuppressedHighlights()
	self:_refreshPickupHighlights()
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

-- The pickup tool's click. The first one on a structure picks it, the second one on the same structure
-- sends it, and a click on anything else -- another structure, the ground, the sky -- moves or drops
-- the pick. So nothing is ever taken back by a click that wasn't aimed at it twice.
function BuildController:_tryPickup()
	-- Nothing to point with, so the tool was equipped before the player had a base to point at.
	if not self._mouse then
		return
	end

	-- Raycast afresh rather than reading what the hover loop last saw. On a touch device the tap that
	-- gets here and the frame that moves the cursor to it aren't ordered against each other, so a
	-- remembered target could be one tap behind -- and this is the click that takes something down.
	local model, uid = self:_getStructureUnderCursor()

	if uid ~= self._armedUid then
		self:_armPickup(model, uid)
		return
	end

	-- Nothing under the cursor and nothing picked, so the click was at empty ground twice over.
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
		if (footprintX <= countX and footprintZ <= countZ) or (footprintZ <= countX and footprintX <= countZ) then
			return
		end

		warn(
			`[Build] {structure.Name} is {footprintX}x{footprintZ} cells and plot {plotId} is only `
				.. `{countX}x{countZ} ({Structures.CELL_SIZE} studs each), so it can't fit`
		)
	end
end

-- The guide frame, or nil if the place file hasn't got one. Re-resolved rather than kept, because a
-- ScreenGui with ResetOnSpawn left on is rebuilt with every character -- so a reference taken once
-- would be pointing at a destroyed frame from the first respawn onwards.
function BuildController:_getGuide(): Frame?
	if self._guide and self._guide.Parent then
		return self._guide
	end

	self._guide = self.UI and self.UI:FindFirstChild(GUIDE_FRAME_NAME)

	return self._guide
end

-- One entry of the guide, by name.
function BuildController:_getGuideScale(entryName: string): UIScale?
	local guide = self:_getGuide()
	local entry = guide and guide:FindFirstChild(entryName)

	return entry and entry:FindFirstChildOfClass("UIScale")
end

-- Squashes one entry of the guide while its input is held, and lets it back out on release. Reads as a
-- button being pressed because it's the same spring UIController puts on every other button.
function BuildController:_pressGuideEntry(entryName: string, pressed: boolean)
	local uiScale = self:_getGuideScale(entryName)

	-- No guide up: either the place file hasn't got one, or this is a phone, or the tool was put away
	-- mid-press. Nothing to squash either way.
	if not uiScale then
		return
	end

	Spr.target(uiScale, GUIDE_DAMPING, GUIDE_FREQUENCY, {
		Scale = if pressed then GUIDE_PRESS_SCALE else GUIDE_NORMAL_SCALE,
	})
end

-- Puts the guide up for the length of a placement, or takes it down.
function BuildController:_showGuide(shown: boolean)
	local guide = self:_getGuide()
	if not guide then
		return
	end

	-- Desktop only. A phone gets the touch buttons instead, and its "cursor" is wherever a finger last
	-- landed -- so a hint chasing it would sit under the player's own thumb. Forced down rather than
	-- left alone, since the frame may well be authored visible in the place file.
	if UserInputService.TouchEnabled then
		shown = false
	end

	-- Both entries go back to full size as the guide goes *up* rather than as it comes down. A spring
	-- left running on a hidden frame would still be settling if the player swapped tools quickly, so
	-- resetting on the way in is what makes the guide crisp however it was last put away. Stopped
	-- before it's written, since a live spring would otherwise carry on over the value.
	if shown then
		for _, entryName in { GUIDE_PLACE_ENTRY, GUIDE_ROTATE_ENTRY } do
			local uiScale = self:_getGuideScale(entryName)

			if uiScale then
				Spr.stop(uiScale, "Scale")
				uiScale.Scale = GUIDE_NORMAL_SCALE
			end
		end
	end

	guide.Visible = shown

	-- Dropped so the next placement starts on the cursor rather than gliding in from wherever the last
	-- one was left.
	self._guidePosition = nil
end

-- Glides the guide to the cursor. Eased rather than pinned so it trails the pointer slightly and
-- settles, which reads as something following the mouse rather than something stuck to it.
function BuildController:_updateGuide(deltaTime: number)
	local guide = self:_getGuide()
	if not guide or not guide.Visible then
		return
	end

	local mouse = UserInputService:GetMouseLocation()

	-- GetMouseLocation is measured from below the topbar, and so is a ScreenGui's own origin -- unless
	-- it ignores the inset, in which case it measures from the very top and the inset has to go back
	-- on. Read off the gui rather than assumed, since that's a property of the place file.
	local target = if self.UI.IgnoreGuiInset then mouse + GuiService:GetGuiInset() else mouse

	-- The first frame snaps outright, and math.exp keeps the glide the same speed whatever the
	-- framerate -- the same easing the ghost uses over the grid.
	if self._guidePosition then
		self._guidePosition = self._guidePosition:Lerp(target, 1 - math.exp(-GUIDE_FOLLOW_SPEED * deltaTime))
	else
		self._guidePosition = target
	end

	-- Position only: the anchor point is authored, and it's what decides where the frame sits relative
	-- to the pointer.
	guide.Position = UDim2.fromOffset(self._guidePosition.X, self._guidePosition.Y)
end

-- Binds placing and rotating for as long as the ghost is up, and puts an on-screen button behind each
-- on a touch device -- which is the whole point, since rotation is otherwise a key a phone hasn't got.
-- Bound per placement rather than once, so the buttons are on screen exactly while there's something
-- to aim.
--
-- Place is bound to no key at all: on a desktop it's the tool's own click that commits, and on a phone
-- it's the button. Rotate takes the key as well, so one handler serves both rather than a keyboard
-- path and a touch path that can drift apart.
function BuildController:_bindPlacementActions()
	ContextActionUtility = ContextActionUtility or require(Modules.ContextActionUtlity)

	-- The touch buttons report the press, the drag and the release alike, so without this a tap would
	-- count twice and a rotate would turn half a circle.
	local function onPlace(_actionName: string, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			self:_tryPlace()
		end
	end

	-- Rotation carries across placements until the tool is put away, so laying out a row of things all
	-- facing the same way is one press rather than one per copy.
	--
	-- The release is worth listening for even though nothing turns on it: it's what lets the hint on
	-- screen come back out of its press, so holding the key holds the button down.
	local function onRotate(_actionName: string, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			self._rotation = (self._rotation + 1) % 4
			self:_pressGuideEntry(GUIDE_ROTATE_ENTRY, true)
		elseif inputState == Enum.UserInputState.End then
			self:_pressGuideEntry(GUIDE_ROTATE_ENTRY, false)
		end
	end

	-- Place first, so it takes the slot nearest the jump button: it's the action being aimed at, and
	-- rotate is the one you reach past it for.
	ContextActionUtility:BindAction(PLACE_ACTION, onPlace, true)
	ContextActionUtility:SetTitle(PLACE_ACTION, "Place")

	ContextActionUtility:BindAction(ROTATE_ACTION, onRotate, true, ROTATE_KEY)
	ContextActionUtility:SetTitle(ROTATE_ACTION, "Rotate")

	self._placementCleaner:Add(function()
		ContextActionUtility:UnbindAction(PLACE_ACTION)
		ContextActionUtility:UnbindAction(ROTATE_ACTION)
	end)
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
		self:_updateGuide(deltaTime)
	end)

	self:_bindPlacementActions()

	-- Only for building: the pickup tool has nothing to rotate and its click picks rather than places,
	-- so _enterPickup deliberately leaves the guide down.
	self:_showGuide(true)

	-- Registered rather than called from _exitPlacement, so the guide goes down with everything else
	-- driving the ghost -- including when the tool is destroyed out from under it.
	self._placementCleaner:Add(function()
		self:_showGuide(false)
	end)
end

-- Raises the calm pass over everything on the base that can be taken back, and stands ready for the
-- clicks. Everything it sets up hangs off the placement cleaner, so putting the tool away puts the
-- base back exactly as it was -- including any outlines a pick had turned off.
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

	-- Occluded like the calm pass, since what's under the cursor is by definition something the player
	-- can see.
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

	-- Registered rather than called from _exitPlacement, so a structure's own outlines come back with
	-- everything else -- including when the tool is destroyed out from under a pick.
	self._placementCleaner:Add(function()
		for _, highlight in self._suppressedHighlights do
			highlight.Enabled = true
		end
	end)

	self:_refreshPickupHighlights()

	-- Hover is chased every frame, the way the ghost chases the cursor -- it's answering "what am I
	-- pointing at", so a frame of lag reads as the outline sticking. Which structures are nearest the
	-- camera can't meaningfully change that fast and costs a walk of the whole base to work out, so the
	-- calm pass underneath it is throttled instead.
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
	self._targetPlotId = nil
	self._targetCellX = nil
	self._targetCellZ = nil
	self._valid = false
	self._structureFolder = nil
	self._hoverUid = nil
	self._hoverHighlight = nil
	self._armedUid = nil
	self._armedHighlight = nil
	self._pickupHighlights = nil
	self._suppressedHighlights = nil
end

-- Hooks one build tool, so equipping it starts placement and using it commits. Anything else in the
-- backpack -- sticks, ingredients, crates -- isn't ours and is left alone.
function BuildController:_hookTool(tool: Tool)
	local isPickup = tool:GetAttribute(PICKUP_TOOL_ATTRIBUTE) == true

	if not isPickup and not tool:HasTag(STRUCTURE_TOOL_TAG) then
		return
	end

	if self._hookedTools[tool] then
		return
	end
	self._hookedTools[tool] = true

	-- Which structure this tool places, resolved once: a tool is built for one kind and never changes
	-- kind, only how many of it are left. Nil for the pickup tool, and for a tool naming a structure
	-- the config dropped for want of a model -- which leaves it inert in the hand rather than erroring.
	local structure = Structures.GetStructureFromId(tool:GetAttribute(STRUCTURE_TOOL_ATTRIBUTE))

	self._characterCleaner:Connect(tool.Equipped, function(mouse: Mouse)
		if isPickup then
			self:_enterPickup(mouse)
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
		if isPickup then
			self:_tryPickup()
		else
			self:_tryPlace()
			self:_pressGuideEntry(GUIDE_PLACE_ENTRY, true)
		end
	end)

	-- The release half of the click, purely so the hint on screen comes back out of its press. Taken
	-- off the tool rather than by binding the mouse button through ContextActionService, which would
	-- swallow clicks game-wide for as long as a build tool was in hand.
	self._characterCleaner:Connect(tool.Deactivated, function()
		if not isPickup then
			self:_pressGuideEntry(GUIDE_PLACE_ENTRY, false)
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

	-- Waited on with a timeout rather than indefinitely: a missing guide should cost the player their
	-- on-screen hint and nothing else, where an open-ended wait would hold this whole controller --
	-- and so building itself -- on a piece of UI that's only ever decoration.
	self.UI = LocalPlayer.PlayerGui:WaitForChild(GUIDE_GUI_NAME, GUIDE_TIMEOUT)

	if not self.UI then
		warn(`[Build] PlayerGui.{GUIDE_GUI_NAME} is missing, so there's no on-screen build guide`)
	end
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
