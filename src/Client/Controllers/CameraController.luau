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

--
local CameraController = {
	Camera = Camera,
	_cameraShaker = nil,
	_lockedCFrame = nil,
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

-- Locks the camera to a CFrame or BasePart, optionally tweened. Shake is then applied relative to it.
function CameraController:SetCameraCFrameTo(cframe: CFrame | BasePart, animate: boolean, tweenInfo: TweenInfo?)
	if typeof(cframe) == "Instance" then
		cframe = cframe.CFrame
	end

	tweenInfo = tweenInfo or TweenInfo.new(0.4, Enum.EasingStyle.Sine)
	Camera.CameraType = Enum.CameraType.Scriptable

	if animate then
		TweenService:Create(Camera, tweenInfo, { CFrame = cframe }):Play()
		task.delay(tweenInfo.Time, function()
			if not (Camera.CameraType == Enum.CameraType.Scriptable) then
				return
			end

			self._lockedCFrame = cframe
		end)
	else
		Camera.CFrame = cframe
		self._lockedCFrame = cframe
	end
end

-- Unlocks the camera and returns it to Custom, so it follows the character again.
function CameraController:SetBackToDefault()
	self._lockedCFrame = nil
	Camera.CameraType = Enum.CameraType.Custom
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
	local camShake = CameraShaker.new(Enum.RenderPriority.Camera.Value, function(shakeCFrame: CFrame)
		local offset = self._lockedCFrame or Camera.CFrame
		Camera.CFrame = offset * shakeCFrame
	end)

	camShake:Start()
	self._cameraShaker = camShake
end

function CameraController:OnStart() end

return CameraController
