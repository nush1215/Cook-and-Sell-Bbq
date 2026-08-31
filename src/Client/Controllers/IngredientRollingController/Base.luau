-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spring = require(Packages.Spring)

-- Shared
local Shared = ReplicatedStorage.Shared
local RandomUtil = require(Shared.RandomUtil)
local Highlights = require(Shared.Config.Highlights)
local RollingConfig = require(Shared.Config.Rolling)

-- Controllers
local Controllers = script.Parent.Parent
local SoundController = require(Controllers.SoundController)
local CameraController = require(Controllers.CameraController)

-- Modules
local Stand = require(script.Parent.Stand)
local EquippedItem = require(Controllers.Parent.Modules.EquippedItem)

-- Required lazily to break the cycle: IngredientRollingController requires this class.
local IngredientRollingController

--
local LocalPlayer = Players.LocalPlayer

-- Flip to Vector3.xAxis / Vector3.zAxis if the handle swings around the wrong axis in game.
local LEVER_ROTATION_AXIS = Vector3.zAxis

local PROMPT_HOLD = 0.25

-- How close the local player is to this base, as a band rather than a distance: ordered so the checks
-- below can ask whether it's at least rendering. See the distances in the Rolling config for what each
-- one costs.
local BAND_NONE = 0
local BAND_RENDER = 1
local BAND_ANIMATE = 2

--[[
    Class for one base's rolling setup -- its lever and the stands in front of it -- on every client,
    so a pull is something visitors can watch rather than something only the puller sees.

    The server mirrors each pull onto the stand models' attributes (RolledIngredient / RolledAt) and
    the stands render themselves off those, which is what gets the roll to everyone: player data only
    replicates to its owner, so it's the one channel a visitor's client can read. It also means a
    stand doesn't care whether the roll it's picking up happened a moment ago or in a session that's
    over -- a stamp inside the roll duration is still cycling, an older one already landed.

    Only the owner gets the lever's prompt and its cue, and only their stands carry a buy prompt;
    everyone else just watches. Their lever swings the instant they hit the prompt rather than waiting
    on the server, so the pull reads as immediate -- a visitor's swings when the stands pick the roll
    up, which is as soon as they could know about it anyway.

    Rolling is by far the most expensive thing on the base -- a stand clones a model per cycle step --
    so what this draws is banded on how near the local player is: the full roll up close, results
    dropped straight onto the stands further out, and nothing at all past that.
]]

--
local Base = {}
Base.__index = Base

function Base.new(model: Model)
	--
	local cleaner = Trove.new()

	local rollingFolder = model.Rolling
	local lever = rollingFolder.Lever
	local leverHandle = lever.Handle

	-- Swings hard on the pull and settles back, underdamped so it rocks rather than easing home.
	local leverSpring = Spring.new(0)
	leverSpring.Damper = 0.3
	leverSpring.Speed = 15

	local leverRestCFrame = leverHandle:GetPivot()

	-- Every sound a roll makes comes off this one part rather than off the stands, so a pull reads as one
	-- machine in one place. The stands slide as the grid reflows and whichever one reaches a step first is
	-- the one that plays that step's tick, so emitting from them panned the roll somewhere new every pull
	-- -- and the sting, which follows the rarest landing, jumped again on the reveal. The lever's rest
	-- pose is the one point on the setup that doesn't move.
	local soundEmitter = Instance.new("Part")
	soundEmitter.Name = "RollSoundEmitter"
	soundEmitter.Anchored = true
	soundEmitter.CanCollide = false
	soundEmitter.CanQuery = false
	soundEmitter.CanTouch = false
	soundEmitter.Transparency = 1
	soundEmitter.Size = Vector3.one
	soundEmitter.CFrame = leverRestCFrame
	soundEmitter.Parent = rollingFolder

	--
	local self = setmetatable({
		--
		_model = model,
		_id = model.Name,

		--
		_lever = lever,
		_leverHandle = leverHandle,
		_leverSpring = leverSpring,
		_leverRestCFrame = leverRestCFrame,
		_soundEmitter = soundEmitter,

		-- The pull the lever last swung for, so a bank of stands all picking up the same roll swings it
		-- once between them rather than once each.
		_leverPulledAt = nil,

		--
		_standsFolder = rollingFolder.Stands,
		_stands = {}, -- [standId] = Stand

		--
		_band = BAND_NONE,
		_prompt = nil,
		_rolling = false,

		--
		_cleaner = cleaner,
		_standCleaner = cleaner:Construct(Trove),
		_promptCleaner = cleaner:Construct(Trove),
	}, Base)

	cleaner:Add(soundEmitter)

	-- The lever breathes instead of carrying PromptSubjectHighlight: both would put a Highlight on the
	-- same adornee, which renders one of them at random. The breathe covers what that tag did and reads
	-- from further off, and the custom prompt UI still shows you're in range.
	lever:SetAttribute("HighlightColor", Highlights.OPERATE)
	cleaner:Add(function()
		lever:RemoveTag(Highlights.TAG)
	end)

	-- The server parks a stand out of the world while it's locked and parents it back in when it's
	-- bought, so the folder is what says which stands this base has -- not player data, which only ever
	-- reaches one client and replicates on a different channel to the reparent anyway.
	--
	-- Filtered on the name being a number, because the stands aren't the only thing in here: a roll
	-- lands its result alongside them rather than under one (see PlayRoll), named for the ingredient it
	-- is. Without the filter that would be taken for a new stand and re-run the reconcile. Only the
	-- landing arrives here -- the models the cycle spawns and drops on its way there go in the
	-- silhouette container instead, so they never touch this folder.
	self:_reconcileStands()
	cleaner:Connect(self._standsFolder.ChildAdded, function(child)
		if tonumber(child.Name) then
			self:_reconcileStands()
		end
	end)
	cleaner:Connect(self._standsFolder.ChildRemoved, function(child)
		if tonumber(child.Name) then
			self:_reconcileStands()
		end
	end)

	self:RefreshInteraction()

	return self
