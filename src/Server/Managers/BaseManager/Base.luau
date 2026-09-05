-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Managers
local CollisionManager = require(script.Parent.Parent.CollisionManager)
local EffectManager = require(script.Parent.Parent.EffectManager)
local SoundManager = require(script.Parent.Parent.SoundManager)

-- Shared
local Shared = ReplicatedStorage.Shared
local BaseUnlocks = require(Shared.Config.BaseUnlocks)
local Plots = require(Shared.Config.Plots)
local Structures = require(Shared.Config.Structures)
local GridUtil = require(Shared.GridUtil)

-- Assets
local UI = ReplicatedStorage.Assets.UI

--
local SPAWN_HEIGHT_OFFSET = 5
local RESPAWN_DELAY = 5

-- Under SoundService.Building, played positionally so a visitor hears a base being rearranged where it happens
local PLACE_SOUND = "Place"
local TAKE_SOUND = "Take"

-- Names both the folder authored onto each base and the ReplicatedStorage folder they're parked under.
local TUTORIAL_GUIDES_NAME = "TutorialGuides"

-- One base in the world: renders its owner's unlocks, plots and build server-side, since player data only replicates to its owner.

-- Made on first use, so adding a base to the place file needs nothing done to it.
local function getTutorialGuideHolder(): Folder
	local holder = ReplicatedStorage:FindFirstChild(TUTORIAL_GUIDES_NAME)
	if not holder then
		holder = Instance.new("Folder")
		holder.Name = TUTORIAL_GUIDES_NAME
		holder.Parent = ReplicatedStorage
	end

	return holder :: Folder
end

--
local Base = {}
Base.__index = Base

function Base.new(model: Model)
	--
	local cleaner = Trove.new()

	-- Parked out of the world, keyed by base: they're one player's tutorial cue, and each carries its authored pose
	local guides = model:FindFirstChild(TUTORIAL_GUIDES_NAME)
	if guides then
		guides.Name = model.Name
		guides.Parent = getTutorialGuideHolder()
	end

	-- Layout templates, off the cleaner -- destroying it would take the templates with it
	local storage = Instance.new("Folder")
	storage.Name = `BaseStorage_{model.Name}`
	storage.Parent = ServerStorage

	-- Made rather than authored, and off the cleaner, since it outlives every owner the base has
	local structureFolder = Instance.new("Folder")
	structureFolder.Name = Structures.FOLDER_NAME
	structureFolder.Parent = model

	--
	local self = setmetatable({
		--
		_model = model,
		_spawn = model.Core.PlayerSpawn,
		_stallBoard = model.Stalls.SellStall.Structure.BoardSign.Board,
		_nameplateAttachment = model.BaseAttachment,
		_owner = nil,

		--
		_storage = storage,
		_layouts = {}, -- [unlockId] = { Template, Home, Center, Step: Vector2, Spec, Count, Clones }  (Layout)
		-- [plotId] = { Model, Sign, Misc, Floor }. The starting cell has neither Sign nor Misc, but its floor sets the grid
		_plots = {},
		-- [plotId] = the token for the pull waiting on that plot's burn -- see ApplyPlots
		_clearing = {},

		_structureFolder = structureFolder,
		_structures = {}, -- [uid] = the live model for that placed structure

		--
		_cleaner = cleaner,
		_ownerCleaner = cleaner:Construct(Trove),
		_characterCleaner = cleaner:Construct(Trove),
	}, Base)

	self:_cacheUnlocks()
	self:_cachePlots()

	-- Nobody owns it yet, and the caches above had to read the authored state before anything renders.
	self:ApplyUnlocks(BaseUnlocks.NO_UNLOCKS)
	self:ApplyPlots({})

	return self
end

-- Caches each unlock's authored state: a Layout group pulls its template out of the world, a Ghost needs nothing.
function Base:_cacheUnlocks()
	for _, unlock in BaseUnlocks.Data do
		-- A Stat group has nothing in the world -- no Path to walk and nothing to pull out of it.
		if unlock.LockStyle == "Stat" then
			continue
		end

		local folder = self._model
		for _, segment in unlock.Path do
			folder = folder:FindFirstChild(segment)

			-- Skipped rather than thrown -- BaseManager's OnInit is pcall'd, and erroring would leave every base unassigned
			if not folder then
				warn(`[Base] {self._model.Name} has no {table.concat(unlock.Path, ".")}, {unlock.Id} won't render`)
				break
			end
		end

		if not folder then
			continue
		end

		-- Layout: pull the authored template out of the world, and record its centre and copy spacing.
		if unlock.LockStyle == "Layout" then
			local template = folder:FindFirstChild("1")
			if not template then
				warn(`[Base] {self._model.Name} {unlock.Id} has no "1" template, won't render`)
				continue
			end

			-- Size drives spacing so copies never overlap; columns run along local X, rows along local Z
			local _, size = template:GetBoundingBox()
			local padding = unlock.Layout.Padding

			self._layouts[unlock.Id] = {
				Template = template,
				Home = folder,
				Center = template:GetPivot(),
				Step = Vector2.new(size.X + padding, size.Z + padding),
				Spec = unlock.Layout,
				Count = 0,
				Clones = {}, -- [i] = the live clone for slot i
			}

			template.Parent = self._storage
			continue
		end
	end
