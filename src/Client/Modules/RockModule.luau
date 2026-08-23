--!strict
--[[
	RockModule
	----------
	Spawns short-lived rock debris effects (craters, explosions) that inherit the
	colour / material / transparency of whatever ground they land on, then clean
	themselves up via the Debris service.

	Public API:
		RockModule.Crater(center, radius?, minRocks?, maxRocks?, playerCollision?)
		RockModule.CraterRows(center, radius?, rows?, nextRowRadius?, minRocks?, maxRocks?, playerCollision?)
		RockModule.Explosion(center, totalRocks?, minSize?, maxSize?, playerCollision?)
		RockModule.ClearDebris(fade?)

	Originally written by @LxckyDev.
	Refactored by @nush_rblx + opus.

	The "RockDebris" collision group this assigns is registered server-side in CollisionManager --
	hardcoded here rather than read off it, since that's a server manager this can't require.
]]

local RockModule = {}

-- Cache services once instead of calling game:GetService inside loops.
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

-- Any instance with this tag is ignored by the ground/material raycasts so
-- rocks never spawn on top of it (or sample its colour).
local IGNORE_TAG = "RockModuleIgnore"

-- Collision group for debris that shouldn't body-block anyone. Registered in CollisionManager.
local DEBRIS_COLLISION_GROUP = "RockDebris"

-- Folder under workspace that holds every spawned rock part.
local DebrisFolder: Folder

-- Make sure the shared Debris folder exists and is cached.
local function ensureDebrisFolder()
	local existing = workspace:FindFirstChild("Debris")
	if existing and existing:IsA("Folder") then
		DebrisFolder = existing
	else
		DebrisFolder = Instance.new("Folder")
		DebrisFolder.Name = "Debris"
		DebrisFolder.Parent = workspace
	end
end

-- Build the RaycastParams shared by an effect call: excludes the debris folder,
-- all player characters, and anything tagged IGNORE_TAG. Assumes
-- ensureDebrisFolder() has already run.
local function buildRaycastParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	local filter: { Instance } = { DebrisFolder }

	-- Don't sample/spawn against player characters.
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(filter, player.Character)
		end
	end

	-- Don't sample/spawn against explicitly-ignored instances.
	for _, instance in CollectionService:GetTagged(IGNORE_TAG) do
		table.insert(filter, instance)
	end

	params.FilterDescendantsInstances = filter
	return params
end

-- Spawns a single ring of rocks pushing up out of the ground beneath `Center`,
-- which then slowly sink and shrink away.
function RockModule.Crater(Center: CFrame, Radius: number, MinRocks: number, MaxRocks: number, PlayerCollision: boolean)
	Radius = Radius or 7
	MinRocks = MinRocks or 7
	MaxRocks = MaxRocks or 10
	-- Defaults to true; only disable collisions when explicitly passed false.
	if PlayerCollision == nil then
		PlayerCollision = true
	end

	ensureDebrisFolder()
	local raycastParams = buildRaycastParams()

	-- Find the ground straight below the center point.
	local ray = workspace:Raycast(Center.Position, Center.UpVector * -1000, raycastParams)
	if not ray then
		return
	end

	local numRocks = math.random(MinRocks, MaxRocks)
	local distance = Radius
	local groundCFrame = CFrame.new(ray.Position)
	local angle = 0

	for _ = 1, numRocks do
		local Rock = Instance.new("Part")
		Rock.Name = "GroundSlam"
		Rock.Size = Vector3.new(math.random(3, 5), math.random(2, 3), math.random(2, 4))

		-- Position the rock on the ring (radius `distance`) around the impact,
		-- start it sunk 5 studs into the ground, then face it inward.
		Rock.CFrame = groundCFrame * CFrame.Angles(0, math.rad(angle), 0) * CFrame.new(0, 0, -distance)
			+ Vector3.new(0, -5, 0)
		Rock.CFrame = CFrame.lookAt(Rock.Position, ray.Position)

		-- Sample the ground directly under each rock so it matches that surface;
		-- fall back to the central hit if there's nothing below it.
		local groundRay = workspace:Raycast(
			Rock.CFrame.Position + Vector3.new(0, 7, 0),
			Vector3.new(0, 2.5, 0) * -1000,
			raycastParams
		)
		local source = groundRay and groundRay.Instance or ray.Instance
		Rock.Color = source.Color
		Rock.Material = source.Material
		Rock.Transparency = source.Transparency

		if PlayerCollision == false then
			Rock.CollisionGroup = DEBRIS_COLLISION_GROUP
		end
		Rock.Anchored = true
		Rock.CanCollide = true
		Rock.Parent = DebrisFolder
		Debris:AddItem(Rock, 30)

		-- Pop up out of the ground.
		TweenService:Create(
			Rock,
			TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ Position = Rock.Position + Vector3.new(0, 4.5, 0) }
		):Play()

		-- After a random delay, sink back down and shrink away.
		task.spawn(function()
			task.wait(math.random(650, 950) / 100)
			TweenService:Create(
				Rock,
				TweenInfo.new(4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Position = Rock.Position + Vector3.new(0, -5, 0), Size = Vector3.new(1, 1, 1) }
			):Play()
		end)

		angle += 360 / numRocks
	end
