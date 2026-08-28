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

-- The two halves of moving a structure, under SoundService.Building. Played positionally on the cell
-- the structure lands on or leaves, and heard by everyone -- a base being rearranged is something a
-- visitor standing on it should hear happen where it happens, not flatly in their ear.
local PLACE_SOUND = "Place"
local TAKE_SOUND = "Take"

--[[
    Class for a single base in the world.

    One instance per model under workspace.Base. A base starts unowned; BaseManager assigns a
    player on join and clears them on leave. While owned, the base loads its owner's character
    and places it on Core.PlayerSpawn -- on first spawn and on every respawn after death.

    A base also renders its owner's build: the unlock levels (a Layout group shows one copy of its
    template per level), which plots they've bought (an unbought plot keeps its overgrowth, and wears
    an unlock sign once it's reachable), and the structures they've placed on those plots. That happens
    on the server rather than the client because player data only replicates to the player it belongs
    to -- a visitor's client can't read the owner's Unlocks, Plots or Structures, but it sees the models
    the server moved just fine.

    Structures are the free-form half of that. Rather than a level on a ladder, each one is a model
    the player put on a particular cell of the base (see Config.Structures), so the base is the thing
    that turns those cells back into world poses. One lattice runs across the whole base, measured off
    the starting plot's Floor, and the plots the player owns say which of its cells they may build on
    (see Shared.GridUtil) -- so a plot they haven't bought is ground missing from that set rather than
    a special case anywhere, and a structure may straddle the seam between two they have.
]]

--
local Base = {}
Base.__index = Base

function Base.new(model: Model)
	--
	local cleaner = Trove.new()

	-- Layout templates live here, out of the world: they stay visible in the explorer while testing,
	-- and nothing has to hold a Lua reference to keep them from being collected. Deliberately off the
	-- cleaner -- destroying it would take the templates with it.
	local storage = Instance.new("Folder")
	storage.Name = `BaseStorage_{model.Name}`
	storage.Parent = ServerStorage

	-- Where the owner's placed structures go. Made here rather than authored into the place file, so
	-- adding a base needs nothing done to it. Deliberately off the cleaner for the same reason as the
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
		-- [plotId] = { Model, Sign, Misc, Floor } -- the sign parks in _storage while the plot isn't
		-- buyable and the overgrowth parks there once it's bought, and Floor is the part saying which
		-- cells of the base's grid this plot covers. The starting cell is in here too: it has neither of
		-- the first two and is never bought, but it's ground the player can build on like any other --
		-- and its floor is what the whole grid is measured off (see GetGround).
		_plots = {},
		-- [plotId] = the token belonging to the pull waiting on that plot's burn. A render landing
		-- mid-burn reads it to leave the plot alone, and the pull reads it back to know it's still the
		-- one that should run -- see ApplyPlots.
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

	-- Nobody owns this base yet, and the caches above have to read the place file's authored state
	-- before anything renders on top of it.
	self:ApplyUnlocks(BaseUnlocks.NO_UNLOCKS)
	self:ApplyPlots({})

	return self
end

-- Reads each unlock's authored state off the place file once, before anything renders on top of it.
-- A Layout group pulls its one template out of the world to clone from, and works out where the grid
-- is centred. A Ghost group keeps its model in place and needs nothing cached.
function Base:_cacheUnlocks()
	for _, unlock in BaseUnlocks.Data do
		-- A Stat group has nothing in the world -- no Path to walk and nothing to pull out of it.
		if unlock.LockStyle == "Stat" then
			continue
		end

		local folder = self._model
		for _, segment in unlock.Path do
			folder = folder:FindFirstChild(segment)

			-- The models live in the place file, not this repo, so a path can go stale with nothing
			-- here failing to build. Skip the group rather than throw: BaseManager's OnInit is
			-- pcall'd, and erroring here would leave every base unassigned instead.
			if not folder then
				warn(`[Base] {self._model.Name} has no {table.concat(unlock.Path, ".")}, {unlock.Id} won't render`)
				break
			end
		end

		if not folder then
			continue
		end

		-- Layout: pull the single authored template out of the world to clone from, and record where
		-- its grid is centred and how far apart to space copies.
		if unlock.LockStyle == "Layout" then
			local template = folder:FindFirstChild("1")
			if not template then
				warn(`[Base] {self._model.Name} {unlock.Id} has no "1" template, won't render`)
				continue
			end

			-- Size drives spacing so copies never overlap whatever the model's dimensions are;
			-- Padding is the gap left on top. Columns run along local X, rows along local Z.
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

