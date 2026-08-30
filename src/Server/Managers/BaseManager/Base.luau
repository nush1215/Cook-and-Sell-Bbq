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

-- Under SoundService.Building. Played positionally on the cell and heard by everyone, so a visitor hears
-- a base being rearranged where it happens rather than flatly in their ear.
local PLACE_SOUND = "Place"
local TAKE_SOUND = "Take"

-- Names both the folder authored onto each base and the ReplicatedStorage folder they're parked under.
local TUTORIAL_GUIDES_NAME = "TutorialGuides"

--[[
    One base in the world -- one instance per model under workspace.Base. Unowned until BaseManager
    assigns a player, after which it loads their character onto Core.PlayerSpawn on every spawn.

    It also renders the owner's build: unlock levels, bought plots, and placed structures. On the server
    rather than the client because player data only replicates to its owner, so a visitor's client can't
    read the owner's Unlocks/Plots/Structures but does see the models the server moved.

    One cell lattice runs across the whole base, measured off the starting plot's Floor, with the owned
    plots saying which cells are buildable (see Shared.GridUtil) -- so an unbought plot is simply ground
    missing from that set, and a structure may straddle the seam between two owned ones.
]]

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

	-- Taken out of the world and parked under ReplicatedStorage, keyed by base: they're a cue for one
	-- player mid-onboarding, and left in place every visitor would see ghost buildings on someone's plot.
	-- Parked rather than destroyed because each carries the world pose it was authored at, which the
	-- tutorial client reparents back in locally. Nothing under ReplicatedStorage renders.
	local guides = model:FindFirstChild(TUTORIAL_GUIDES_NAME)
	if guides then
		guides.Name = model.Name
		guides.Parent = getTutorialGuideHolder()
	end

	-- Layout templates, out of the world but still visible in the explorer. Deliberately off the cleaner:
	-- destroying it would take the templates with it.
	local storage = Instance.new("Folder")
	storage.Name = `BaseStorage_{model.Name}`
	storage.Parent = ServerStorage

	-- Made here rather than authored, so adding a base needs nothing done to it. Off the cleaner like the
	-- storage above -- it outlives every owner the base has.
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
		-- [plotId] = { Model, Sign, Misc, Floor }. Sign parks in _storage while unbuyable, Misc parks once
		-- bought, Floor says which grid cells the plot covers. The starting cell is in here with neither
		-- of the first two -- it's never bought, but its floor is what the whole grid is measured off.
		_plots = {},
		-- [plotId] = the token for the pull waiting on that plot's burn, so a render landing mid-burn
		-- leaves it alone and the pull knows it's still the one that should run -- see ApplyPlots.
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

-- Reads each unlock's authored state off the place file once. A Layout group pulls its template out of the
-- world to clone from and records its grid centre; a Ghost group needs nothing cached.
function Base:_cacheUnlocks()
	for _, unlock in BaseUnlocks.Data do
		-- A Stat group has nothing in the world -- no Path to walk and nothing to pull out of it.
		if unlock.LockStyle == "Stat" then
			continue
		end

		local folder = self._model
		for _, segment in unlock.Path do
			folder = folder:FindFirstChild(segment)

			-- The models live in the place file, so a path can go stale with nothing here failing to
			-- build. Skipped rather than thrown: BaseManager's OnInit is pcall'd, and erroring would
			-- leave every base unassigned.
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

			-- Size drives spacing so copies never overlap, with Padding as the gap on top. Columns run
			-- along local X, rows along local Z.
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

-- Finds each plot's unlock sign, overgrowth and build floor once. The first two the server moves in and
-- out of the world; the floor stays put and is only read.
--
-- The starting cell is cached alongside the buyable plots: most of the render skips it, but building
-- doesn't care which kind a plot is, and its floor is what the base's whole grid is measured off.
function Base:_cachePlots()
	local folder = self._model:FindFirstChild(Plots.FOLDER_NAME)

	-- Warn and carry on rather than throw: BaseManager's OnInit is pcall'd, and erroring would leave
	-- every base unassigned rather than just plot-less.
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

		-- Parked and parented back rather than hidden and restored: one move instead of every client
		-- writing every part, and nothing has to remember what the place file authored. The starting cell
		-- has neither, being owned from the off and never overgrown.
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

		-- Searched rather than indexed, so a floor nested inside the plot's own structure still counts.
		-- A plot without one is simply not buildable ground.
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

	-- Said once here rather than at every placement and render. Without it there's no grid to measure.
	if not self:GetPlotFloor(Plots.START) then
		warn(
			`[Base] {self._model.Name} has no {Plots.START} {Plots.FLOOR_NAME}, `
				.. `so its grid can't be measured and nothing can be built on it`
		)
	end