end

-- Blasts a burst of physics-driven rock shards outward and upward from `Center`,
-- which fade out shortly after landing.
function RockModule.Explosion(
	Center: CFrame,
	TotalRocks: number,
	MinSize: number,
	MaxSize: number,
	PlayerCollision: boolean
)
	TotalRocks = TotalRocks or 7
	MinSize = MinSize or 0.5
	MaxSize = MaxSize or 2.5
	-- Defaults to false (no player collision) for explosions.
	PlayerCollision = PlayerCollision or false

	ensureDebrisFolder()
	local raycastParams = buildRaycastParams()

	-- Sample the ground under the explosion to colour/match the shards.
	local ray = workspace:Raycast(Center.Position, Center.UpVector * -100, raycastParams)
	if not ray then
		return
	end

	for _ = 1, TotalRocks do
		local Rock = Instance.new("Part")
		Rock.Name = "ExplosionPart"

		local RandomSize = math.random(MinSize * 100, MaxSize * 100) / 100.0
		if math.random(1, 5) == 3 then
			-- ~20% chance: a flat pancake-like shard.
			Rock.Size = Vector3.new(RandomSize * 2, 0.15, RandomSize * 2)
		else
			Rock.Size = Vector3.new(RandomSize, RandomSize, RandomSize)
		end

		Rock.CFrame = Center
		Rock.Color = ray.Instance.Color
		Rock.Material = ray.Instance.Material
		Rock.Transparency = ray.Instance.Transparency
		Rock.Orientation = Vector3.new(math.random(-359, 359), math.random(-359, 359), math.random(-359, 359))
		Rock.Anchored = false
		Rock.CanCollide = true
		if PlayerCollision == false then
			Rock.CollisionGroup = DEBRIS_COLLISION_GROUP
		end

		Rock.Parent = DebrisFolder
		Debris:AddItem(Rock, 4.5)

		-- Fling the shard out in a random horizontal direction with a fixed
		-- upward kick. BodyVelocity is deprecated by Roblox but kept here for
		-- the existing behaviour; a brief lifetime lets gravity take over.
		local velocitySpread = 32
		local upwardForce = 22
		local bodyVelocity = Instance.new("BodyVelocity")
		bodyVelocity.Velocity = Vector3.new(
			math.random(-velocitySpread, velocitySpread),
			upwardForce,
			math.random(-velocitySpread, velocitySpread)
		)
		bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
		bodyVelocity.P = 5000
		bodyVelocity.Parent = Rock
		Debris:AddItem(bodyVelocity, 0.25)

		-- Shrink and fade the shard out near the end of its life.
		task.spawn(function()
			task.wait(4)
			TweenService:Create(
				Rock,
				TweenInfo.new(0.75, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut),
				{ Size = Vector3.new(0.1, 0.1, 0.1), Transparency = 1 }
			):Play()
		end)
	end
end

-- Spawns several concentric rings of rocks, each ring wider and with more rocks
-- than the last, for a larger crater.
function RockModule.CraterRows(
	Center: CFrame,
	Radius: number,
	Rows: number,
	NextRowRadius: number,
	MinRocks: number,
	MaxRocks: number,
	PlayerCollision: boolean
)
	if PlayerCollision == nil then
		PlayerCollision = true
	end
	Radius = Radius or 7
	MinRocks = MinRocks or 7
	MaxRocks = MaxRocks or 10
	Rows = Rows or 3
	NextRowRadius = NextRowRadius or 4

	local currentRadius = Radius
	for i = 1, Rows do
		-- Each successive ring is wider and denser (rock count scales with row).
		RockModule.Crater(Center, currentRadius, MinRocks * i, MaxRocks * i, PlayerCollision)
		currentRadius += NextRowRadius
	end
end

-- Removes all spawned debris. When `Fade` is true the parts shrink/fade out
-- first; otherwise they are destroyed immediately.
function RockModule.ClearDebris(Fade: boolean)
	ensureDebrisFolder()

	if Fade then
		for _, v in DebrisFolder:GetChildren() do
			if v:IsA("BasePart") then
				TweenService:Create(
					v,
					TweenInfo.new(0.75, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut),
					{ Size = Vector3.new(0.1, 0.1, 0.1), Transparency = 1 }
				):Play()
				Debris:AddItem(v, 1)
			end
		end
	else
		for _, v in DebrisFolder:GetChildren() do
			v:Destroy()
		end
	end
end

return RockModule
-- Written by @LxckyDev
