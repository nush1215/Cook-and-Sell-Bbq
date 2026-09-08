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

-- Bobs and spins a BasePart, Model or Attachment off one shared loop, tuned by CanHover/HoverAmplitude/HoverSpeed/HoverAxis and CanSpin/SpinDirection/SpinSpeed.
local PartFloat = Component.new({
	Tag = script.Name,
})

-- Shared loop state: the active floaters and the one connection updating them all
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
	-- PVInstances go through GetPivot/PivotTo; an Attachment has no pivot, so its parent-local CFrame is driven instead
	local part: PVInstance | Attachment = self.Instance

	self.instance = part
	self.isAttachment = part:IsA("Attachment")

	-- Anchored at start, so the bob oscillates around a fixed point and the spin accumulates on top
	self.basePivot = if self.isAttachment then part.CFrame else part:GetPivot()
	self.elapsed = 0
	self.spinCFrame = CFrame.identity

	local canHover = part:GetAttribute("CanHover")
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