end

-- Caches each plot's sign, overgrowth and floor. The starting cell is in here too -- its floor sets the base's grid.
function Base:_cachePlots()
	local folder = self._model:FindFirstChild(Plots.FOLDER_NAME)

	-- Warn rather than throw -- BaseManager's OnInit is pcall'd, and erroring would leave every base unassigned
	if not folder then
		warn(`[Base] {self._model.Name} has no {Plots.FOLDER_NAME}, its plots won't render`)
		return
	end

	for _, plotModel in folder:GetChildren() do
		-- Anything in the folder that isn't a plot or the starting cell isn't ours to drive.
		local isStart = plotModel.Name == Plots.START
		if not isStart and not Plots.IsPlot(plotModel.Name) then
			continue
		end

		-- Parked and parented back, not hidden and restored: one move, and nothing has to remember the authored state
		local sign = if isStart then nil else plotModel:FindFirstChild(Plots.SIGN_NAME)
		local misc = if isStart then nil else plotModel:FindFirstChild(Plots.MISC_FOLDER_NAME)

		if not isStart and not sign then
			warn(`[Base] {self._model.Name} plot {plotModel.Name} has no {Plots.SIGN_NAME}, it can't be bought`)
		end

		if not isStart and not misc then
			warn(
				`[Base] {self._model.Name} plot {plotModel.Name} has no {Plots.MISC_FOLDER_NAME}, `
					.. `it has no overgrowth to clear`
			)
		end

		-- Searched, so a floor nested inside the plot's own structure still counts; without one it isn't buildable
		local floor = plotModel:FindFirstChild(Plots.FLOOR_NAME, true)

		if not floor or not floor:IsA("BasePart") then
			warn(
				`[Base] {self._model.Name} plot {plotModel.Name} has no {Plots.FLOOR_NAME} part, `
					.. `nothing can be built on it`
			)
			floor = nil
		end

		self._plots[plotModel.Name] = {
			Model = plotModel,
			Sign = sign,
			Misc = misc,
			Floor = floor,
		}
	end

	-- Said once here rather than at every placement and render. Without it there's no grid to measure
	if not self:GetPlotFloor(Plots.START) then
		warn(
			`[Base] {self._model.Name} has no {Plots.START} {Plots.FLOOR_NAME}, `
				.. `so its grid can't be measured and nothing can be built on it`
		)
	end
end

-- Renders the base's plots and their buy signs. `animate` marks a render following a purchase, which burns.
function Base:ApplyPlots(plots: { [string]: boolean }, animate: boolean?)
	for plotId, plot in self._plots do
		-- Cached with the plots so building can find its floor, but there's nothing to render on it.
		if plotId == Plots.START then
			continue
		end

		local isUnlocked = plots[plotId] == true

		-- The last render's value is all the history needed to spot the locked -> unlocked edge
		local wasUnlocked = plot.Model:GetAttribute("Unlocked") == true
		plot.Model:SetAttribute("Unlocked", isUnlocked or nil)

		-- Burned, not snapped, on the plot that just changed hands; EffectManager culls by distance from it
		local burning = animate and isUnlocked and not wasUnlocked
		if burning then
			EffectManager:RunEffect("All", "PlotCleared", { plot.Model })
		end

		-- Overgrowth leaves the world outright, so cleared ground has nothing to collide with or stream back in
		if plot.Misc then
			if not isUnlocked then
				-- Cancels any pending pull, so an owner leaving mid-clear can't have one fire on the plot just put back
				self._clearing[plotId] = nil
				plot.Misc.Parent = plot.Model
			elseif burning then
				-- A token, not a flag: it answers both "is a pull coming" and "am I still the pull that should run"
				local token = {}
				self._clearing[plotId] = token

				task.delay(Plots.CLEAR_HOLD + Plots.CLEAR_FADE + Plots.CLEAR_PARK_GRACE, function()
					if self._clearing[plotId] ~= token then
						return
					end

					self._clearing[plotId] = nil
					plot.Misc.Parent = self._storage
				end)
			elseif not self._clearing[plotId] then
				plot.Misc.Parent = self._storage
			end
		end

		-- Only currently-buyable plots wear a board, so a price is never shown on an unreachable plot.
		if plot.Sign then
			plot.Sign.Parent = if Plots.IsAvailable(plotId, plots) then plot.Model else self._storage
		end
	end