end

-- This base's id, which is the name of its model in workspace.Base.
function Base:GetId(): string
	return self._id
end

-- The fixed point this base's rolling sounds play from. See the emitter in Base.new for why they don't
-- come off the stands themselves.
function Base:GetSoundEmitter(): BasePart
	return self._soundEmitter
end

-- Whether the local player is the one who owns this base, and so the one who gets its prompts.
function Base:IsOwned(): boolean
	return LocalPlayer:GetAttribute("BaseId") == self._id
end

-- The player who owns this base, if anyone does. The server writes BaseId onto the player, so unlike
-- their data it's readable from any client -- which is what lets a visitor's purchase fly-in know who
-- to fly to.
function Base:GetOwner(): Player?
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("BaseId") == self._id then
			return player
		end
	end

	return nil
end

-- Whether this base is near enough to be drawing anything at all.
function Base:IsRendered(): boolean
	return self._band >= BAND_RENDER
end

-- Whether this base is near enough for a roll to be worth cycling rather than just landing.
function Base:IsAnimating(): boolean
	return self._band >= BAND_ANIMATE
end

-- Whether any of this base's stands is still cycling towards its result.
function Base:AnyStandRolling(): boolean
	for _, stand in self._stands do
		if stand:IsRolling() then
			return true
		end
	end

	return false
end

-- Adds/removes Stand instances so they match the stands the server currently has in the folder,
-- leaving the stands that didn't change -- and their in-progress rolls -- untouched. The server only
-- ever adds one stand on an upgrade and never reparents the others, so a full rebuild here would
-- needlessly destroy a stand mid-roll and orphan whatever it had spawned.
function Base:_reconcileStands()
	-- Drop stands whose model the server took away (a downgrade, or the base being cleared).
	for id, stand in self._stands do
		if not self._standsFolder:FindFirstChild(id) then
			self._standCleaner:Remove(stand)
			self._stands[id] = nil
		end
	end

	-- Build a Stand for any model that doesn't have one yet. It reads its own attributes as it's
	-- constructed, so one arriving with a roll already stamped on it puts that roll straight up. The
	-- numbered children are the stands; the rest are ingredients a roll in progress has spawned beside
	-- them.
	for _, standModel in self._standsFolder:GetChildren() do
		if not tonumber(standModel.Name) or self._stands[standModel.Name] then
			continue
		end

		local stand = Stand.new(standModel, self)
		self._stands[standModel.Name] = stand
		self._standCleaner:Add(stand)
	end
end

-- Re-picks which band this base is in from the local player's position, widening whichever band it's
-- already in by DISTANCE_HYSTERESIS so a player stood on a boundary doesn't spawn and destroy the same
-- models on every sweep. Coming into range puts back whatever is sitting on the stands; dropping out
-- of it wipes them and parks the lever, so a base nobody is near costs nothing to keep around.
function Base:RefreshProximity(position: Vector3?)
	local band = BAND_NONE

	-- No character is no viewpoint, so nothing is near anything.
	if position then
		local margin = RollingConfig.DISTANCE_HYSTERESIS
		local animateDistance = RollingConfig.ANIMATE_DISTANCE + (if self:IsAnimating() then margin else 0)
		local renderDistance = RollingConfig.RENDER_DISTANCE + (if self:IsRendered() then margin else 0)

		-- Measured to the lever's rest pose rather than its live pivot: it's the fixed point on the
		-- setup, and the stands slide around it as the grid reflows.
		local distance = (position - self._leverRestCFrame.Position).Magnitude

		if distance <= animateDistance then
			band = BAND_ANIMATE
		elseif distance <= renderDistance then
			band = BAND_RENDER
		end
	end

	if band == self._band then
		return
	end

	local wasRendered = self:IsRendered()
	self._band = band

	if self:IsRendered() == wasRendered then
		return
	end

	if wasRendered then
		for _, stand in self._stands do
			stand:Clear()
		end

		-- Park the lever rather than leaving it wherever its swing had got to, since Update stops
		-- driving it from here -- otherwise it would still be halfway down when someone walks back.
		self._leverSpring.Position = 0
		self._leverSpring.Velocity = 0
		self._leverHandle:PivotTo(self._leverRestCFrame)

		return
	end

	for _, stand in self._stands do
		stand:Sync()
	end
