-- Services
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")

-- Meteor entry: how far up / to the side the crate starts before diving in (diagonal, not straight down).
local ENTRY_HEIGHT = 220
local ENTRY_HORIZONTAL = 150

-- How many end-over-end tumbles the crate does on the way down. Rounded to a whole number of turns
-- at runtime so it always settles exactly on the resting orientation, no matter the configured value.
local TUMBLE_TURNS = 2.5

-- How long to wait for a crashing crate to replicate before giving up. Crash events carry the crate's
-- UniqueId (not the model) because a model spawned the same frame the event fires may not have
-- streamed to the client yet.
local DEFAULT_CRATE_WAIT = 10

local CRATE_TAG = "Crate"
local UNIQUE_ID_ATTRIBUTE = "UniqueId"

-- Every play binds its own render step name so several meteors can fall at once on one client
-- without BindToRenderStep collisions.
local bindCounter = 0

export type MeteorFallOptions = {
	Duration: number,
	LandingCFrame: CFrame,
	OnFrame: ((alpha: number, position: Vector3) -> ())?, -- fires on in-flight frames only, not the landing frame
	OnLanded: (() -> ())?, -- fires once, after the final PivotTo to the landing CFrame
}

-- Client-side meteor crash-in: yanks a server-spawned, at-rest crate up to a diagonal entry point
-- and accelerates it back down to its resting spot, tumbling on the way. Purely visual -- the crate
-- never moves on the server; each client animates (or doesn't) its own copy.
local MeteorFall = {}

-- Finds the tagged crate carrying the given UniqueId, waiting up to `timeout` for it to replicate
-- (and for its PrimaryPart to come with it). Returns nil if it never arrives.
-- @param uniqueId: The crate's UniqueId attribute, stamped by CrateManager on spawn
-- @param timeout: Seconds to keep polling before giving up (default 10)
function MeteorFall.WaitForCrate(uniqueId: string, timeout: number?): Model?
	local deadline = os.clock() + (timeout or DEFAULT_CRATE_WAIT)

	while os.clock() < deadline do
		for _, model in CollectionService:GetTagged(CRATE_TAG) do
			if model:GetAttribute(UNIQUE_ID_ATTRIBUTE) == uniqueId and model.PrimaryPart then
				return model
			end
		end
		task.wait()
	end

	return nil
end

-- Plays the fall on the given crate. Snaps it to the entry point synchronously, so callers that
-- invoke this before the next render never show the resting crate first. Returns an idempotent
-- cancel function that stops the animation where it is (also called internally on landing, or when
-- the model leaves the workspace mid-fall).
-- @param model: The crate to animate (already at rest on the server)
-- @param options: Duration, landing CFrame, and optional per-frame / landed callbacks
function MeteorFall.Play(model: Model, options: MeteorFallOptions): () -> ()
	local duration = options.Duration
	local landingCFrame = options.LandingCFrame
	local landingPos = landingCFrame.Position

	-- Diagonal meteor entry: high up and off to one side.
	local startPos = landingPos + Vector3.new(ENTRY_HORIZONTAL, ENTRY_HEIGHT, ENTRY_HORIZONTAL)
	local travelDir = (landingPos - startPos).Unit

	-- Orient the crate diving along its travel direction, then settle to the landing orientation.
	local startRot = CFrame.lookAt(Vector3.zero, travelDir).Rotation
	local landingRot = landingCFrame.Rotation

	-- Tumble end-over-end around a horizontal axis perpendicular to the dive direction.
	local tumbleAxis = travelDir:Cross(Vector3.yAxis)
	tumbleAxis = (tumbleAxis.Magnitude > 1e-3 and tumbleAxis or Vector3.xAxis).Unit

	bindCounter += 1
	local bindName = `MeteorFall{bindCounter}`

	local cancelled = false
	local function cancel()
		if cancelled then
			return
		end
		cancelled = true
		RunService:UnbindFromRenderStep(bindName)
	end

	-- Snap to the start before the next render so the player never sees the resting crate first.
	model:PivotTo(CFrame.new(startPos) * startRot)

	local startTime = os.clock()
	RunService:BindToRenderStep(bindName, Enum.RenderPriority.Camera.Value + 1, function()
		if not model.Parent then
			cancel()
			return
		end

		local alpha = math.clamp((os.clock() - startTime) / duration, 0, 1)
		-- Quad-In so it accelerates downward like a falling meteor.
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

		local pos = startPos:Lerp(landingPos, eased)
		if alpha >= 1 then
			model:PivotTo(landingCFrame)
			cancel()

			if options.OnLanded then
				options.OnLanded()
			end
			return
		end

		-- World-space tumble layered on top of the orientation blend. Rounded to whole turns and
		-- decelerated so it lands exactly on the resting orientation (no snap) as it crashes down.
		local spinProgress = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local spin = CFrame.fromAxisAngle(tumbleAxis, spinProgress * math.round(TUMBLE_TURNS) * math.pi * 2)
		model:PivotTo(CFrame.new(pos) * spin * startRot:Lerp(landingRot, eased))

		if options.OnFrame then
			options.OnFrame(alpha, pos)
		end
	end)

	return cancel
end

return MeteorFall