end

-- Renders the base's plots: which are cleared, and which are near enough to wear a buy sign -- the latter
-- walking the player outwards from the middle rather than letting them buy a far corner.
--
-- `animate` marks a render that follows a purchase, and is the only thing separating a plot just bought
-- from one the base was handed over already owning. Under it a cleared plot burns back on screen first.
function Base:ApplyPlots(plots: { [string]: boolean }, animate: boolean?)
	for plotId, plot in self._plots do
		-- Cached with the plots so building can find its floor, but there's nothing to render on it.
		if plotId == Plots.START then
			continue
		end

		local isUnlocked = plots[plotId] == true

		-- Read before the write below: the last render's value is all the history needed to spot the
		-- locked -> unlocked edge. An attribute only because the plot model outlives exactly as long as
		-- the base does; nothing else reads it.
		local wasUnlocked = plot.Model:GetAttribute("Unlocked") == true
		plot.Model:SetAttribute("Unlocked", isUnlocked or nil)

		-- Burned rather than snapped, on the one plot that just changed hands. EffectManager culls by
		-- distance from the plot model, so everyone nearby sees it.
		local burning = animate and isUnlocked and not wasUnlocked
		if burning then
			EffectManager:RunEffect("All", "PlotCleared", { plot.Model })
		end

		-- A bought plot's overgrowth leaves the world outright, so what's standing on cleared ground is
		-- nothing rather than something invisible: no collision to walk into, no parts to raycast, and
		-- nothing to stream back in overgrown. It comes back for the next owner of this base the same
		-- way the sign does.
		--
		-- The burn tweens these trees, and the server can't animate what it has already taken out of the
		-- world -- so a plot that just changed hands keeps them until the fade has run.
		if plot.Misc then
			if not isUnlocked then
				-- Cancels any pending pull, so an owner leaving mid-clear can't have one fire on the plot
				-- it has just put back.
				self._clearing[plotId] = nil
				plot.Misc.Parent = plot.Model
			elseif burning then
				-- A token rather than a flag, so it answers both "is a pull already coming" (for a render
				-- landing mid-burn) and "am I still the pull that should run" (for the pull itself, on a
				-- base that may have changed hands).
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

-- Places copy `index` of `count`: rows fill left to right up to MaxPerRow, each centred on its own, and
-- rows grow toward +Z -- so the front row keeps the template's authored spot as rows are added behind it.
function Base:_slotCFrame(layout, index: number, count: number): CFrame
	local cols = layout.Spec.MaxPerRow
	local row = math.floor((index - 1) / cols)
	local inRow = math.min(cols, count - row * cols)
	local col = (index - 1) - row * cols

	local x = (col - (inRow - 1) / 2) * layout.Step.X
	local z = row * layout.Step.Y

	return layout.Center * CFrame.new(x, 0, z)
end

-- Renders the base at the given unlock levels: a Layout group shows `level` copies in a centred grid.
-- `animate` marks a render following a purchase, letting a newly-bought copy rise and flash.
function Base:ApplyUnlocks(unlocks: { [string]: number }, animate: boolean?)
	for _, unlock in BaseUnlocks.Data do
		-- An entry in the config but not in DataSettings' Unlocks template reads back nil. Two hand-kept
		-- tables in different files, and staying locked beats never spawning the player.
		local level = unlocks[unlock.Id] or 0

		if unlock.LockStyle == "Layout" then
			local layout = self._layouts[unlock.Id]

			-- No layout means its template was missing at cache time. The count check below matters
			-- because the listener re-applies the whole table on any change, so an unrelated upgrade
			-- would otherwise churn the folder and interrupt an in-progress rise.
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

				-- Whole or not at all, as with a placed structure (see BuildStructure): the client builds
				-- a class per copy and reads its parts, which the default mode delivers late.
				clone.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

				layout.Clones[i] = clone
			end

			-- The server only says where each copy goes, via SlotCFrame; the client's LayoutStand springs
			-- it there. A fresh copy starts below its slot so it rises; an existing one just slides.
			for i = 1, target do
				local slot = self:_slotCFrame(layout, i, target)
				local clone = layout.Clones[i]

				if not clone.Parent then
					clone:PivotTo(slot * CFrame.new(0, -BaseUnlocks.LAYOUT_RISE, 0))
					clone:ScaleTo(BaseUnlocks.LAYOUT_ENTRANCE_SCALE)
					clone:SetAttribute("SlotCFrame", slot)

					-- An attribute rather than an EffectManager remote: the copy is made and parented in
					-- this same frame, so a remote naming it could beat the instance to a client.
					if animate then
						clone:SetAttribute("PulseOnSpawn", true)
					end

					clone:AddTag("LayoutStand")
					clone.Parent = layout.Home

					-- Once the rise has landed, settle the server's own copy onto its slot at full size --
					-- the same settle a placed structure gets (see BuildStructure), plus scale, since a
					-- fresh copy starts undersized as well as sunk.
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