-- Finds each plot's unlock sign, its overgrowth and its build floor once, before anything renders on
-- top of them. The first two are the pieces the server moves in and out of the world; the floor stays
-- put and is only ever read.
--
-- The starting cell is cached alongside the buyable plots. It's never bought and wears no sign, so
-- most of the plot render skips it -- but it's ground the player owns from the moment they're handed
-- the base, and building doesn't care which of the two a plot is. Its floor matters twice over: it's
-- ground like any other plot's, and it's what the base's whole grid is measured off -- so a base
-- without one can't be built on at all.
function Base:_cachePlots()
	local folder = self._model:FindFirstChild(Plots.FOLDER_NAME)

	-- The models live in the place file, not this repo, so this can go stale with nothing here failing
	-- to build. Warn and carry on rather than throw: BaseManager's OnInit is pcall'd, and erroring
	-- here would leave every base unassigned instead of just plot-less.
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

		-- Both are parked in storage and parented back rather than hidden and restored: it's one move
		-- instead of every client writing every part, and nothing has to remember what the place file
		-- authored -- a folder pulled out of the world comes back off the place file's own values for
		-- whoever is handed this base next.
		--
		-- The starting cell has neither, being owned from the off and never overgrown.
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

		-- The cells of the base's grid this plot covers. Searched rather than indexed, so a floor tucked
		-- inside the plot's own structure still counts. A plot without one is simply not buildable
		-- ground, which is the same warn-and-carry-on as everything else read off the place file here.
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

	-- Said once rather than at every placement and every render: without it there's no grid to measure,
	-- so nothing can go down and nothing already down can be put back.
	if not self:GetPlotFloor(Plots.START) then
		warn(
			`[Base] {self._model.Name} has no {Plots.START} {Plots.FLOOR_NAME}, `
				.. `so its grid can't be measured and nothing can be built on it`
		)
	end
end

-- Renders the base at the given plots: which ones are cleared, and which ones are buyable enough to
-- wear a sign -- the latter being what walks the player outwards from the middle of their base
-- instead of letting them buy a far corner.
--
-- `animate` is for a render that follows a purchase, and it's the only thing separating a plot that
-- was just bought from one this base was handed over already owning -- the two look identical from a
-- client and race freely on join. So a plot cleared under it is burned back on screen before its
-- overgrowth is pulled, and one cleared without it simply never had any.
function Base:ApplyPlots(plots: { [string]: boolean }, animate: boolean?)
	for plotId, plot in self._plots do
		-- The starting cell is cached with the plots so building can find its floor, but there's nothing
		-- to render on it: it's owned from the off, so it never wears a sign and was never overgrown.
		if plotId == Plots.START then
			continue
		end

		local isUnlocked = plots[plotId] == true

		-- Read before the write below overwrites it: where the last render left each plot is all the
		-- history needed to spot the locked -> unlocked edge, so no extra state is kept. Nobody else
		-- reads it -- what a client used to hide off this flag is taken out of the world below instead --
		-- so it's an attribute purely because the plot model is somewhere to keep it that lives exactly
		-- as long as the base does.
		local wasUnlocked = plot.Model:GetAttribute("Unlocked") == true
		plot.Model:SetAttribute("Unlocked", isUnlocked or nil)

		-- Burned back rather than snapped, on the one plot that just changed hands. Everyone nearby
		-- sees it: it's the plot model that goes over, so EffectManager culls by distance from it.
		local burning = animate and isUnlocked and not wasUnlocked
		if burning then
			EffectManager:RunEffect("All", "PlotCleared", { plot.Model })
		end

		-- A bought plot's overgrowth leaves the world outright, so what's standing on cleared ground is
		-- nothing rather than something invisible: no collision to walk into, no parts to raycast, and
		-- nothing to stream back in overgrown. It comes back for the next owner of this base the same
		-- way the sign does.
		--
		-- The one wrinkle is the burn. The trees being tweened are these, and the server can't animate
		-- something it has already taken out of the world -- so the plot that just changed hands keeps
		-- them until the fade everyone is watching has run.
		if plot.Misc then
			if not isUnlocked then
				-- Any pull still waiting on a burn goes with it, so an owner leaving mid-clear can't have
				-- one fire on the plot it has just put back.
				self._clearing[plotId] = nil
				plot.Misc.Parent = plot.Model
			elseif burning then
				-- Held against a token rather than a bare flag, because it answers two questions: whether a
				-- pull is already coming, for the render that lands mid-burn -- buying a second plot
				-- re-applies every one of them -- and whether this is still the pull that should run, for
				-- the pull itself, on a base that may have changed hands by the time it comes round.
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

		-- Exactly the plots that are buyable right now wear a board, so a player is never shown a price
		-- on something they can't reach yet.
		if plot.Sign then
			plot.Sign.Parent = if Plots.IsAvailable(plotId, plots) then plot.Model else self._storage
		end
	end