end

-- Per-frame driver for the lever's spring and every stand's animation, skipped outright on a base too
-- far away to be drawing anything -- so the cost of this scales with the bases near the player rather
-- than the number in the place.
function Base:Update(deltaTime: number)
	if not self:IsRendered() then
		return
	end

	self._leverHandle:PivotTo(
		self._leverRestCFrame * CFrame.fromAxisAngle(LEVER_ROTATION_AXIS, self._leverSpring.Position)
	)

	for _, stand in self._stands do
		stand:Update(deltaTime)
	end
end

-- Swings the lever handle and rings the pull.
function Base:SwingLever()
	self._leverSpring:Impulse(-RandomUtil.GetRandomFromMinMax(20, 27))
	SoundController:PlaySound("LeverPull", self._leverHandle)
end

-- Swings the lever for a pull the stands have just been handed, once however many of them report it.
-- The owner's own lever already swung as they hit the prompt -- before the server had even answered,
-- which is what makes it feel instant -- so theirs is left alone here.
function Base:SwingLeverForPull(rolledAt: number)
	if self:IsOwned() or self._leverPulledAt == rolledAt then
		return
	end

	self._leverPulledAt = rolledAt
	self:SwingLever()
end

-- Pulls the lever: swings it, asks the server for a roll, and holds the prompt down until the roll it
-- stamped has played out. Owner-only, since only their base carries the prompt this hangs off.
function Base:RollIngredients()
	IngredientRollingController = IngredientRollingController or require(script.Parent)

	-- The lock is checked here as well as on the prompt: the prompt goes down a frame after it's taken,
	-- and a trigger already on its way in would otherwise still land a pull.
	if self._rolling or IngredientRollingController:IsRollLocked() then
		return
	end

	self._rolling = true
	self:RefreshInteraction()

	-- Swing up front so the pull reads as instant, then wait on the server. Nothing is cycled until the
	-- stands are told what they landed on, so a rejected roll never animates.
	self:SwingLever()
	CameraController:ShakeCustom(1, 5, 0.15, 0.3)

	local rolledAt, duration = IngredientRollingController:RequestRoll()

	if rolledAt then
		-- Wait the roll out on the server's own clock before looking at the stands: what they landed on
		-- arrives on their attributes, which can still be in flight here, and a stand that hasn't been
		-- told yet reads as not rolling -- which would re-arm the lever a whole roll early. Past that,
		-- wait on the stands themselves, since PlayRoll can take the roll duration *plus* its own
		-- cloning overhead and a stand that's still cycling silently ignores the next roll.
		--
		-- The length is the server's own, sent back with the pull: how fast a roll runs is a level now,
		-- and this has to be the window the claim is gated on rather than one worked out here.
		local finishesAt = rolledAt + duration

		repeat
			task.wait()
		until workspace:GetServerTimeNow() >= finishesAt

		repeat
			task.wait()
		until not self:AnyStandRolling()
	end

	self._rolling = false
	self:RefreshInteraction()
end

-- Breathes the lever only with empty hands, and never mid-roll. Rolling is free, so the lever is
-- almost always pullable and lighting it on that alone would leave it glowing permanently -- holding
-- something means the player's partway through the loop and has somewhere better to be, so the cue
-- waits until they're back to needing an ingredient.
function Base:_refreshLeverHighlight()
	IngredientRollingController = IngredientRollingController or require(script.Parent)

	-- The lock goes on the cue as well as the prompt: the glow is what says a lever is pullable, so a lit
	-- one over a shut prompt only sends the player over to press nothing.
	if
		self._rolling
		or not self:IsOwned()
		or EquippedItem.GetTool()
		or IngredientRollingController:IsRollLocked()
	then
		self._lever:RemoveTag(Highlights.TAG)
	else
		self._lever:AddTag(Highlights.TAG)
	end
end

-- Puts the roll prompt and the lever's cue up on the local player's own base and takes them down
-- otherwise, so a visitor can watch a pull without being offered one the server would only reject.
function Base:RefreshInteraction()
	IngredientRollingController = IngredientRollingController or require(script.Parent)

	local owned = self:IsOwned()

	if owned and not self._prompt then
		local prompt = Instance.new("ProximityPrompt")
		prompt.RequiresLineOfSight = false
		prompt.HoldDuration = PROMPT_HOLD
		prompt.ActionText = "Roll Ingredients"
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.Parent = self._leverHandle

		self._prompt = prompt
		self._promptCleaner:Add(prompt)
		self._promptCleaner:Connect(prompt.Triggered, function()
			self:RollIngredients()
		end)
	elseif not owned and self._prompt then
		self._promptCleaner:Clean()
		self._prompt = nil
	end

	if self._prompt then
		self._prompt.Enabled = not self._rolling and not IngredientRollingController:IsRollLocked()
	end

	self:_refreshLeverHighlight()

	for _, stand in self._stands do
		stand:RefreshInteraction()
	end
end

function Base:Destroy()
	self._cleaner:Destroy()
	self = nil
end

return Base
