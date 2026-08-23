-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Managers
local EffectManager = require(script.Parent.Parent.EffectManager)

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
    the player put on a particular cell of a particular plot (see Config.Structures), so the base is
    the thing that turns those cells back into world poses -- one grid per plot, off the plot's own
    Floor part, which is what makes a plot they haven't bought unbuildable ground rather than a
    special case anywhere.
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
		-- [plotId] = { Model, Sign, Floor } -- the sign parks in _storage while the plot isn't buyable,
		-- and Floor is the part its build grid is measured off. The starting cell is in here too: it has
		-- no sign and is never bought, but it's ground the player can build on like any other.
		_plots = {},

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

-- Finds each plot's unlock sign and its build floor once, before anything renders on top of them. The
-- sign is the only piece of a plot the server moves; the overgrowth is the client's, for the reason
-- below.
--
-- The starting cell is cached alongside the buyable plots. It's never bought and wears no sign, so
-- most of the plot render skips it -- but it's ground the player owns from the moment they're handed
-- the base, and building doesn't care which of the two a plot is.
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

		-- The sign is parked in storage and parented back rather than hidden and restored: it's one move
		-- instead of writing every part, and nothing has to remember what the place file authored.
		--
		-- The overgrowth is deliberately NOT handled here. Clearing a plot burns its trees back on
		-- screen, and the server can't animate something it has already taken out of the world -- so it
		-- stays put and every client dissolves and hides it off the Unlocked attribute instead. That's
		-- the same split the grillers and stands use: the server owns the state, the client owns how it
		-- looks getting there.
		--
		-- The starting cell has neither, being owned from the off and never overgrown.
		local sign = if isStart then nil else plotModel:FindFirstChild(Plots.SIGN_NAME)

		if not isStart and not sign then
			warn(`[Base] {self._model.Name} plot {plotModel.Name} has no {Plots.SIGN_NAME}, it can't be bought`)
		end

		-- Where the plot's build grid is measured from. Searched rather than indexed, so a floor tucked
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
			Floor = floor,
		}
	end
end

-- Renders the base at the given plots: which ones are cleared, and which ones are buyable enough to
-- wear a sign -- the latter being what walks the player outwards from the middle of their base
-- instead of letting them buy a far corner.
--
-- `animate` is for a render that follows a purchase. The client can't work that out for itself: a
-- plot flipping to cleared looks the same whether it was just bought or whether this base was only
-- assigned a moment ago, and the two races freely on join. So the flag below says *what* is cleared
-- and this says *that one just changed hands*, which is what gets burned rather than snapped.
function Base:ApplyPlots(plots: { [string]: boolean }, animate: boolean?)
	for plotId, plot in self._plots do
		-- The starting cell is cached with the plots so building can find its floor, but there's nothing
		-- to render on it: it's owned from the off, so it never wears a sign and was never overgrown.
		if plotId == Plots.START then
			continue
		end

		local isUnlocked = plots[plotId] == true

		-- Read before the write below overwrites it: the attribute the last render left is all the
		-- history needed to spot the locked -> unlocked edge, so no extra state is kept.
		local wasUnlocked = plot.Model:GetAttribute("Unlocked") == true

		-- The one thing this render says about a plot, and it says it to everyone: the owner's Plots
		-- table doesn't replicate to visitors, but this does, so every client can keep the overgrowth
		-- hidden off the same flag.
		plot.Model:SetAttribute("Unlocked", isUnlocked or nil)

		-- Burned back rather than snapped, on the one plot that just changed hands. Everyone nearby
		-- sees it: it's the plot model that goes over, so EffectManager culls by distance from it.
		if animate and isUnlocked and not wasUnlocked then
			EffectManager:RunEffect("All", "PlotCleared", { plot.Model })
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

-- Where a structure standing on this cell of this plot actually sits in the world. Cells are turned
-- back into poses here rather than being stored as one, because a player is handed whichever base
-- happens to be free -- the same cell on another base is the right spot on that base, while a saved
-- pose would rebuild in mid-air.
function Base:GetCellPose(
	structure: Structures.Structure,
	plotId: string,
	cellX: number,
	cellZ: number,
	rotation: number
): CFrame?
	local floor = self:GetPlotFloor(plotId)
	if not floor then
		return nil
	end

	local footprintX, footprintZ = Structures.GetFootprint(structure, rotation)
	local surface = GridUtil.CellToSurfaceCFrame(floor, cellX, cellZ, footprintX, footprintZ, Structures.CELL_SIZE)

	return Structures.GetPlacementPivot(structure.Model, surface, rotation)
