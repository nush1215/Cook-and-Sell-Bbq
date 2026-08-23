-- Camera
local Camera = workspace.CurrentCamera

-- Cache the viewport size once and refresh it on change so the per-particle
-- update loop never has to touch the camera every frame.
local viewportX, viewportY = Camera.ViewportSize.X, Camera.ViewportSize.Y
Camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
	viewportX, viewportY = Camera.ViewportSize.X, Camera.ViewportSize.Y
end)

-- Size is expressed as a viewport scale (fraction of the screen) instead of a fixed
-- pixel offset so confetti shrinks proportionally on small screens instead of looking massive.
-- DEFAULT_SIZE is the fraction of viewport height (0.028 ~= 30px on a 1080-tall screen).
local DEFAULT_SIZE = 0.028

-- Forces/gravity are authored in pixels for a screen this tall. The motion is rescaled to the
-- live viewport so a velocity covers the same fraction of the screen on every resolution -- on a
-- small screen, fixed-pixel velocities would otherwise rocket particles off-screen in a few frames.
local REFERENCE_VIEWPORT_Y = 1080

-- Reference simulation rate. :Update(dt) scales its motion by dt/STEP so the effect is frame-rate
-- independent: at 60 fps a frame is exactly one step (identical to the original tuning), lower fps
-- takes proportionally bigger steps to keep wall-clock speed, and high-refresh displays take smaller
-- ones without fast-forwarding. One update per frame (no fixed-step batching) keeps it judder-free.
local STEP = 1 / 60
-- Per-step velocity drag, stored as the reciprocal so it can be raised to a fractional step count.
local DRAG_X = 1 / 1.01
local DRAG_Y = 1 / 1.05
local DEFAULT_COLORS = {
	Color3.fromRGB(255, 0, 0),
	Color3.fromRGB(0, 0, 255),
	Color3.fromRGB(0, 255, 0),
	Color3.fromRGB(255, 255, 0),
	Color3.fromRGB(255, 165, 0),
	Color3.fromRGB(255, 105, 180),
	Color3.fromRGB(0, 255, 255),
	Color3.fromRGB(255, 215, 0),
}

-- Reuse ImageLabels from a pool so heavy bursts/rain never thrash Instance.new/Destroy.
local POOL_SIZE = 100
local labelPool = {}

local function createLabel(): ImageLabel
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.ZIndex = 20
	label.Visible = false
	return label
end

for _ = 1, POOL_SIZE do
	table.insert(labelPool, createLabel())
end

-- Pooled labels stay parented while idle, so reusing one with the same parent skips the reparent.
local function acquireLabel(parent: Instance): ImageLabel
	local label = table.remove(labelPool) or createLabel()
	if label.Parent ~= parent then
		label.Parent = parent
	end
	return label
end

local UIConfetti = {}
UIConfetti.__index = UIConfetti

type ConfettiOptions = {
	Position: Vector2,
	Force: Vector2,
	Gravity: Vector2,
	Parent: GuiBase,
	Images: { string },
	Colors: { Color3 }?,
	Spin: boolean?,
	Scale: number?,
	ScaleType: Enum.ScaleType?,
}

