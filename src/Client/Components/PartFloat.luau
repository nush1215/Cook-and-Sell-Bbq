-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)

-- Constants (defaults, overridable per-part via attributes)
local HOVER_AMPLITUDE = 0.25 -- How far the part bobs (in studs)
local HOVER_SPEED = 3 -- How fast the bob cycles (radians per second)
local HOVER_AXIS = Vector3.new(0, 1, 0) -- Axis to bob along (Y by default)
local SPIN_DIRECTION = Vector3.new(0, 1, 0) -- Axis to spin around (Y by default)
local SPIN_SPEED = 1 -- Spin rate (radians per second)

--[[
	PartFloat — bobs and/or spins a BasePart, Model or Attachment in place.

	Every floater is driven by a single shared RenderStepped loop rather than
	one connection per instance, so cost scales with how much there is to move,
	not how many tagged objects exist.

	Attributes (all optional):
		CanHover      (boolean)  default true
		HoverAmplitude(number)   default 0.01
		HoverSpeed    (number)   default 3
		HoverAxis     (Vector3)  default (0, 1, 0)

		CanSpin       (boolean)  default true
		SpinDirection (Vector3)  default (0, 1, 0)
		SpinSpeed     (number)   default 1
]]
local PartFloat = Component.new({
	Tag = script.Name,
})

-- Shared loop state: a set of active floaters and the single connection
-- that updates all of them each frame.
local active: { [any]: true } = {}
local connection: RBXScriptConnection? = nil

local function stepAll(deltaTime: number)
	for floater in active do
		floater.elapsed += deltaTime

		if floater.canSpin then
			local dir, speed = floater.spinDirection, floater.spinSpeed
			floater.spinCFrame *= CFrame.Angles(
				dir.X * speed * deltaTime,
				dir.Y * speed * deltaTime,
				dir.Z * speed * deltaTime
			)
		end

		local hoverOffset = CFrame.identity
		if floater.canHover then
			hoverOffset =
				CFrame.new(floater.hoverAxis * math.sin(floater.elapsed * floater.hoverSpeed) * floater.hoverAmplitude)
		end

		local pivot = floater.basePivot * hoverOffset * floater.spinCFrame
		if floater.isAttachment then
			floater.instance.CFrame = pivot
		else
			floater.instance:PivotTo(pivot)
		end
	end
end

function PartFloat:Start()
	-- Works on any PVInstance (a Model or a BasePart) via GetPivot/PivotTo,
	-- so it animates whole models around their pivot just as well as single parts.
	-- An Attachment has no pivot, so it's driven through its CFrame instead --
	-- that's parent-local, so the bob rides along with whatever part it hangs off.
	local part: PVInstance | Attachment = self.Instance

	self.instance = part
	self.isAttachment = part:IsA("Attachment")

	-- Anchor to the pivot at start time so the bob oscillates around a
	-- fixed point instead of drifting, and the spin accumulates on top.
	self.basePivot = if self.isAttachment then part.CFrame else part:GetPivot()
	self.elapsed = 0
	self.spinCFrame = CFrame.identity

	local canHover = part:GetAttribute("CanHover")
	print(canHover)
	if canHover == nil then
		canHover = true
	end
	self.canHover = canHover
	self.hoverAmplitude = part:GetAttribute("HoverAmplitude") or HOVER_AMPLITUDE
	self.hoverSpeed = part:GetAttribute("HoverSpeed") or HOVER_SPEED
	self.hoverAxis = part:GetAttribute("HoverAxis") or HOVER_AXIS

	local canSpin = part:GetAttribute("CanSpin")
	if canSpin == nil then
		canSpin = true
	end
	self.canSpin = canSpin
	self.spinDirection = part:GetAttribute("SpinDirection") or SPIN_DIRECTION
	self.spinSpeed = part:GetAttribute("SpinSpeed") or SPIN_SPEED

	active[self] = true

	-- Spin up the shared loop on the first floater.
	if not connection then
		connection = RunService.RenderStepped:Connect(stepAll)
	end
end

function PartFloat:Stop()
	active[self] = nil

	-- Tear down the shared loop once the last floater is gone.
	if connection and next(active) == nil then
		connection:Disconnect()
		connection = nil
	end
end

return PartFloat
