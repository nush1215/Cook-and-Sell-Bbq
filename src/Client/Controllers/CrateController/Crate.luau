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

--[[
    One spawned crate's own behaviour, on every client -- so an open is something the people around
    you watch rather than something only you see.

    Two states, and Open is terminal. A crate that's been thrown to its slot goes straight into it;
    Idle is the resting hop of a crate that sits waiting to be opened instead, which is what the
    post-tutorial playtime crate will be.

    The open itself: the crate rattles, harder and faster and a little higher each beat, hops once
    more, and slams back down onto its slot -- and on the frame it lands it blows out to POP_SCALE
    while every part turns into a flat block of light and fades, its contents coming out of that
    flash. The reveal is the controller's, since it's the half that has to talk to the server; this
    class just hands off to it at the moment of the pop.
]]

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

-- Changes the crate's state and runs the matching hook. Open is where a crate ends, so nothing moves
-- it out of there.
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

-- The resting hop of a crate that's waiting to be opened rather than being thrown and opened on
-- arrival. Nothing spawns one of those yet -- it's what the post-tutorial playtime crate will be --
-- so this hangs off the AutoIdle spawn flag, and that crate is a flag rather than a rewrite.
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

	-- Pinned to where the crate is now, so this must not start until whatever put it there has
	-- finished moving it or the two fight over the pivot.
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

-- The open: rattle up off the slot, hop, slam back down, and pop into light on the impact -- then
-- hand the reveal over to the controller.
function Crate:OnOpen()
	local model = self.Model

	if self._idleCleaner then
		self._idleCleaner:Destroy()
		self._idleCleaner = nil
	end

	local crate = CratesConfig.GetCrateFromId(model:GetAttribute("CrateId"))
	local basePivot = model:GetPivot()
	local baseScale = model:GetScale()

	-- The rattle: a random jolt per beat, coming faster each time and carrying the crate a little
	-- further off its slot, so it builds rather than just buzzing.
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

		-- The effect owns the puff, the flash and the rattle sound between them, so a beat is one call
		EffectController:RunEffect("CrateTwitch", model)

		task.wait(waitTime)
		waitTime = math.max(waitTime - CratesConfig.TWITCH_WAIT_DECREMENT, CratesConfig.TWITCH_MIN_WAIT)
	end

	if not model:IsDescendantOf(workspace) then
		return
	end

	-- The rattle stops on a full flash across the whole crate, which is what sells the hop as the crate
	-- winding up rather than just pausing
	EffectController:RunEffect("HighlightPulse", { model, CratesConfig.FLASH_COLOR, 1, 0 })

	-- One last hop, straight up and back level -- adding the lift in world space rather than through
	-- the pivot drops the jolt's rotation with it, so the crate rights itself at the top
	task.wait(CratesConfig.TWITCH_SETTLE)
	Spr.target(model, 0.5, 4, { Pivot = basePivot + Vector3.new(0, lift + CratesConfig.WINDUP_LIFT, 0) })
	task.wait(CratesConfig.WINDUP_DURATION)

	if not model:IsDescendantOf(workspace) then
		return
	end

	-- Then straight back down onto the slot. What it lands on is the pop.
	Spr.target(model, 0.5, 5, { Pivot = basePivot })
	SoundController:PlaySound("CrateDrop", model.PrimaryPart, {
		PlaybackSpeed = Random.new():NextNumber(0.97, 1.03),
	})
	task.wait(CratesConfig.SLAM_DURATION)

	if not model:IsDescendantOf(workspace) then
		return
	end

	-- The pop, all on one frame. Neon only reads if nothing is painted over it, so what's painted on
	-- goes first: a SurfaceAppearance overrides colour and material outright, and a decal sits on top
	-- of both -- leave either on and the crate swells and fades without ever lighting up. The model is
	-- a clone that's seconds from being destroyed, so this costs the asset nothing. (Texture inherits
	-- from Decal, so the one check covers both.)
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

	-- Scale only: the slam already owns the pivot, and re-targeting it here with a different damping
	-- would jerk the landing out from under itself
	Spr.target(model, 0.6, 4, { Scale = baseScale * CratesConfig.POP_SCALE })

	-- The impact throws dust the same way any other landing does. The shell is only a husk from here,
	-- but it has to outlive these particles, which is what POP_LINGER is sized for.
	EffectController:RunEffect("CrateLand", model)

	-- Same frame as the pop, so the contents come out of the flash rather than after it. The slot is
	-- handed over rather than read back off the model, which is still mid-spring from the slam.
	CrateController = CrateController or require(script.Parent)
	CrateController:RevealContents(model, basePivot)

	task.delay(CratesConfig.POP_LINGER, function()
		Spr.stop(model)
		model:Destroy()
	end)
end

-- Drops everything this crate owns. Spr is taken off the model first: a Pivot spring on a destroyed
-- instance is still stepped every frame forever, which is the leak that ate the frame rate once
-- already.
function Crate:Destroy()
	Spr.stop(self.Model)
	self._cleaner:Destroy()
end

return Crate
