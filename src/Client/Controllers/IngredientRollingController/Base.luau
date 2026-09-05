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

-- Past the 14 studs the tutorial's pull step treats as arrived, so the prompt is up when it points
local PROMPT_DISTANCE = 15

-- How close the player is, as an ordered band so a check can ask whether it's at least rendering
local BAND_NONE = 0
local BAND_RENDER = 1
local BAND_ANIMATE = 2

-- One base's rolling setup: its lever, its stands, and the distance band deciding how much of it is drawn.

--
local Base = {}
Base.__index = Base

function Base.new(model: Model)
	local cleaner = Trove.new()

	local rollingFolder = model.Rolling
	local lever = rollingFolder.Lever
	local leverHandle = lever.Handle

	-- Swings hard on the pull and settles back, underdamped so it rocks rather than easing home.
	local leverSpring = Spring.new(0)
	leverSpring.Damper = 0.3
	leverSpring.Speed = 15

	local leverRestCFrame = leverHandle:GetPivot()

	-- One emitter, since the stands slide as the grid reflows and would pan the roll somewhere new
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

	local self = setmetatable({
		_model = model,
		_id = model.Name,

		_lever = lever,
		_leverHandle = leverHandle,
		_leverSpring = leverSpring,
		_leverRestCFrame = leverRestCFrame,
		_soundEmitter = soundEmitter,

		-- The pull the lever last swung for, so a bank of stands swings it once between them
		_leverPulledAt = nil,

		_standsFolder = rollingFolder.Stands,
		_stands = {}, -- [standId] = Stand

		_band = BAND_NONE,
		_prompt = nil,
		_rolling = false,

		_cleaner = cleaner,
		_standCleaner = cleaner:Construct(Trove),
		_promptCleaner = cleaner:Construct(Trove),
	}, Base)

	cleaner:Add(soundEmitter)

	-- Breathes rather than carrying PromptSubjectHighlight, which would fight it for the same adornee
	lever:SetAttribute("HighlightColor", Highlights.OPERATE)
	cleaner:Add(function()
		lever:RemoveTag(Highlights.TAG)
	end)

	-- The folder is what says which stands exist; the number filter keeps a landed result from reading as one
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

-- The fixed point this base's rolling sounds play from. See the emitter in Base.new.
function Base:GetSoundEmitter(): BasePart
	return self._soundEmitter
end

-- Whether the local player owns this base, and so gets its prompts.
function Base:IsOwned(): boolean
	return LocalPlayer:GetAttribute("BaseId") == self._id
end

-- The base's owner, if any. BaseId is on the player, so a visitor's fly-in can read who to fly to.
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

-- Reconciles Stand instances against the folder, leaving unchanged stands and their rolls untouched.
function Base:_reconcileStands()
	-- Drop stands whose model the server took away (a downgrade, or the base being cleared)
	for id, stand in self._stands do
		if not self._standsFolder:FindFirstChild(id) then
			self._standCleaner:Remove(stand)
			self._stands[id] = nil
		end
	end

	-- A Stand reads its own attributes as it's built, so one arriving stamped puts its roll straight up
	for _, standModel in self._standsFolder:GetChildren() do
		if not tonumber(standModel.Name) or self._stands[standModel.Name] then
			continue
		end

		local stand = Stand.new(standModel, self)
		self._stands[standModel.Name] = stand
		self._standCleaner:Add(stand)
	end
end

-- Re-picks the distance band, widened by hysteresis so a player on a boundary doesn't thrash the models.
function Base:RefreshProximity(position: Vector3?)
	local band = BAND_NONE

	-- No character is no viewpoint, so nothing is near anything
	if position then
		local margin = RollingConfig.DISTANCE_HYSTERESIS
		local animateDistance = RollingConfig.ANIMATE_DISTANCE + (if self:IsAnimating() then margin else 0)
		local renderDistance = RollingConfig.RENDER_DISTANCE + (if self:IsRendered() then margin else 0)

		-- Measured to the lever's rest pose, it being the fixed point the stands slide around
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

		-- Parked, since Update stops driving it -- otherwise it stays halfway down until someone walks back
		self._leverSpring.Position = 0
		self._leverSpring.Velocity = 0
		self._leverHandle:PivotTo(self._leverRestCFrame)

		return
	end

	for _, stand in self._stands do
		stand:Sync()
	end
end

-- Per-frame driver for the lever and stands, skipped on a far base so cost scales with what's near.
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
	SoundController:PlaySound("LeverPull", self._soundEmitter)
end

-- Swings the lever for a pull the stands report. The owner's already swung on the press, so theirs is skipped.
function Base:SwingLeverForPull(rolledAt: number)
	if self:IsOwned() or self._leverPulledAt == rolledAt then
		return
	end

	self._leverPulledAt = rolledAt
	self:SwingLever()
end

-- Pulls the lever: swings, asks the server, and holds the prompt down until the roll plays out. Owner only.
function Base:RollIngredients()
	IngredientRollingController = IngredientRollingController or require(script.Parent)

	-- Checked here too -- the prompt goes down a frame after it's taken, and a trigger in flight would land
	if self._rolling or IngredientRollingController:IsRollLocked() then
		return
	end

	self._rolling = true
	self:RefreshInteraction()

	-- Swing up front so it reads as instant; nothing cycles until the stands are told, so a rejection never animates
	self:SwingLever()
	CameraController:ShakeCustom(1, 5, 0.15, 0.3)

	local rolledAt, duration = IngredientRollingController:RequestRoll()

	if rolledAt then
		-- Wait the server's own roll length first, since a stand not yet told reads as not rolling
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

-- Breathes only with empty hands and never mid-roll, or a free pull would leave it lit permanently.
function Base:_refreshLeverHighlight()
	IngredientRollingController = IngredientRollingController or require(script.Parent)

	-- On the cue as well as the prompt -- a lit lever over a shut one sends the player to press nothing
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

-- Puts the roll prompt and lever cue up on the owner's base only, so a visitor can watch without being offered one.
function Base:RefreshInteraction()
	IngredientRollingController = IngredientRollingController or require(script.Parent)

	local owned = self:IsOwned()

	if owned and not self._prompt then
		local prompt = Instance.new("ProximityPrompt")
		prompt.RequiresLineOfSight = false
		prompt.HoldDuration = PROMPT_HOLD
		prompt.MaxActivationDistance = PROMPT_DISTANCE
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