-- The cells of this base the given plots may be built on: one lattice across the whole base, with the
-- owned floors saying which of it is theirs -- so the seam between two touching plots is ordinary ground.
--
-- Per call rather than cached off a render, since this is what the authoritative check reads and a cached
-- one could answer for a state the placement has moved past. A handful of rectangles either way.
--
-- @param plots The player's data.Plots
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

-- Where a structure on this cell actually sits in the world. Cells are stored rather than poses because a
-- player is handed whichever base is free: the same cell is right anywhere, a saved pose is not.
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

-- Whether a footprint can stand on this block: every cell on owned ground, nothing already built in the
-- way. Authoritative -- the client runs the same test to colour its ghost, but only this one decides.
--
-- Ownership *is* the bounds test rather than a check beside it: the ground is built from owned plots, so
-- a block reaching onto an unbought one fails on the cells nothing covers.
--
-- @param structures The player's data.Structures, which is the whole of their build
-- @param plots The player's data.Plots
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

-- Puts one of the owner's placed structures down. The order is load-bearing: the tag goes on last,
-- because CollectionService fires the moment it does and every handler reads the attributes back.
function Base:BuildStructure(uid: string, placed: Structures.PlacedStructure, animate: boolean?): Model?
	local structure = Structures.GetStructureFromId(placed.Type)

	-- A structure whose template was missing is dropped from the config at load, so older data can name
	-- one that no longer exists.
	if not structure then
		warn(`[Base] {self._model.Name} was asked to build a {placed.Type}, which isn't a structure`)
		return nil
	end

	local pose = self:GetCellPose(structure, placed.CellX, placed.CellZ, placed.Rotation)

	-- No starting floor means no grid and so no cells. Left in data rather than dropped, so re-laying out
	-- a base doesn't destroy anyone's build.
	if not pose then
		warn(`[Base] {self._model.Name} can't build {placed.Type}, it has no {Plots.START} {Plots.FLOOR_NAME}`)
		return nil
	end

	local footprintX, footprintZ = Structures.GetFootprint(structure, placed.Rotation)

	local model = structure.Model:Clone()
	model.Name = uid

	-- Made inert as it goes down: it wraps the whole model, so left as authored every structure would
	-- carry an invisible wall the size of its footprint. Query stays on -- the pickup tool aims by
	-- raycast and this is the easiest part to point at (BuildController:_getStructureUnderCursor).
	local hitbox = model:FindFirstChild(Structures.HITBOX_NAME)
	if hitbox and hitbox:IsA("BasePart") then
		hitbox.CanCollide = false
		hitbox.CanTouch = false
	end

	-- Solid to the owner, passable to customers walking to their stall -- see CollisionManager. Stamped
	-- per copy rather than on the replicated template.
	CollisionManager:SetModelGroup(model, CollisionManager.STRUCTURE)

	-- Whole or not at all. Client systems build one class per tagged model and read its parts once, so
	-- under the default mode -- containers staying put while parts stream out from under them -- those
	-- classes end up holding destroyed parts on a model that's still tagged, and the structure is dead
	-- for the session. Atomic makes the added/removed signals fire per stream cycle against a whole model.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	model:SetAttribute("SlotCFrame", pose)
	model:SetAttribute(Structures.UID_ATTRIBUTE, uid)
	model:SetAttribute(Structures.OWNER_ATTRIBUTE, self._owner.UserId)

	-- Which model of griller (or stand) this is, where the tag below only says which kind -- for what
	-- differs between two of the same kind, like the Electric Grill's cook effect. The model's own name
	-- is the uid and says nothing about what it is.
	model:SetAttribute(Structures.TYPE_ATTRIBUTE, placed.Type)

	-- On the model rather than read from data, since data only reaches its owner and the ghost has to be
	-- right on every client.
	model:SetAttribute(Structures.CELL_X_ATTRIBUTE, placed.CellX)
	model:SetAttribute(Structures.CELL_Z_ATTRIBUTE, placed.CellZ)
	model:SetAttribute(Structures.FOOTPRINT_X_ATTRIBUTE, footprintX)
	model:SetAttribute(Structures.FOOTPRINT_Z_ATTRIBUTE, footprintZ)

	-- Drops in from above at full size, where a bought Layout copy rises from below and small -- so
	-- building reads as putting a finished thing down and upgrading as one growing into place. A rejoin
	-- snaps instead (sound included), so nobody watches their whole base rain in.
	if animate then
		model:PivotTo(pose * CFrame.new(0, Structures.PLACE_DROP_HEIGHT, 0))
		model:SetAttribute("PulseOnSpawn", true)
		model:AddTag("LayoutStand")

		SoundManager:PlaySound("All", PLACE_SOUND, pose)
	else
		model:PivotTo(pose)
	end

	model.Parent = self._structureFolder

	-- The category, not the id: a manager owns a kind of structure, so tagging the kind is what lets a
	-- second griller be a config entry and nothing else.
	model:AddTag(structure.Category)

	-- Once the drop has landed, settle the server's own copy -- only the client moved it, so until now the
	-- server holds it PLACE_DROP_HEIGHT in the air and a late-arriving client reads that pose. Read back
	-- off the attribute rather than closed over, since a move inside the window has already rewritten it.
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

