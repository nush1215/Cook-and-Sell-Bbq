-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local BaseUnlocks = require(Shared.Config.BaseUnlocks)

-- Managers
local EffectManager = require(script.Parent.Parent.EffectManager)

-- Assets
local UI = ReplicatedStorage.Assets.UI

--
local SPAWN_HEIGHT_OFFSET = 5
local RESPAWN_DELAY = 5

-- The sign a Ghost slot wears while it's the next one up for purchase. Every other sign in the slot's
-- signs folder is an owned-slot sign instead, up only once the slot's unlocked.
local UNLOCK_SIGN_NAME = "UnlockSign"

--[[
    Class for a single base in the world.

    One instance per model under workspace.Base. A base starts unowned; BaseManager assigns a
    player on join and clears them on leave. While owned, the base loads its owner's character
    and places it on Core.PlayerSpawn -- on first spawn and on every respawn after death.

    A base also renders its owner's unlock levels: locked slots are either parented out of the
    world or faded, depending on the group. That happens on the server rather than the client
    because player data only replicates to the player it belongs to -- a visitor's client can't
    read the owner's Unlocks, but it sees the models the server moved just fine.
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
		_slots = {}, -- [unlockId] = { [slotNumber] = { Parts, Hidden, Signs, SignHome } }  (Ghost)
		_layouts = {}, -- [unlockId] = { Template, Home, Center, Step: Vector2, Spec, Count, Clones }  (Layout)

		--
		_cleaner = cleaner,
		_ownerCleaner = cleaner:Construct(Trove),
		_characterCleaner = cleaner:Construct(Trove),
	}, Base)

	self:_cacheUnlocks()

	-- Nobody owns this base yet, and the cache above has to read the place file's authored state
	-- before anything renders on top of it.
	self:ApplyUnlocks(BaseUnlocks.NO_UNLOCKS)

	return self
end

-- Reads each unlock's authored state off the place file once, before anything renders on top of it.
-- A Ghost group keeps its model in place and remembers how to restore it; a Layout group pulls its
-- one template out of the world to clone from, and works out where the grid is centred.
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

		-- Ghost: remember each part's authored transparency and collision so locking can fade it and
		-- unlocking can put it back exactly.
		local slots = {}
		self._slots[unlock.Id] = slots

		-- [signName] = { Sign, Offset }, the first authored copy of each sign and where it sits
		-- relative to its slot's anchor. Slots the place file didn't author signs on borrow from these.
		local signTemplates = {}

		for _, slotModel in folder:GetChildren() do
			-- Anything in the folder that isn't a numbered slot isn't ours to drive.
			local slotNumber = tonumber(slotModel.Name)
			if not slotNumber then
				continue
			end

			local signHome = unlock.SignsFolder and slotModel:FindFirstChild(unlock.SignsFolder)
			local anchor = unlock.SignAnchor and slotModel:FindFirstChild(unlock.SignAnchor)

			-- Children that go fully invisible while locked rather than being ghosted with the rest.
			local hiddenRoots = {}
			for _, name in unlock.HiddenWhileLocked or {} do
				local child = slotModel:FindFirstChild(name)
				if child then
					table.insert(hiddenRoots, child)
				end
			end

			local parts = {}
			local hidden = {}
			for _, descendant in slotModel:GetDescendants() do
				if not descendant:IsA("BasePart") then
					continue
				end

				-- Signs carry the lock state rather than wearing it, so they're never faded -- the
				-- render below parents them in and out instead.
				if signHome and descendant:IsDescendantOf(signHome) then
					continue
				end

				local authored = { Transparency = descendant.Transparency, CanCollide = descendant.CanCollide }

				local isHidden = false
				for _, root in hiddenRoots do
					if descendant:IsDescendantOf(root) then
						isHidden = true
						break
					end
				end

				if isHidden then
					hidden[descendant] = authored
				else
					parts[descendant] = authored
				end
			end

			-- Pull the slot's signs out of the world and remember where they were authored, so the
			-- render can put exactly the right one back on its spot. The first copy of each sign also
			-- becomes the template every other slot borrows from, measured off the slot's anchor.
			local signs = {}
			if signHome then
				for _, sign in signHome:GetChildren() do
					local pivot = sign:GetPivot()
					signs[sign] = pivot

					if anchor and not signTemplates[sign.Name] then
						signTemplates[sign.Name] = { Sign = sign, Offset = anchor:GetPivot():ToObjectSpace(pivot) }
					end

					sign.Parent = self._storage
				end
			end

			slots[slotNumber] = {
				Model = slotModel,
				Anchor = anchor,
				Parts = parts,
				Hidden = hidden,
				Signs = signs,
				SignHome = signHome,
			}
		end

		self:_fillInMissingSigns(unlock, slots, signTemplates)
	end
end

-- Gives every slot the full set of signs, cloning them onto any the place file didn't author -- the
-- grill that shipped before the signs existed, and every grill added to the place file after. A
-- borrowed sign is placed the same way relative to its slot's anchor as the one it came from, so slots
-- that are copies of each other line up; a slot that authors its own sign keeps it untouched.
function Base:_fillInMissingSigns(unlock: BaseUnlocks.Unlock, slots, signTemplates)
	if not unlock.SignsFolder then
		return
	end

	-- Nothing to copy from: no slot in this base authored a sign (or none of them had an anchor).
	if not next(signTemplates) then
		warn(`[Base] {self._model.Name} {unlock.Id} has no authored {unlock.SignsFolder}, its signs won't render`)
		return
	end

	for slotNumber, slot in slots do
		-- Without an anchor there's nothing to measure the placement off, so a borrowed sign would
		-- land somewhere arbitrary -- better to go without than to drop a board in mid-air.
		if not slot.Anchor then
			warn(
				`[Base] {self._model.Name} {unlock.Id} slot {slotNumber} has no {unlock.SignAnchor}, its signs won't render`
			)
			continue
		end

		local present = {}
		for sign in slot.Signs do
			present[sign.Name] = true
		end

		for name, template in signTemplates do
			if present[name] then
				continue
			end

			-- The folder is the render's handle on where signs go up, so a slot missing that gets one.
			if not slot.SignHome then
				local signHome = Instance.new("Folder")
				signHome.Name = unlock.SignsFolder
				signHome.Parent = slot.Model
				slot.SignHome = signHome
			end

			local sign = template.Sign:Clone()
			sign.Parent = self._storage
			slot.Signs[sign] = slot.Anchor:GetPivot() * template.Offset
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