end

-- Places copy `index` of `count`; rows grow toward +Z, so the front row keeps the template's authored spot.
function Base:_slotCFrame(layout, index: number, count: number): CFrame
	local cols = layout.Spec.MaxPerRow
	local row = math.floor((index - 1) / cols)
	local inRow = math.min(cols, count - row * cols)
	local col = (index - 1) - row * cols

	local x = (col - (inRow - 1) / 2) * layout.Step.X
	local z = row * layout.Step.Y

	return layout.Center * CFrame.new(x, 0, z)
end

-- Renders the base at the given unlock levels, a Layout group showing `level` copies in a centred grid.
function Base:ApplyUnlocks(unlocks: { [string]: number }, animate: boolean?)
	for _, unlock in BaseUnlocks.Data do
		-- Two hand-kept tables in different files, and staying locked beats never spawning the player
		local level = unlocks[unlock.Id] or 0

		if unlock.LockStyle == "Layout" then
			local layout = self._layouts[unlock.Id]

			-- The count check matters because the listener re-applies the whole table, which would churn the folder
			if not layout then
				continue
			end

			local target = math.min(level, unlock.Limit)
			if target == layout.Count then
				continue
			end

			-- Downgrade: drop the copies past the new count.
			for i = target + 1, layout.Count do
				layout.Clones[i]:Destroy()
				layout.Clones[i] = nil
			end

			-- Upgrade: make the new copies (positioned + handed to the client in the loop below).
			for i = layout.Count + 1, target do
				local clone = layout.Template:Clone()
				clone.Name = tostring(i)

				-- Whole or not at all -- the client builds a class per copy and reads its parts, delivered late by default
				clone.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

				layout.Clones[i] = clone
			end

			-- The server only says where each copy goes; a fresh one starts below its slot so it rises
			for i = 1, target do
				local slot = self:_slotCFrame(layout, i, target)
				local clone = layout.Clones[i]

				if not clone.Parent then
					clone:PivotTo(slot * CFrame.new(0, -BaseUnlocks.LAYOUT_RISE, 0))
					clone:ScaleTo(BaseUnlocks.LAYOUT_ENTRANCE_SCALE)
					clone:SetAttribute("SlotCFrame", slot)

					-- An attribute, not a remote: the copy is parented this same frame, so a remote could beat it to a client
					if animate then
						clone:SetAttribute("PulseOnSpawn", true)
					end

					clone:AddTag("LayoutStand")
					clone.Parent = layout.Home

					-- Settled once the rise lands, plus scale, since a fresh copy starts undersized as well as sunk
					task.delay(BaseUnlocks.LAYOUT_SETTLE_TIME, function()
						if clone.Parent then
							clone:PivotTo(clone:GetAttribute("SlotCFrame"))
							clone:ScaleTo(1)
							clone:SetAttribute("PulseOnSpawn", nil)
						end
					end)
				else
					clone:SetAttribute("SlotCFrame", slot)
				end
			end

			layout.Count = target

			continue
		end
	end
end

-- The part a plot's build grid is measured off, or nil for a plot that has none (or isn't a plot).
function Base:GetPlotFloor(plotId: string): BasePart?
	local plot = self._plots[plotId]
	return plot and plot.Floor
end

-- The buildable cells for `plots`: one lattice across the base, owned floors saying which of it is theirs.
function Base:GetGround(plots: { [string]: boolean }): GridUtil.Ground?
	local startFloor = self:GetPlotFloor(Plots.START)
	if not startFloor then
		return nil
	end

	local floors = {}

	for plotId, plot in self._plots do
		if plot.Floor and Plots.IsOwned(plotId, plots) then
			table.insert(floors, plot.Floor)
		end
	end

	return GridUtil.BuildGround(startFloor, floors, Structures.CELL_SIZE)
end

