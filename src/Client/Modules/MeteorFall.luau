-- Services
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")

-- Meteor entry: how far up / to the side the crate starts before diving in (diagonal, not straight down).
local ENTRY_HEIGHT = 220
local ENTRY_HORIZONTAL = 150

-- Tumbles on the way down, rounded to whole turns at runtime so it settles on the resting orientation
local TUMBLE_TURNS = 2.5

-- How long to wait for the crate to replicate; crash events carry a UniqueId, not the model
local DEFAULT_CRATE_WAIT = 10

local CRATE_TAG = "Crate"
local UNIQUE_ID_ATTRIBUTE = "UniqueId"

-- Every play binds its own render step name, so several meteors can fall at once
local bindCounter = 0

export type MeteorFallOptions = {
	Duration: number,
	LandingCFrame: CFrame,
	OnFrame: ((alpha: number, position: Vector3) -> ())?, -- fires on in-flight frames only, not the landing frame
	OnLanded: (() -> ())?, -- fires once, after the final PivotTo to the landing CFrame
}

-- Client-side crash-in: yanks an at-rest crate up to a diagonal entry and dives it back down. Purely visual.
local MeteorFall = {}

-- Finds the tagged crate with `uniqueId`, waiting up to `timeout` for it and its PrimaryPart. Nil if it never arrives.
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

-- Plays the fall, snapping to the entry point synchronously so the resting crate never shows. Returns an idempotent cancel.
function MeteorFall.Play(model: Model, options: MeteorFallOptions): () -> ()
	local duration = options.Duration
	local landingCFrame = options.LandingCFrame
	local landingPos = landingCFrame.Position

	-- Diagonal meteor entry: high up and off to one side
	local startPos = landingPos + Vector3.new(ENTRY_HORIZONTAL, ENTRY_HEIGHT, ENTRY_HORIZONTAL)
	local travelDir = (landingPos - startPos).Unit

	-- Orient the crate diving along its travel direction, then settle to the landing orientation
	local startRot = CFrame.lookAt(Vector3.zero, travelDir).Rotation
	local landingRot = landingCFrame.Rotation

	-- Tumble end-over-end around a horizontal axis perpendicular to the dive direction
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

	-- Snap to the start before the next render, so the player never sees the resting crate first
	model:PivotTo(CFrame.new(startPos) * startRot)

	local startTime = os.clock()
	RunService:BindToRenderStep(bindName, Enum.RenderPriority.Camera.Value + 1, function()
		if not model.Parent then
			cancel()
			return
		end

		local alpha = math.clamp((os.clock() - startTime) / duration, 0, 1)
		-- Quad-In so it accelerates downward like a falling meteor
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

		-- A world-space tumble over the orientation blend, rounded to whole turns so it lands with no snap
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
