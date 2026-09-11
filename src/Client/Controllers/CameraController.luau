-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local CameraShaker = require(Packages.CameraShaker)

--
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer
local DefaultPosInfluence = Vector3.new(0.15, 0.15, 0.15)
local DefaultRotInfluence = Vector3.new(1, 1, 1)

-- How a taken camera travels. Tweened rather than sprung: the hand-back has to know exactly when it has
-- landed, and a tween says so where a spring only ever settles quietly
local CAMERA_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--
local CameraController = {
	Camera = Camera,
	_cameraShaker = nil,
	-- Where the camera sits before shake. The shaker below is the only thing that writes Camera.CFrame, so
	-- anything wanting to move the camera moves this instead
	_lockedCFrame = nil,
	_cameraProxy = nil, -- what the tween drives, since the Camera itself is already spoken for
	_cameraTween = nil, -- the one in flight, cancelled by whatever takes the camera next
	_cameraToken = 0, -- bumped per take-over, so a restore still in flight can't release a camera taken again
}

--
local function validateCameraShaker(self: any): boolean
	if not self._cameraShaker then
		warn("Camera shaker not initialized")
		return false
	end
	return true
end

-- Shakes the camera once, with its own magnitude, roughness, fades and position/rotation influence.
function CameraController:ShakeCustom(
	magnitude: number,
	roughness: number,
	fadeInTime: number,
	fadeOutTime: number,
	posInfluence: Vector3,
	rotInfluence: Vector3
)
	if not validateCameraShaker(self) then
		return
	end

	self._cameraShaker:ShakeOnce(magnitude, roughness, fadeInTime, fadeOutTime, posInfluence, rotInfluence)
end

-- Where the camera is right now, for a caller that means to hand it back there afterwards.
function CameraController:GetCameraState(): { Type: Enum.CameraType, CFrame: CFrame }
	return { Type = Camera.CameraType, CFrame = Camera.CFrame }
end

-- Stops whatever the camera was doing, so two take-overs never drive it at once.
function CameraController:_cancelCameraTween()
	if self._cameraTween then
		self._cameraTween:Cancel()
		self._cameraTween = nil
	end
end

-- Takes the camera and moves it to `cframe`. Shake keeps working on top: this drives the offset the shaker reads rather than fighting it for Camera.CFrame, which the shaker rewrites every frame.
function CameraController:TweenCameraCFrameTo(cframe: CFrame, tweenInfo: TweenInfo?)
	self._cameraToken += 1
	self:_cancelCameraTween()

	-- Seeded from where the camera is, and locked before the type flips. A frame of Scriptable with no lock
	-- lets a running shake compound onto its own output and walk the camera off into space
	if Camera.CameraType ~= Enum.CameraType.Scriptable then
		self._cameraProxy.Value = Camera.CFrame
		self._lockedCFrame = Camera.CFrame
		Camera.CameraType = Enum.CameraType.Scriptable
	end

	local tween = TweenService:Create(self._cameraProxy, tweenInfo or CAMERA_TWEEN, { Value = cframe })
	self._cameraTween = tween
	tween:Play()
end

-- Unlocks the camera and returns it to Custom, so it follows the character again. `cframe` is where to put it on the way out -- handed the one it was taken from, the cut back is to exactly where they were looking.
function CameraController:SetBackToDefault(cframe: CFrame?)
	self._cameraToken += 1
	self:_cancelCameraTween()

	self._lockedCFrame = nil

	if cframe then
		Camera.CFrame = cframe
	end

	-- Straight back rather than travelled: the default camera re-derives its own look from the live CFrame,
	-- so it picks up from here, and nothing is left holding the camera if this is reached mid-flight
	Camera.CameraType = Enum.CameraType.Custom
	self:SetSubject()
end

-- Turns the camera along a horizontal direction, keeping its pitch. Doesn't take control -- the default camera re-derives from the live CFrame.
function CameraController:AlignCameraYawTo(lookDirection: Vector3)
	local pitch = Camera.CFrame:ToEulerAnglesYXZ()
	local yaw = math.atan2(-lookDirection.X, -lookDirection.Z)

	Camera.CFrame = CFrame.new(Camera.CFrame.Position) * CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
end

-- Shakes the camera using a named preset.
function CameraController:ShakePreset(presetName: string)
	if not validateCameraShaker(self) then
		return
	end

	if not CameraShaker.Presets[presetName] then
		warn(`Camera shake preset '{presetName}' not found`)
		return
	end

	return self._cameraShaker:Shake(CameraShaker.Presets[presetName])
end

-- Starts a sustained camera shake, with its own magnitude, roughness, fades and influence.
function CameraController:ShakeSustain(
	magnitude: number,
	roughness: number,
	fadeInTime: number,
	fadeOutTime: number?,
	posInfluence: Vector3?,
	rotInfluence: Vector3?
)
	if not validateCameraShaker(self) then
		return
	end

	-- If one is already running, update it rather than starting a second
	local shakeSustain = self._shakeSustain
	if shakeSustain then
		shakeSustain.Magnitude = magnitude or shakeSustain.Magnitude
		shakeSustain.Roughness = roughness or shakeSustain.Roughness
		shakeSustain.FadeInTime = fadeInTime or shakeSustain.FadeInTime
		shakeSustain.FadeOutTime = fadeOutTime or shakeSustain.FadeOutTime
		shakeSustain.PositionInfluence = posInfluence or shakeSustain.PositionInfluence
		shakeSustain.RotationInfluence = rotInfluence or shakeSustain.RotationInfluence
		return
	end

	self._shakeSustain =
		self._cameraShaker:StartShake(magnitude, roughness, fadeInTime, fadeOutTime, posInfluence, rotInfluence)
end

-- Stops a sustained camera shake.
function CameraController:StopShakeSustain(duration: number?)
	if not validateCameraShaker(self) then
		return
	end

	self._cameraShaker:StopSustained(duration)
	self._shakeSustain = nil
end

-- Sets the camera subject, defaulting to the player's humanoid.
function CameraController:SetSubject(subject: Instance?)
	local character = LocalPlayer.Character
	if not character then
		warn("Player character not found")
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warn("Player humanoid not found")
		return
	end

	Camera.CameraSubject = subject or humanoid
end

function CameraController:OnInit()
	-- A stand-in for where the camera sits before shake. Tweening the Camera itself would just be overwritten
	-- by the bind below, which is the one place in the client allowed to write Camera.CFrame
	local proxy = Instance.new("CFrameValue")
	proxy.Name = "CameraCFrame"
	proxy.Parent = Camera
	self._cameraProxy = proxy

	-- Only while the camera is actually taken: the tween writes this every frame, and a stale write landing
	-- after the hand-back would lock the camera again a frame after it was let go
	proxy.Changed:Connect(function(value: CFrame)
		if Camera.CameraType == Enum.CameraType.Scriptable then
			self._lockedCFrame = value
		end
	end)

	local camShake = CameraShaker.new(Enum.RenderPriority.Camera.Value, function(shakeCFrame: CFrame)
		local offset = self._lockedCFrame or Camera.CFrame
		Camera.CFrame = offset * shakeCFrame
	end)

	camShake:Start()
	self._cameraShaker = camShake
end

function CameraController:OnStart() end

return CameraController