-- Where a structure on this cell sits. Cells are stored, not poses -- a player gets whichever base is free.
function Base:GetCellPose(
	structure: Structures.Structure,
	cellX: number,
	cellZ: number,
	rotation: number
): CFrame?
	local startFloor = self:GetPlotFloor(Plots.START)
	if not startFloor then
		return nil
	end

	local footprintX, footprintZ = Structures.GetFootprint(structure, rotation)
	local surface = GridUtil.CellToSurfaceCFrame(
		GridUtil.GetOrigin(startFloor),
		cellX,
		cellZ,
		footprintX,
		footprintZ,
		Structures.CELL_SIZE
	)

	return Structures.GetPlacementPivot(structure.Model, surface, rotation)
end

-- Whether a footprint fits: every cell on owned ground, nothing built in the way. Authoritative.
function Base:IsBlockFree(
	cellX: number,
	cellZ: number,
	footprintX: number,
	footprintZ: number,
	structures: { [string]: Structures.PlacedStructure },
	plots: { [string]: boolean }
): boolean
	local ground = self:GetGround(plots)

	if not ground or not GridUtil.IsBlockOnGround(ground, cellX, cellZ, footprintX, footprintZ) then
		return false
	end

	for _, placed in structures do
		if Structures.Overlaps(placed, cellX, cellZ, footprintX, footprintZ) then
			return false
		end
	end

	return true
end

-- Puts one placed structure down. The order is load-bearing -- the tag goes last, and handlers read attributes back.
function Base:BuildStructure(uid: string, placed: Structures.PlacedStructure, animate: boolean?): Model?
	local structure = Structures.GetStructureFromId(placed.Type)

	-- A structure whose template was missing is dropped at load, so older data can name one that's gone
	if not structure then
		warn(`[Base] {self._model.Name} was asked to build a {placed.Type}, which isn't a structure`)
		return nil
	end

	local pose = self:GetCellPose(structure, placed.CellX, placed.CellZ, placed.Rotation)

	-- Left in data rather than dropped, so re-laying out a base doesn't destroy anyone's build
	if not pose then
		warn(`[Base] {self._model.Name} can't build {placed.Type}, it has no {Plots.START} {Plots.FLOOR_NAME}`)
		return nil
	end

	local footprintX, footprintZ = Structures.GetFootprint(structure, placed.Rotation)

	local model = structure.Model:Clone()
	model.Name = uid

	-- Made inert, or every structure would carry an invisible wall. Query stays on for the pickup tool's raycast
	local hitbox = model:FindFirstChild(Structures.HITBOX_NAME)
	if hitbox and hitbox:IsA("BasePart") then
		hitbox.CanCollide = false
		hitbox.CanTouch = false
	end

	-- Solid to the owner, passable to customers. Stamped per copy rather than on the replicated template
	CollisionManager:SetModelGroup(model, CollisionManager.STRUCTURE)

	-- Whole or not at all: under default mode a class ends up holding destroyed parts on a still-tagged model
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	model:SetAttribute("SlotCFrame", pose)
	model:SetAttribute(Structures.UID_ATTRIBUTE, uid)
	model:SetAttribute(Structures.OWNER_ATTRIBUTE, self._owner.UserId)

	-- Which model this is, where the tag says only the kind -- the model's own name is the uid
	model:SetAttribute(Structures.TYPE_ATTRIBUTE, placed.Type)

	-- On the model, not data, since data only reaches its owner and the ghost must be right on every client
	model:SetAttribute(Structures.CELL_X_ATTRIBUTE, placed.CellX)
	model:SetAttribute(Structures.CELL_Z_ATTRIBUTE, placed.CellZ)
	model:SetAttribute(Structures.FOOTPRINT_X_ATTRIBUTE, footprintX)
	model:SetAttribute(Structures.FOOTPRINT_Z_ATTRIBUTE, footprintZ)

	-- Drops in at full size where an upgrade rises small, so building and upgrading read differently. A rejoin snaps
	if animate then
		model:PivotTo(pose * CFrame.new(0, Structures.PLACE_DROP_HEIGHT, 0))
		model:SetAttribute("PulseOnSpawn", true)
		model:AddTag("LayoutStand")

		SoundManager:PlaySound("All", PLACE_SOUND, pose)
	else
		model:PivotTo(pose)
	end

	model.Parent = self._structureFolder

	-- The category, not the id, so a second griller can be a config entry and nothing else
	model:AddTag(structure.Category)

	-- Settled once the drop lands -- only the client moved it. Read off the attribute, since a move rewrites it
	if animate then
		task.delay(Structures.PLACE_SETTLE_TIME, function()
			if model.Parent then
				model:PivotTo(model:GetAttribute("SlotCFrame"))
				model:SetAttribute("PulseOnSpawn", nil)
			end
		end)
	end

	self._structures[uid] = model

	return model
