-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Assets
local Assets = ReplicatedStorage.Assets
local Particles = Assets.Particles

-- Shared
local Shared = ReplicatedStorage.Shared
local RandomUtil = require(Shared.RandomUtil)
local GlobalUtil = require(Shared.GlobalUtil)
local MathUtil = require(Shared.MathUtil)

-- Modules
local PitchLadder = require(script.Parent.Parent.Modules.PitchLadder)
local EffectUtil = require(script.Parent.Parent.Modules.EffectUtil)

--
local EffectController = require(script.Parent.Parent.Controllers.EffectController)
local SoundController = require(script.Parent.Parent.Controllers.SoundController)
local CurrencyController = require(script.Parent.Parent.Controllers.CurrencyController)

--
local LocalPlayer = Players.LocalPlayer

--
local FLIGHT_DURATION = 0.8
local FLIGHT_DURATION_VARIANCE = 0.15
local BURST_DISTANCE_MIN, BURST_DISTANCE_MAX = 10, 15
local BURST_HEIGHT_MIN, BURST_HEIGHT_MAX = 10, 15
local LAUNCH_DELAY_MAX = 0.12
local TARGET_HEIGHT_OFFSET = 2

-- Extra time before cleanup, so particles emitted last still finish their lifetime
local CLEANUP_PADDING = 0.5

-- Per-player pitch ladder so each collector ramps independently.
local pitch = PitchLadder.new({ Max = 1.7, MaxHits = 1 })

-- Bursts one cash part outward then curves it into the target, popping a "+X" on arrival.
local function launchProjectile(template: BasePart, startPosition: Vector3, targetPlayer: Player, popupValue: number?)
	local clone = template:Clone()
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CFrame = CFrame.new(startPosition)
	clone.Parent = workspace

	-- Random outward/upward peak used as the bezier control point so the cash bursts before curving back.
	local burstAngle = RandomUtil.GetRandomFromMinMax(0, math.pi * 2)
	local burstDistance = RandomUtil.GetRandomFromMinMax(BURST_DISTANCE_MIN, BURST_DISTANCE_MAX)
	local controlPosition = startPosition
		+ Vector3.new(
			math.cos(burstAngle) * burstDistance,
			RandomUtil.GetRandomFromMinMax(BURST_HEIGHT_MIN, BURST_HEIGHT_MAX),
			math.sin(burstAngle) * burstDistance
		)

	local spinAxis = Vector3.new(
		RandomUtil.GetRandomFromMinMax(-1, 1),
		RandomUtil.GetRandomFromMinMax(-1, 1),
		RandomUtil.GetRandomFromMinMax(-1, 1)
	).Unit
	local duration = FLIGHT_DURATION
		+ RandomUtil.GetRandomFromMinMax(-FLIGHT_DURATION_VARIANCE, FLIGHT_DURATION_VARIANCE)
	local startTime = os.clock()
	local connection

	connection = RunService.RenderStepped:Connect(function()
		local character = targetPlayer.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if not (rootPart and clone:IsDescendantOf(workspace)) then
			connection:Disconnect()
			clone:Destroy()
			return
		end

		local alpha = math.clamp((os.clock() - startTime) / duration, 0, 1)
		local easedAlpha = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		-- Recompute the target each frame so the cash tracks the player as they move.
		local targetPosition = rootPart.Position + Vector3.new(0, TARGET_HEIGHT_OFFSET, 0)
		local position = MathUtil.QuadraticBezier(easedAlpha, startPosition, controlPosition, targetPosition)
		clone.CFrame = CFrame.new(position) * CFrame.fromAxisAngle(spinAxis, (os.clock() - startTime))

		if alpha >= 1 then
			connection:Disconnect()
			clone:Destroy()

			SoundController:PlaySound(
				"CashCollected",
				character.PrimaryPart,
				{ PlaybackSpeed = Random.new():NextNumber(0.97, 1) },
				true
			)

			if popupValue then
				CurrencyController:SpawnCurrencyPopup(popupValue)
			end
		end
	end)
end

-- Bursts cash off a character's whole body, welded so it rides along as they walk off.
local function burstCashOffBody(character: Model, rootPart: BasePart)
	-- The rig's own parts, not GetBoundingBox, which would include the held skewer and blow the burst out
	local min, max
	for _, part in character:GetChildren() do
		if not part:IsA("BasePart") then
			continue
		end

		local halfSize = part.Size / 2
		min = min and min:Min(part.Position - halfSize) or part.Position - halfSize
		max = max and max:Max(part.Position + halfSize) or part.Position + halfSize
	end

	-- On a part matching the character's volume, so the cash bursts off the whole body
	local emitterPart = Instance.new("Part")
	emitterPart.Size = max - min
	emitterPart.CFrame = CFrame.new((min + max) / 2)
	emitterPart.Transparency = 1
	emitterPart.Anchored = false
	emitterPart.CanCollide = false
	emitterPart.CanQuery = false
	emitterPart.CanTouch = false
	emitterPart.Massless = true
	emitterPart.Parent = workspace.Effects

	-- Part0 is ours, so the weld goes with the part rather than orphaning on a pooled rig
	GlobalUtil.Weld(emitterPart, rootPart)

	local effect = EffectUtil.ParentEffectFolder(Particles.Cash, emitterPart)
	effect.EmitParticles()

	local lifetime = 0
	for _, particle in effect.Particles do
		lifetime = math.max(lifetime, particle.Lifetime.Max)
	end

	task.delay(lifetime + CLEANUP_PADDING, function()
		effect.Cleanup()
		emitterPart:Destroy()
	end)
end

-- Plays the collect-cash effect from a CFrame, part or model, splitting `value` across projectiles.
return function(origin: CFrame | BasePart | Model, value: number?, targetPlayer: Player?)
	local target = targetPlayer or LocalPlayer

	local originCFrame: CFrame
	if typeof(origin) == "CFrame" then
		originCFrame = origin
	elseif origin:IsA("BasePart") then
		originCFrame = origin.CFrame
	else
		local rootPart = origin:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			originCFrame = rootPart.CFrame

			-- Cash also bursts off the whole rig, so the sale reads on the character, not just as projectiles
			burstCashOffBody(origin, rootPart)
		else
			-- NPC rigs get pooled away, so the character can already be gone by the time this reaches us
			originCFrame = origin:GetPivot()
		end
	end

	-- A raw CFrame has no instance to flash, so only pulse when handed a part or model
	if typeof(origin) ~= "CFrame" then
		EffectController:RunEffect("HighlightPulse", { origin, Color3.fromRGB(85, 255, 0), 1, 0.3 })
	end

	-- Ramp the pitch up on each consecutive collect, resetting once the player pauses for long enough.
	SoundController:PlaySound("CashCollect", originCFrame, { PlaybackSpeed = pitch:Next(target) })

	local projectileAmount = RandomUtil.GetRandomIntFromMinMax(4, 6)
	local projectile = Particles.CashProjectile
	local startPosition = originCFrame.Position

	-- Split across projectiles, skipping labels below 1. Screen UI, so only the player being paid sees them
	local popupValue = if target == LocalPlayer and value then math.floor(value / projectileAmount) else nil
	if popupValue and popupValue < 1 then
		popupValue = nil
	end

	for _ = 1, projectileAmount do
		task.delay(
			RandomUtil.GetRandomFromMinMax(0, LAUNCH_DELAY_MAX),
			launchProjectile,
			projectile,
			startPosition,
			target,
			popupValue
		)
	end
end
