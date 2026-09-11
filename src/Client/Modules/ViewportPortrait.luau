-- A dressed rig posed in a ViewportFrame as a head-and-shoulders portrait. Shared by every panel that shows an employee's face, so they're all framed and lit alike.

-- A long lens flatters a face; a wide one gives it a fisheye nose
local PORTRAIT_FOV = 20

-- Studs across the frame should cover, sized on an R6 head plus whatever hair sits on it
local PORTRAIT_SUBJECT_SIZE = 3
local PORTRAIT_FILL = 0.85

-- Lifted a touch off the head's middle, so tall hair isn't cropped off the top
local PORTRAIT_FOCUS = CFrame.new(0, 0.1, 0)

-- Turned three-quarters on and tilted a hair, so a portrait reads as a portrait rather than a mugshot
local PORTRAIT_YAW = math.rad(-20)
local PORTRAIT_PITCH = math.rad(6)

-- A ViewportFrame ignores Lighting entirely, so its fill and key are set here or every face renders flat
local PORTRAIT_AMBIENT = Color3.fromRGB(150, 150, 150)
local PORTRAIT_LIGHT_COLOR = Color3.fromRGB(255, 250, 240)

--
local ViewportPortrait = {}

-- Points a viewport's camera at a head so it fills the frame. Solved off whichever side of the frame is shorter -- FieldOfView is the vertical angle, and an R6 head is wider than it is tall, so a tall frame would crop it at the ears.
function ViewportPortrait.Frame(viewport: ViewportFrame, camera: Camera, head: BasePart)
	local size = viewport.AbsoluteSize

	-- Zero until the GUI has been laid out once; the AbsoluteSize signal brings us back through Reframe
	if size.Y <= 0 then
		return
	end

	local halfAngle = math.rad(PORTRAIT_FOV) / 2
	local aspect = size.X / size.Y
	if aspect < 1 then
		halfAngle = math.atan(math.tan(halfAngle) * aspect)
	end

	local focus = head.CFrame * PORTRAIT_FOCUS
	local distance = (PORTRAIT_SUBJECT_SIZE / PORTRAIT_FILL / 2) / math.tan(halfAngle)
	local placed = focus
		* CFrame.Angles(0, PORTRAIT_YAW, 0)
		* CFrame.Angles(PORTRAIT_PITCH, 0, 0)
		* CFrame.new(0, 0, -distance)

	camera.FieldOfView = PORTRAIT_FOV
	camera.CFrame = CFrame.lookAt(placed.Position, focus.Position)

	-- LightDirection is the way the light travels, so this comes down over the camera's shoulder onto the
	-- face. Derived from the camera rather than the world, so every portrait is lit the same whichever way it faces
	local forward = (focus.Position - camera.CFrame.Position).Unit
	viewport.Ambient = PORTRAIT_AMBIENT
	viewport.LightColor = PORTRAIT_LIGHT_COLOR
	viewport.LightDirection = (forward + Vector3.new(0, -0.9, 0) - camera.CFrame.RightVector * 0.4).Unit
end

-- Clones `rig` into `viewport` and frames its head, giving the viewport a camera if it has none. Hands the clone back for the caller to clean up.
function ViewportPortrait.Show(viewport: ViewportFrame, rig: Model): Model
	local camera = viewport:FindFirstChildOfClass("Camera")
	if not camera then
		camera = Instance.new("Camera")
		camera.Parent = viewport
	end

	-- Its own camera, parented inside it: a viewport ignores workspace.CurrentCamera entirely
	viewport.CurrentCamera = camera

	local clone = rig:Clone()
	clone.Parent = viewport

	local head = clone:FindFirstChild("Head")
	if head then
		ViewportPortrait.Frame(viewport, camera, head)
	end

	return clone
end

-- Frames whatever portrait a viewport is already showing again. For its AbsoluteSize signal, since a viewport measures zero until it's been laid out once.
function ViewportPortrait.Reframe(viewport: ViewportFrame)
	local camera = viewport.CurrentCamera
	local rig = viewport:FindFirstChildWhichIsA("Model")
	local head = rig and rig:FindFirstChild("Head")

	if camera and head then
		ViewportPortrait.Frame(viewport, camera, head)
	end
end

return ViewportPortrait