end

-- Places copy `index` of `count` in the grid: rows fill left to right up to MaxPerRow, each row is
-- centered on its own, and rows grow toward the back (+Z) off the front row. So the front row sits
-- on the template's authored spot and stays put as later rows are added behind it.
function Base:_slotCFrame(layout, index: number, count: number): CFrame
	local cols = layout.Spec.MaxPerRow
	local row = math.floor((index - 1) / cols)
	local inRow = math.min(cols, count - row * cols)
	local col = (index - 1) - row * cols

	local x = (col - (inRow - 1) / 2) * layout.Step.X
	local z = row * layout.Step.Y

	return layout.Center * CFrame.new(x, 0, z)
end

-- Renders the base at the given unlock levels: a Layout group shows `level` copies in a centered grid.
-- `animate` is for a render that follows a purchase -- it's what lets a newly-bought copy rise into
-- place and flash instead of appearing.
function Base:ApplyUnlocks(unlocks: { [string]: number }, animate: boolean?)
	for _, unlock in BaseUnlocks.Data do
		-- An entry added to the config but not to DataSettings' Unlocks template reads back nil.
		-- That's two hand-kept tables in different files, and staying locked beats throwing here
		-- and never spawning the player.
		local level = unlocks[unlock.Id] or 0

		if unlock.LockStyle == "Layout" then
			local layout = self._layouts[unlock.Id]

			-- A group whose template was missing at cache time has no layout. And the Unlocks
			-- listener re-applies the whole table on any change, so this runs for groups that didn't
			-- move -- bail unless the count actually differs, so an unrelated upgrade can't churn the
			-- folder or interrupt an in-progress roll.
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

				-- Streamed whole or not at all, for the same reason a placed structure is (see
				-- BuildStructure): the client builds a class per copy and reads its parts as it does, and
				-- under the default mode the copy's model arrives ahead of them.
				clone.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

				layout.Clones[i] = clone
			end

			-- The server only decides where each copy goes -- via the SlotCFrame attribute -- and the
			-- client's LayoutStand component springs the model there. A fresh copy is dropped below its
			-- slot so the client rises it up; an existing one just gets a new target and slides.
			for i = 1, target do
				local slot = self:_slotCFrame(layout, i, target)
				local clone = layout.Clones[i]

				if not clone.Parent then
					clone:PivotTo(slot * CFrame.new(0, -BaseUnlocks.LAYOUT_RISE, 0))
					clone:ScaleTo(BaseUnlocks.LAYOUT_ENTRANCE_SCALE)
					clone:SetAttribute("SlotCFrame", slot)

					-- The gold flash a bought copy wears as it rises. Left to the client to fire off
					-- this attribute rather than sent through EffectManager: the copy is made and
					-- parented in this same frame, so a remote naming it could beat it to a client.
					-- An attribute replicates with the instance instead.
					if animate then
						clone:SetAttribute("PulseOnSpawn", true)
					end

					clone:AddTag("LayoutStand")
					clone.Parent = layout.Home

					-- Once the rise has had time to land, put the server's own copy on its slot at full
					-- size and drop the flash with it -- the same settle a placed structure gets, and for
					-- the same reason (see BuildStructure). Scale as well as pose here, since a fresh copy
					-- starts undersized as well as sunk.
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

-- The cells of this base the given plots may be built on: one lattice across the whole base, and the
-- floors of the plots they own saying which of it is theirs. Two plots that touch hand off to each
-- other cell for cell, so the seam between them is buildable ground like any other.
--
-- Worked out per call rather than cached off a render, because this is what the authoritative check
-- reads -- a cached one could answer for an unlock state the placement has already moved past, and
-- it's a handful of rectangles either way.
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

