-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Replica = require(Packages.Replica)

-- Shared
local Shared = ReplicatedStorage.Shared
local Animations = require(Shared.Animations)

-- Local Player
local LocalPlayer = Players.LocalPlayer

--
local AnimationController = {
	_animationTracks = {},
	_animator = nil,
}

function AnimationController:PlayAnimation(animationName: string)
	local animationTrack = self._animationTracks[animationName] or self:_loadAnimation(animationName)
	if not animationTrack then
		warn("Animation not found:", animationName)
		return
	end

	animationTrack:Play()
end

function AnimationController:StopAnimation(animationName: string)
	local animationTrack = self._animationTracks[animationName]
	if not animationTrack then
		warn("Animation not found:", animationName)
		return
	end

	animationTrack:Stop()
end

function AnimationController:SetAnimationSpeed(animationName: string, speed: number)
	local animationTrack = self._animationTracks[animationName]
	if not animationTrack then
		warn("Animation not found:", animationName)
		return
	end

	animationTrack:AdjustSpeed(speed)
end

function AnimationController:_loadAnimation(animationName: string)
	local animationId = Animations[animationName]
	if animationId == nil then
		warn("Animation id not found:", animationName)
		return
	end
	if typeof(animationId) ~= "string" then
		return -- nested groups (e.g. Npc) aren't local-player animations
	end

	if not self._animator then
		warn("Animator not ready, cannot load animation:", animationName)
		return
	end

	local animation = Instance.new("Animation")
	animation.Name = animationName
	animation.AnimationId = animationId

	local animationTrack = self._animator:LoadAnimation(animation)
	self._animationTracks[animationName] = animationTrack

	return animationTrack
end

function AnimationController:_initAnimations()
	local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
	local humanoid = character:WaitForChild("Humanoid", 5)
	self._animator = humanoid:WaitForChild("Animator", 5)

	for animationName in Animations do
		self:_loadAnimation(animationName)
	end
end

function AnimationController:OnInit()
	LocalPlayer.CharacterAdded:Connect(function()
		self:_initAnimations()
	end)

	self:_initAnimations()
end

return AnimationController