end

-- Renders the owner's build, reconciling so placing one thing doesn't restart every other cook animation.
function Base:RenderStructures(structures: { [string]: Structures.PlacedStructure }, animate: boolean?)
	for uid, model in self._structures do
		if not structures[uid] then
			-- Read off the model, the record having gone from data. Same flag, so clearing a base is silent
			if animate then
				SoundManager:PlaySound("All", TAKE_SOUND, model:GetPivot())
			end

			model:Destroy()
			self._structures[uid] = nil
		end
	end

	for uid, placed in structures do
		local model = self._structures[uid]

		if not model then
			self:BuildStructure(uid, placed, animate)
			continue
		end

		local structure = Structures.GetStructureFromId(placed.Type)
		local pose = structure
			and self:GetCellPose(structure, placed.CellX, placed.CellZ, placed.Rotation)

		if not pose then
			continue
		end

		-- SlotCFrame is both where it belongs and the client's spring target, so writing it is what makes a move slide
		if model:GetAttribute("SlotCFrame") ~= pose then
			model:SetAttribute("SlotCFrame", pose)
			model:SetAttribute(Structures.CELL_X_ATTRIBUTE, placed.CellX)
			model:SetAttribute(Structures.CELL_Z_ATTRIBUTE, placed.CellZ)
			model:PivotTo(pose)
		end
	end
end

-- Takes the whole build back down, so the next player through doesn't inherit the last one's.
function Base:ClearStructures()
	for uid, model in self._structures do
		model:Destroy()
		self._structures[uid] = nil
	end
end

-- Claims this base for a player, renders it at their unlocks, plots and build, and spawns them on it.
function Base:AssignOwner(
	player: Player,
	unlocks: { [string]: number },
	plots: { [string]: boolean },
	structures: { [string]: Structures.PlacedStructure }
)
	self._owner = player

	-- Server-side so every visitor sees it, and parented to the board -- display only, with nothing to click
	local stallUI = self._ownerCleaner:Clone(UI.StallUI)
	stallUI.Title.Text = `{player.DisplayName}'s Stall`
	stallUI.Parent = self._stallBoard

	-- An rbxthumb url, so nothing here yields or fails on a web call. BaseIcon is raised per-viewer
	local baseUI = self._ownerCleaner:Clone(UI.BaseUI)
	baseUI.PlayerName.Text = `{player.DisplayName}`
	baseUI.PlayerImg.Image = `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=150&h=150`
	baseUI.BaseIcon.Visible = false
	baseUI.Parent = self._nameplateAttachment

	-- Built before the client gets its id, which it needs to find these. None animate -- that's for what was just done
	self:ApplyUnlocks(unlocks)
	self:ApplyPlots(plots)
	self:RenderStructures(structures)

	-- The client reads this to work out which base in the world is its own.
	player:SetAttribute("BaseId", self._model.Name)

	self._ownerCleaner:Connect(player.CharacterAdded, function(character: Model)
		self._characterCleaner:Clean()
		character:PivotTo(self._spawn.CFrame + Vector3.new(0, SPAWN_HEIGHT_OFFSET, 0))

		-- CharacterAutoLoads is off, so the respawn after a death is ours to drive.
		self._characterCleaner:Connect(character.Humanoid.Died, function()
			task.wait(RESPAWN_DELAY)

			-- The player may have left during the respawn delay.
			if self._owner ~= player then
				return
			end

			self:SpawnOwnerCharacter()
		end)
	end)

	self:SpawnOwnerCharacter()
end

-- Loads the owner's character; the CharacterAdded hook from AssignOwner places it on the spawn.
function Base:SpawnOwnerCharacter()
	self._owner:LoadCharacterAsync()
end

-- Frees the base and stops managing its former owner's character.
function Base:ClearOwner()
	self._owner:SetAttribute("BaseId", nil)

	self._owner = nil
	self._ownerCleaner:Clean()
	self._characterCleaner:Clean()

	-- An empty plot table puts the overgrowth back; structures aren't a level, so they're taken down
	self:ClearStructures()
	self:ApplyUnlocks(BaseUnlocks.NO_UNLOCKS)
	self:ApplyPlots({})
end

-- Returns the player who currently owns this base, if any.
function Base:GetOwner(): Player?
	return self._owner
end

function Base:Destroy()
	self._cleaner:Destroy()
	self = nil
end

return Base
