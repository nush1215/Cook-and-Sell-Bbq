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

-- Shakes the camera once with custom parameters
-- @param magnitude The magnitude of the shake
-- @param roughness The roughness of the shake
-- @param fadeInTime Time to fade in the shake
-- @param fadeOutTime Time to fade out the shake
-- @param posInfluence Position influence vector
-- @param rotInfluence Rotation influence vector
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

-- Sets the camera to a specific CFrame position
-- @param cframe The target CFrame or BasePart to set the camera to
-- @param animate Whether to animate the camera movement (uses tween) or set instantly
-- @param tweenInfo Optional TweenInfo for the animation (defaults to 0.4s Sine easing)
-- @remarks When a CFrame is locked, camera shake will be applied relative to this locked position
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

-- Resets the camera back to default behavior
-- @remarks Unlocks the camera CFrame and sets camera type back to Custom, allowing normal camera following
function CameraController:SetBackToDefault()
	self._lockedCFrame = nil
	Camera.CameraType = Enum.CameraType.Custom
end

-- Turns the camera to look along a horizontal direction, keeping its current pitch
-- @param lookDirection The world-space direction the camera should face
-- @remarks Does not take control of the camera: the default camera re-derives its orientation from
-- the live Camera.CFrame each frame, so it picks this up and keeps following the character as normal
function CameraController:AlignCameraYawTo(lookDirection: Vector3)
	local pitch = Camera.CFrame:ToEulerAnglesYXZ()
	local yaw = math.atan2(-lookDirection.X, -lookDirection.Z)

	Camera.CFrame = CFrame.new(Camera.CFrame.Position) * CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
end

-- Shakes the camera using a preset
-- @param presetName The name of the preset to use
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

-- Starts a sustained camera shake
-- @param magnitude The magnitude of the shake
-- @param roughness The roughness of the shake
-- @param fadeInTime Time to fade in the shake
-- @param fadeOutTime Time to fade out the shake
-- @param posInfluence Position influence vector
-- @param rotInfluence Rotation influence vector
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

	-- If there is already an existing one then we just update that
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

-- Stops a sustained camera shake
function CameraController:StopShakeSustain(duration: number?)
	if not validateCameraShaker(self) then
		return
	end

	self._cameraShaker:StopSustained(duration)
	self._shakeSustain = nil
end

-- Sets the camera subject
-- @param subject Optional subject to set (defaults to player's humanoid)
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
