-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

-- Shared
local Shared = ReplicatedStorage.Shared
local RandomUtil = require(Shared.RandomUtil)
local GlobalUtil = require(Shared.GlobalUtil)
local MathUtil = require(Shared.MathUtil)

--
local FLIGHT_DURATION = 0.8
local FLIGHT_DURATION_VARIANCE = 0.15
local BURST_DISTANCE_MIN, BURST_DISTANCE_MAX = 10, 15
local BURST_HEIGHT_MIN, BURST_HEIGHT_MAX = 10, 15
local LAUNCH_DELAY_MAX = 0.12
local TARGET_HEIGHT_OFFSET = 2

-- Extra time before cleanup, so particles emitted last still finish their lifetime
local CLEANUP_PADDING = 0.5

--
local EffectUtil = {}

export type Effect = {
	Clone: Instance,
	Children: { Instance },
	Particles: { ParticleEmitter },
	Cleanup: () -> (),
	EmitParticles: () -> (),
}

-- Clones an effect folder onto `parent`, returning the clone, its children, its emitters and a cleanup.
function EffectUtil.ParentEffectFolder(effectFolder: Instance, parent: Instance): Effect
	local clone = effectFolder:Clone()
	local children = clone:GetChildren()
	local particles = {}

	for _, v in clone:GetDescendants() do
		if v:IsA("ParticleEmitter") then
			table.insert(particles, v)
		end
	end

	for _, v in children do
		v.Parent = parent
	end

	return {
		Clone = clone,
		Children = children,
		Particles = particles,
		Cleanup = function()
			for _, v in children do
				v:Destroy()
			end
			clone:Destroy()
		end,
		EmitParticles = function()
			for _, particle in particles do
				particle:Emit(particle:GetAttribute("EmitCount"))
			end
		end,
	}
end

-- Bursts one collectible part outward then curves it into the target, calling `onArrive` with their character as it lands.
local function launchCollectProjectile(
	template: BasePart,
	startPosition: Vector3,
	targetPlayer: Player,
	onArrive: (character: Model) -> ()
)
	local clone = template:Clone()
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CFrame = CFrame.new(startPosition)
	clone.Parent = workspace

	-- Random outward/upward peak used as the bezier control point so the part bursts before curving back.
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

		-- Recompute the target each frame so the part tracks the player as they move.
		local targetPosition = rootPart.Position + Vector3.new(0, TARGET_HEIGHT_OFFSET, 0)
		local position = MathUtil.QuadraticBezier(easedAlpha, startPosition, controlPosition, targetPosition)
		clone.CFrame = CFrame.new(position) * CFrame.fromAxisAngle(spinAxis, (os.clock() - startTime))

		if alpha >= 1 then
			connection:Disconnect()
			clone:Destroy()

			onArrive(character)
		end
	end)
end

-- Launches `count` copies of `template` from `startPosition` into the target on staggered starts. `onArrive` runs as each lands, with their character and that copy's index.
function EffectUtil.LaunchCollectProjectiles(
	template: BasePart,
	startPosition: Vector3,
	targetPlayer: Player,
	count: number,
	onArrive: (character: Model, index: number) -> ()
)
	for index = 1, count do
		task.delay(
			RandomUtil.GetRandomFromMinMax(0, LAUNCH_DELAY_MAX),
			launchCollectProjectile,
			template,
			startPosition,
			targetPlayer,
			function(character: Model)
				onArrive(character, index)
			end
		)
	end
end

-- Bursts `effectFolder`'s particles off a character's whole body, welded so they ride along as it walks off.
function EffectUtil.BurstOffBody(character: Model, rootPart: BasePart, effectFolder: Instance)
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

	-- On a part matching the character's volume, so the particles burst off the whole body
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

	local effect = EffectUtil.ParentEffectFolder(effectFolder, emitterPart)
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

return EffectUtil