-- Where a structure standing on this cell of the base actually sits in the world. Cells are turned
-- back into poses here rather than being stored as one, because a player is handed whichever base
-- happens to be free -- the same cell on another base is the right spot on that base, while a saved
-- pose would rebuild in mid-air.
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

-- Whether a structure of this footprint can stand on this block of cells: every cell of it is on
-- ground the player owns, and nothing they've already built is in the way. This is the authoritative
-- check -- the client runs the same test to colour its ghost, but only this one decides.
--
-- Ownership is the bounds test rather than a check beside it: the ground is built from the plots they
-- own, so a block reaching onto one they haven't bought fails on the cells nothing covers, and a block
-- spanning two they have passes on the cells each of them covers.
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

-- Puts one of the owner's placed structures down. The order here is load-bearing: the tag goes on
-- last, because CollectionService fires its added signal the moment it does and every handler on
-- both sides reads the uid, the owner and the cells straight back off the attributes.
function Base:BuildStructure(uid: string, placed: Structures.PlacedStructure, animate: boolean?): Model?
	local structure = Structures.GetStructureFromId(placed.Type)

	-- A structure whose template was missing is dropped from the config at load, so data written
	-- before that can name one that no longer exists.
	if not structure then
		warn(`[Base] {self._model.Name} was asked to build a {placed.Type}, which isn't a structure`)
		return nil
	end

	local pose = self:GetCellPose(structure, placed.CellX, placed.CellZ, placed.Rotation)

	-- Nowhere to put it: the base has no starting floor to measure its grid off, so there are no cells
	-- to stand on. Left in data rather than dropped, so re-laying out a base doesn't destroy anyone's
	-- build.
	if not pose then
		warn(`[Base] {self._model.Name} can't build {placed.Type}, it has no {Plots.START} {Plots.FLOOR_NAME}`)
		return nil
	end

	local footprintX, footprintZ = Structures.GetFootprint(structure, placed.Rotation)

	local model = structure.Model:Clone()
	model.Name = uid

	-- The box the structure was measured against, made inert as it goes down. It wraps the whole model
	-- (see Structures.HITBOX_NAME) and it's there because this code asked for it rather than because
	-- anyone wanted something in that spot -- so left as the place file has it, every structure a player
	-- builds carries an invisible wall the size of its footprint. Query stays on: being the outline of
	-- the whole thing it's the easiest part of a structure to point at, and the pickup tool aims by
	-- raycast (see BuildController:_getStructureUnderCursor).
	local hitbox = model:FindFirstChild(Structures.HITBOX_NAME)
	if hitbox and hitbox:IsA("BasePart") then
		hitbox.CanCollide = false
		hitbox.CanTouch = false
	end

	-- Solid to the player who built it, passable to the customers walking to their stall -- see
	-- CollisionManager. Stamped per copy rather than on the template, which is a shared config both
	-- realms load and a replicated asset the place file should go on agreeing with.
	CollisionManager:SetModelGroup(model, CollisionManager.STRUCTURE)

	-- Streamed whole or not at all. Every client system that owns a structure builds one class per model
	-- off the tag below and reads the model's parts once as it does -- so under the default mode, where
	-- a model's containers stay put on the client while its parts stream out from under them, those
	-- classes are left holding parts that have been destroyed: the prompts they parented to them are
	-- gone, the model is still tagged so nothing rebuilds them, and the structure is dead for the rest
	-- of the session. Atomic is what makes the tag mean all of it, so the added/removed signals those
	-- classes are already built around fire on each stream cycle and rebuild against a whole model.
	--
	-- Stamped per copy rather than on the template for the same reason as the collision group above.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	model:SetAttribute("SlotCFrame", pose)
	model:SetAttribute(Structures.UID_ATTRIBUTE, uid)
	model:SetAttribute(Structures.OWNER_ATTRIBUTE, self._owner.UserId)

	-- Which griller (or stand) this is, where the tag below only says which kind. For the things that
	-- differ between two models of the same kind rather than between kinds -- the Electric Grill's cook
	-- effect, for one -- since the model's own name is the uid and says nothing about what it is.
	model:SetAttribute(Structures.TYPE_ATTRIBUTE, placed.Type)

	-- The cells it claimed, so a client can tell a free spot from a taken one. On the model rather than
	-- read from data, because data only reaches its owner and the ghost has to be right on every client.
	model:SetAttribute(Structures.CELL_X_ATTRIBUTE, placed.CellX)
	model:SetAttribute(Structures.CELL_Z_ATTRIBUTE, placed.CellZ)
	model:SetAttribute(Structures.FOOTPRINT_X_ATTRIBUTE, footprintX)
	model:SetAttribute(Structures.FOOTPRINT_Z_ATTRIBUTE, footprintZ)

	-- A structure the player just placed drops onto its spot from above and flashes gold. It rides the
	-- same client component as a bought Layout copy, but starts above its slot rather than below it and
	-- at full size rather than small -- so building reads as putting a finished thing down, where buying
	-- an upgrade reads as one growing into place.
	--
	-- One going down on a rejoin snaps instead, so nobody watches their whole base rain in on join --
	-- and, since the sound rides the same flag, nobody hears it rain in either.
	if animate then
		model:PivotTo(pose * CFrame.new(0, Structures.PLACE_DROP_HEIGHT, 0))
		model:SetAttribute("PulseOnSpawn", true)
		model:AddTag("LayoutStand")

		SoundManager:PlaySound("All", PLACE_SOUND, pose)
	else
		model:PivotTo(pose)
	end

	model.Parent = self._structureFolder

	-- The category and not the id: a manager owns a kind of structure rather than one model of it, so
	-- tagging the kind is what lets a second griller be a config entry and nothing else.
	model:AddTag(structure.Category)

	-- Once the drop has had time to land, put the server's own copy where the structure actually is and
	-- drop the flash with it. Only the client ever moved it, so until this runs the server is holding it
	-- PLACE_DROP_HEIGHT in the air -- and every client that arrives late reads that pose rather than the
	-- one it was built on. A move landing inside the window has already written both the attribute and
	-- the pivot, so the pose is read back off the attribute rather than closed over.
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