-- Puts one of a slot's signs up on its authored spot, or takes it back out of the world. A sign going
-- up on a slot that was just bought is dropped in above its spot and tagged, so the client's
-- LayoutStand component springs it down and it reads as a sign being planted; every other placement
-- (a rejoin, a base being handed out) snaps, so nobody watches signs rain in on join.
function Base:_placeSign(sign: Model, pivot: CFrame, home: Instance, placed: boolean, animate: boolean?)
	if not placed then
		if sign.Parent == home then
			-- Dropped so the next placement animates from scratch rather than starting mid-spring.
			sign:RemoveTag("LayoutStand")
			sign.Parent = self._storage
		end

		return
	end

	-- Already up: leave it be, or an unrelated upgrade would replay its drop.
	if sign.Parent == home then
		return
	end

	if animate then
		sign:PivotTo(pivot * CFrame.new(0, BaseUnlocks.SIGN_DROP_HEIGHT, 0))
		sign:SetAttribute("SlotCFrame", pivot)
		sign:AddTag("LayoutStand")
	else
		sign:PivotTo(pivot)
	end

	sign.Parent = home
end

-- Renders the base at the given unlock levels. Layout groups show `level` copies in a centered grid;
-- Ghost groups fade every slot past `level`. `animate` is for a render that follows a purchase -- it's
-- what lets a newly-bought slot's sign drop into place instead of appearing.
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
					-- this attribute rather than sent through EffectManager like the Ghost slots
					-- below: the copy is made and parented in this same frame, so a remote naming it
					-- could beat it to a client. An attribute replicates with the instance instead.
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

		-- Ghost: locked, a slot can't be walked into -- fade it and turn its collision off. Unlocked,
		-- both go back to whatever the place file authored.
		for slotNumber, slot in self._slots[unlock.Id] do
			-- A gamepass slot sits past the group's Limit, so its level can never come round: what owns
			-- it is the pass's tag on this base's owner. An unowned base has nobody to hold one, so every
			-- gamepass slot on it renders locked -- the same as every other slot at level 0.
			local gamepassSlot = unlock.GamepassSlots and unlock.GamepassSlots[slotNumber]
			local isUnlocked = if gamepassSlot
				then self._owner ~= nil and self._owner:HasTag(gamepassSlot.Gamepass)
				else slotNumber <= level

			-- Read before the write below overwrites it: the attribute the last render left is all
			-- the history needed to spot the locked -> unlocked edge, so no extra state is kept.
			local wasUnlocked = slot.Model:GetAttribute("Unlocked") == true

			-- The client reads this to know whether the slot is interactable, and it replicates to
			-- visitors too (unlike the owner's Unlocks).
			slot.Model:SetAttribute("Unlocked", isUnlocked or nil)

			-- Flash the slot gold on the render that follows its purchase, so the grill you just
			-- paid for is the one that catches the eye. The slot's been in the world since the place
			-- loaded, so unlike a Layout copy it's safe to name over a remote right away.
			if animate and isUnlocked and not wasUnlocked then
				EffectManager:RunEffect("All", "HighlightPulse", {
					slot.Model,
					BaseUnlocks.UNLOCK_PULSE_COLOR,
					BaseUnlocks.UNLOCK_PULSE_DURATION,
					BaseUnlocks.UNLOCK_PULSE_START_TRANSPARENCY,
				})
			end

			for part, authored in slot.Parts do
				part.Transparency = if isUnlocked
					then authored.Transparency
					else math.max(authored.Transparency, BaseUnlocks.GHOST_TRANSPARENCY)
				part.CanCollide = if isUnlocked then authored.CanCollide else false
			end

			-- Parts a half-fade would only make look broken go entirely while the slot's locked.
			for part, authored in slot.Hidden do
				part.Transparency = if isUnlocked then authored.Transparency else 1
				part.CanCollide = if isUnlocked then authored.CanCollide else false
			end

			-- Exactly one sign at a time: the unlock sign only on the next slot up for purchase (so a
			-- player is never shown two prices at once), the owned-slot signs once it's bought.
			--
			-- A gamepass slot is off the ladder, so it isn't in that queue at all: its sign is simply up
			-- for as long as the pass isn't held. That's what puts it in front of a player from the
			-- moment they take a base, whatever level the rest of the group is at.
			for sign, pivot in slot.Signs do
				local placed = if sign.Name ~= UNLOCK_SIGN_NAME
					then isUnlocked
					elseif gamepassSlot then not isUnlocked
					else slotNumber == level + 1 and slotNumber <= unlock.Limit

				self:_placeSign(sign, pivot, slot.SignHome, placed, animate)
			end
		end
	end
end

-- Claims this base for a player, renders it at their unlocks and spawns them on it.
function Base:AssignOwner(player: Player, unlocks: { [string]: number })
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
	-- stands, and it can't find one that's still parked in ServerStorage.
	self:ApplyUnlocks(unlocks)

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
	self:ApplyUnlocks(BaseUnlocks.NO_UNLOCKS)
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