end

-- Whether a structure of this footprint can stand on this block of cells: the plot is ground the
-- player owns, the whole block is on that plot's floor, and nothing they've already built is in the
-- way. This is the authoritative check -- the client runs the same test to colour its ghost, but only
-- this one decides.
--
-- @param structures The player's data.Structures, which is the whole of their build
-- @param plots The player's data.Plots
function Base:IsBlockFree(
	plotId: string,
	cellX: number,
	cellZ: number,
	footprintX: number,
	footprintZ: number,
	structures: { [string]: Structures.PlacedStructure },
	plots: { [string]: boolean }
): boolean
	if not Plots.IsOwned(plotId, plots) then
		return false
	end

	local floor = self:GetPlotFloor(plotId)
	if not floor then
		return false
	end

	if not GridUtil.IsBlockInBounds(floor, cellX, cellZ, footprintX, footprintZ, Structures.CELL_SIZE) then
		return false
	end

	for _, placed in structures do
		if Structures.Overlaps(placed, plotId, cellX, cellZ, footprintX, footprintZ) then
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

	local pose = self:GetCellPose(structure, placed.PlotId, placed.CellX, placed.CellZ, placed.Rotation)

	-- Nowhere to put it: the plot it was built on has no floor any more, or isn't in the place file at
	-- all. Left in data rather than dropped, so re-laying out a base doesn't destroy anyone's build.
	if not pose then
		warn(`[Base] {self._model.Name} can't build {placed.Type} on plot {placed.PlotId}, which has no floor`)
		return nil
	end

	local footprintX, footprintZ = Structures.GetFootprint(structure, placed.Rotation)

	local model = structure.Model:Clone()
	model.Name = uid
	model:SetAttribute("SlotCFrame", pose)
	model:SetAttribute(Structures.UID_ATTRIBUTE, uid)
	model:SetAttribute(Structures.OWNER_ATTRIBUTE, self._owner.UserId)

	-- The cells it claimed, so a client can tell a free spot from a taken one. On the model rather than
	-- read from data, because data only reaches its owner and the ghost has to be right on every client.
	model:SetAttribute(Structures.PLOT_ATTRIBUTE, placed.PlotId)
	model:SetAttribute(Structures.CELL_X_ATTRIBUTE, placed.CellX)
	model:SetAttribute(Structures.CELL_Z_ATTRIBUTE, placed.CellZ)
	model:SetAttribute(Structures.FOOTPRINT_X_ATTRIBUTE, footprintX)
	model:SetAttribute(Structures.FOOTPRINT_Z_ATTRIBUTE, footprintZ)

	-- A structure the player just placed drops onto its spot from above and flashes gold. It rides the
	-- same client component as a bought Layout copy, but starts above its slot rather than below it and
	-- at full size rather than small -- so building reads as putting a finished thing down, where buying
	-- an upgrade reads as one growing into place.
	--
	-- One going down on a rejoin snaps instead, so nobody watches their whole base rain in on join.
	if animate then
		model:PivotTo(pose * CFrame.new(0, Structures.PLACE_DROP_HEIGHT, 0))
		model:SetAttribute("PulseOnSpawn", true)
		model:AddTag("LayoutStand")
	else
		model:PivotTo(pose)
	end

	model.Parent = self._structureFolder

	-- The category and not the id: a manager owns a kind of structure rather than one model of it, so
	-- tagging the kind is what lets a second griller be a config entry and nothing else.
	model:AddTag(structure.Category)

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
			and self:GetCellPose(structure, placed.PlotId, placed.CellX, placed.CellZ, placed.Rotation)

		if not pose then
			continue
		end

		-- Already down, so only a structure that's actually been moved is touched. SlotCFrame is both
		-- where it belongs and the client's spring target, so writing it is what makes a move slide.
		if model:GetAttribute("SlotCFrame") ~= pose then
			model:SetAttribute("SlotCFrame", pose)
			model:SetAttribute(Structures.PLOT_ATTRIBUTE, placed.PlotId)
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
