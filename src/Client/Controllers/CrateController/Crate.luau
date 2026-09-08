-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)
local Spring = require(Packages.Spring)

-- Shared
local Shared = ReplicatedStorage.Shared
local RandomUtil = require(Shared.RandomUtil)
local CratesConfig = require(Shared.Config.Crates)

-- Controllers
local Controllers = script.Parent.Parent
local EffectController = require(Controllers.EffectController)
local SoundController = require(Controllers.SoundController)

-- Required lazily to break the cycle: CrateController requires this class.
local CrateController

-- One spawned crate's own behaviour on every client: Idle hops where it sits, Open rattles, slams and pops. The reveal is the controller's, handed off at the pop.

--
export type State = "Idle" | "Open"

--
local Crate = {}
Crate.__index = Crate

-- Creates a state handle for one crate model.
function Crate.new(model: Model)
	local self = setmetatable({
		Model = model,
		State = nil,

		_cleaner = Trove.new(),
		_idleCleaner = nil,
	}, Crate)

	return self
end

-- Changes state and runs the matching hook. Open is terminal, so nothing moves out of it.
function Crate:SetState(state: State): boolean
	if self.State == state or self.State == "Open" then
		return false
	end

	self.State = state

	if state == "Idle" then
		self:OnIdle()
	elseif state == "Open" then
		self:OnOpen()
	end

	return true
end

-- Opens the crate once.
function Crate:Open(): boolean
	return self:SetState("Open")
end

-- The resting hop of a crate waiting to be opened. Nothing spawns one yet -- it hangs off the AutoIdle flag.
function Crate:OnIdle()
	local model = self.Model

	self._idleCleaner = self._cleaner:Extend()

	-- Underdamped, so a hop rocks the crate back down rather than easing it home
	local heightSpring = Spring.new(0)
	heightSpring.Speed = 15
	heightSpring.Damper = 0.6

	local spinSpring = Spring.new(0)
	spinSpring.Speed = 15
	spinSpring.Damper = 0.65

	-- Pinned to where the crate is now, so it must not start while anything is still moving it
	local restCFrame = model:GetPivot()

	self._idleCleaner:Add(RunService.RenderStepped:Connect(function()
		model:PivotTo(
			restCFrame * CFrame.new(0, heightSpring.Position, 0) * CFrame.Angles(0, spinSpring.Position, 0)
		)
	end))

	self._idleCleaner:Add(task.spawn(function()
		while true do
			heightSpring:Impulse(RandomUtil.GetRandomFromMinMax(25, 30))
			spinSpring.Target += RandomUtil.GetRandomFromMinMax(0.5, 1) * (if RandomUtil.RollChance(50) then 1 else -1)

			SoundController:PlaySound("CrateHop", model.PrimaryPart, {
				PlaybackSpeed = Random.new():NextNumber(1, 1.07),
			})

			-- Trails the hop rather than firing with it, so the dust reads as the crate coming back down
			task.delay(CratesConfig.LAND_EFFECT_DELAY, function()
				EffectController:RunEffect("CrateLand", model)
			end)

			task.wait(RandomUtil.GetRandomFromMinMax(1, 4))
		end
	end))
end

-- The open: rattle, hop, slam and pop into light, then hand the reveal to the controller.
function Crate:OnOpen()
	local model = self.Model

	if self._idleCleaner then
		self._idleCleaner:Destroy()
		self._idleCleaner = nil
	end

	local crate = CratesConfig.GetCrateFromId(model:GetAttribute("CrateId"))
	local basePivot = model:GetPivot()
	local baseScale = model:GetScale()

	-- A random jolt per beat, faster and further each time, so the rattle builds rather than buzzes
	local angle = CratesConfig.TWITCH_ANGLE
	local waitTime = CratesConfig.TWITCH_INITIAL_WAIT
	local lift = 0

	for _ = 1, CratesConfig.TWITCH_COUNT do
		-- The server's fallback destroys a crate whose client never got through this
		if not model:IsDescendantOf(workspace) then
			return
		end

		local jolt = CFrame.Angles(
			math.rad(RandomUtil.GetRandomFromMinMax(-angle, angle)),
			math.rad(RandomUtil.GetRandomFromMinMax(-angle, angle)),
			math.rad(RandomUtil.GetRandomFromMinMax(-angle, angle))
		)

		lift = math.min(lift + CratesConfig.TWITCH_LIFT_PER_BEAT, CratesConfig.TWITCH_LIFT_MAX)
		Spr.target(model, 0.5, 6, { Pivot = basePivot * CFrame.new(0, lift, 0) * jolt })

		-- The effect owns the puff, flash and sound between them, so a beat is one call
		EffectController:RunEffect("CrateTwitch", model)

		task.wait(waitTime)
		waitTime = math.max(waitTime - CratesConfig.TWITCH_WAIT_DECREMENT, CratesConfig.TWITCH_MIN_WAIT)
	end

	if not model:IsDescendantOf(workspace) then
		return
	end

	-- The rattle ends on a full flash, which sells the hop as a wind-up rather than a pause
	EffectController:RunEffect("HighlightPulse", { model, CratesConfig.FLASH_COLOR, 1, 0 })

	-- Lifted in world space rather than through the pivot, so the jolt's rotation drops and it rights itself
	task.wait(CratesConfig.TWITCH_SETTLE)
	Spr.target(model, 0.5, 4, { Pivot = basePivot + Vector3.new(0, lift + CratesConfig.WINDUP_LIFT, 0) })
	task.wait(CratesConfig.WINDUP_DURATION)

	if not model:IsDescendantOf(workspace) then
		return
	end

	-- Then straight back down onto the slot. What it lands on is the pop
	Spr.target(model, 0.5, 5, { Pivot = basePivot })
	SoundController:PlaySound("CrateDrop", model.PrimaryPart, {
		PlaybackSpeed = Random.new():NextNumber(0.97, 1.03),
	})
	task.wait(CratesConfig.SLAM_DURATION)

	if not model:IsDescendantOf(workspace) then
		return
	end

	-- Neon only reads with nothing painted over it, so the SurfaceAppearance and decals go first. The model is seconds from destruction, so this costs the asset nothing
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("SurfaceAppearance") or descendant:IsA("Decal") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Material = Enum.Material.Neon
			descendant.Color = crate.ExplodeColor

			TweenService:Create(descendant, TweenInfo.new(CratesConfig.POP_FADE_DURATION), { Transparency = 1 })
				:Play()
		end
	end

	-- Scale only -- the slam owns the pivot, and re-targeting would jerk the landing out from under itself
	Spr.target(model, 0.6, 4, { Scale = baseScale * CratesConfig.POP_SCALE })

	-- The shell is a husk from here but must outlive these particles, which is what POP_LINGER sizes
	EffectController:RunEffect("CrateLand", model)

	-- Same frame as the pop. The slot is handed over rather than read back, the model still mid-spring
	CrateController = CrateController or require(script.Parent)
	CrateController:RevealContents(model, basePivot)

	task.delay(CratesConfig.POP_LINGER, function()
		Spr.stop(model)
		model:Destroy()
	end)
end

-- Drops everything this crate owns. Spr comes off first -- a Pivot spring on a destroyed instance is stepped forever.
function Crate:Destroy()
	Spr.stop(self.Model)
	self._cleaner:Destroy()
end

return Crate