-- Renders the owner's whole build. Reconciles rather than rebuilds: the Structures listener re-applies the
-- whole table on any change, so leaving untouched structures alone is what stops placing one thing from
-- restarting the cook animation on everything else. `animate` marks a render following a placement.
function Base:RenderStructures(structures: { [string]: Structures.PlacedStructure }, animate: boolean?)
	for uid, model in self._structures do
		if not structures[uid] then
			-- Read off the model: the record has already gone from data. Same flag as the drop above, so
			-- clearing a base for the next player through is silent.
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

		-- Already down, so only a structure that's actually been moved is touched. SlotCFrame is both
		-- where it belongs and the client's spring target, so writing it is what makes a move slide.
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

-- Claims this base for a player, renders it at their unlocks, their plots and their build, and spawns
-- them on it.
function Base:AssignOwner(
	player: Player,
	unlocks: { [string]: number },
	plots: { [string]: boolean },
	structures: { [string]: Structures.PlacedStructure }
)
	self._owner = player

	-- Server-side so every visitor sees whose stall it is, and parented straight to the board rather than
	-- adorned from a ScreenGui -- it's display only, with no buttons to make clickable.
	local stallUI = self._ownerCleaner:Clone(UI.StallUI)
	stallUI.Title.Text = `{player.DisplayName}'s Stall`
	stallUI.Parent = self._stallBoard

	-- The headshot goes through an rbxthumb url rather than GetUserThumbnailAsync, so nothing here yields
	-- or can fail on a web call. BaseIcon is per-viewer -- UpgradeBoardController raises it for the owner.
	local baseUI = self._ownerCleaner:Clone(UI.BaseUI)
	baseUI.PlayerName.Text = `{player.DisplayName}`
	baseUI.PlayerImg.Image = `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=150&h=150`
	baseUI.BaseIcon.Visible = false
	baseUI.Parent = self._nameplateAttachment

	-- Built out before the client is handed its id: it reads BaseId to find its stands and plot signs,
	-- and can't find one still parked in ServerStorage. None of these animate -- the rise and the flash
	-- are for the one thing a player just did, not a whole build raining in on join.
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

	-- Back to locked, so the next player doesn't walk into the last one's build. An empty plot table puts
	-- the overgrowth back; structures aren't a level to reset, so they're taken down rather than re-rendered.
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