function UIConfetti.new(options: ConfettiOptions)
	if not options then
		return
	end

	local images = options.Images
	if not images or #images == 0 then
		warn("UIConfetti.new requires options.Images with at least one image")
		return
	end

	local self = setmetatable({}, UIConfetti)

	local force = options.Force
	local xForce = if force.X < 0 then -force.X else force.X
	local gravity = options.Gravity or Vector2.new(0, 1)
	local colors = options.Colors or DEFAULT_COLORS
	local color = colors[math.random(#colors)]

	-- Convert pixel-authored velocity/gravity to the live viewport so the trajectory covers the
	-- same fraction of the screen at any resolution (the integrated position scales linearly too).
	local motionScale = viewportY / REFERENCE_VIEWPORT_Y

	-- Scalar state avoids allocating Vector2s every frame in :Update().
	self.EmitterX, self.EmitterY = options.Position.X, options.Position.Y
	self.GravityX, self.GravityY = gravity.X * motionScale, gravity.Y * motionScale
	self.PosX, self.PosY = 0, 0
	self.PowerX, self.PowerY = force.X * motionScale, (force.Y - (xForce * 0.8)) * motionScale

	self.Colors = colors
	self.CurrentColor = color
	self.Spin = options.Spin ~= false

	local baseSize = DEFAULT_SIZE * (options.Scale or 1)
	self.BaseSize = baseSize

	local label = acquireLabel(options.Parent)
	label.Image = images[math.random(#images)]
	label.Size = UDim2.fromScale(baseSize, baseSize)
	-- Always set this (even back to the default) so a pooled label doesn't keep a prior ScaleType.
	label.ScaleType = options.ScaleType or Enum.ScaleType.Stretch
	label.ImageColor3 = color
	label.Rotation = math.random(360)
	-- Place it at the start before it becomes visible so a reused label doesn't flicker at its old spot.
	label.Position = UDim2.new(self.EmitterX, 0, self.EmitterY, 0)
	label.Visible = true
	self.Label = label

	self.Size = baseSize
	self.Side = -1
	self.OutOfBounds = false
	self.Enabled = false
	self.Cycles = 0

	return self
end

function UIConfetti:Update(dt: number)
	local label = self.Label
	local enabled = self.Enabled

	if enabled and self.OutOfBounds then
		label.ImageColor3 = self.CurrentColor
		self.Cycles += 1
	end

	if not enabled and (self.OutOfBounds or self.Cycles == 0) then
		label.Visible = false
		self.OutOfBounds = true
		self.CurrentColor = self.Colors[math.random(#self.Colors)]
		return
	end

	label.Visible = true

	-- How many reference (1/60 s) steps this frame represents. At 60 fps this is 1, so the math
	-- below reduces to the original per-step formulas; off 60 fps it scales motion to keep the
	-- effect frame-rate independent.
	local steps = dt / STEP

	local gravityX, gravityY = self.GravityX, self.GravityY
	local newPosX = self.PosX - self.PowerX * steps
	local newPosY = self.PosY - self.PowerY * steps
	-- Light horizontal drag only. A heavy divisor here makes PowerX asymptote to zero
	-- (there's no horizontal gravity for side bursts), so particles decelerate to a halt
	-- at a fixed offset from their edge and pile up mid-screen. Keep most of the momentum
	-- so they arc across and fall spread out instead. Drag is raised to the step count so the
	-- decay matches wall-clock time; gravity is an acceleration so it scales linearly.
	local newPowerX = self.PowerX * DRAG_X ^ steps - gravityX * steps
	local newPowerY = self.PowerY * DRAG_Y ^ steps - gravityY * steps

	label.Position = UDim2.new(self.EmitterX, newPosX, self.EmitterY, newPosY)

	-- Compute the on-screen position from the scale emitter + pixel offset instead of reading
	-- AbsolutePosition back every frame (assumes a full-screen parent, which the controller uses).
	local absX = self.EmitterX * viewportX + newPosX
	local absY = self.EmitterY * viewportY + newPosY
	self.OutOfBounds = (absX > viewportX and gravityX > 0)
		or (absY > viewportY and gravityY > 0)
		or (absX < 0 and gravityX < 0)
		or (absY < 0 and gravityY < 0)

	self.PosX, self.PosY = newPosX, newPosY
	self.PowerX, self.PowerY = newPowerX, newPowerY

	-- spin
	if self.Spin and newPowerY < 0 then
		local size, side = self.Size, self.Side
		local baseSize = self.BaseSize
		local color = self.CurrentColor
		-- Step the height scale over ~15 frames per flip, matching the original offset cadence.
		local step = baseSize / 15

		if size <= 0 then
			side = 1
			label.ImageColor3 = color
		elseif size >= baseSize then
			side = -1
			label.ImageColor3 = Color3.new(color.R * 0.9, color.G * 0.9, color.B * 0.9)
		end

		size += side * step * steps
		self.Side, self.Size = side, size
		label.Size = UDim2.fromScale(baseSize, size)
	end
end

function UIConfetti:Toggle()
	self.Enabled = not self.Enabled
end

function UIConfetti:Destroy()
	self.Label.Visible = false
	table.insert(labelPool, self.Label)
	table.clear(self)
	setmetatable(self, nil)
end

return UIConfetti