-- Renders the base at the given structures, which is the whole of the owner's build. Reconciles
-- rather than rebuilds: the Structures listener re-applies the whole table on any change, so leaving
-- a structure that didn't move exactly as it is, is what stops placing one thing from restarting the
-- cook animation on everything else. `animate` is for a render that follows a placement -- it's what
-- lets the structure just put down rise into its spot instead of appearing.
function Base:RenderStructures(structures: { [string]: Structures.PlacedStructure }, animate: boolean?)
	for uid, model in self._structures do
		if not structures[uid] then
			-- Read off the model rather than the record, which has already gone from data by the time this
			-- runs. Same flag as the drop above, so a structure only sounds when it's actually been taken
			-- back up -- clearing a base for the next player through is silent.
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

	-- Names the sell stall after its owner. Put up on the server so every visitor sees whose stall
	-- they're standing in, and parented straight to the board rather than adorned from a client's
	-- ScreenGui -- it's display only, with no buttons to make clickable. Off the owner cleaner, so it
	-- comes back down with the base when they leave.
	local stallUI = self._ownerCleaner:Clone(UI.StallUI)
	stallUI.Title.Text = `{player.DisplayName}'s Stall`
	stallUI.Parent = self._stallBoard

	-- The nameplate over the base itself. The headshot goes through an rbxthumb url rather than
	-- GetUserThumbnailAsync so nothing here yields or has a web call to fail on. BaseIcon is the one
	-- per-viewer piece -- it marks the base as your own -- so it starts down and UpgradeBoardController
	-- raises it on the owner's client alone.
	local baseUI = self._ownerCleaner:Clone(UI.BaseUI)
	baseUI.PlayerName.Text = `{player.DisplayName}`
	baseUI.PlayerImg.Image = `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=150&h=150`
	baseUI.BaseIcon.Visible = false
	baseUI.Parent = self._nameplateAttachment

	-- Build the base out before handing the client its id: the client reads BaseId to go find its
	-- stands and its plot signs, and it can't find one that's still parked in ServerStorage.
	--
	-- None of these animate. A base being handed over renders everything the player already had at
	-- once, and watching a whole build rain in on join is neither a reward nor readable -- the rise and
	-- the gold flash are for the one thing they just did, which is what the refreshes above are for.
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

	-- Drop the base back to locked so the next player through doesn't walk into the last one's build.
	-- An empty plot table puts every plot's overgrowth back, so the base reads as untouched again, and
	-- the structures go with it -- they're the one part of a build that isn't a level to reset to zero,
	-- so they have to be taken down rather than re-rendered away.
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
