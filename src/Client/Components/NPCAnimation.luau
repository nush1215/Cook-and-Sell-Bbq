-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

--
local NPCAnimation = Component.new({
	Tag = script.Name,
})

function NPCAnimation:Start()
	local npc = self.Instance
	local animationId = npc:GetAttribute("AnimationId")

	if not animationId then
		warn("NPCAnimation: No animation ID found")
		return
	end

	local animator: Animator? = npc:FindFirstChildWhichIsA("Animator", true)
	if not animator then
		warn("NPCAnimation: No animator found")
		return
	end

	self._trove = Trove.new()
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	self._trove:Add(animation)

	local animationTrack = animator:LoadAnimation(animation)
	self._trove:Add(animationTrack)

	animationTrack.Looped = true
	animationTrack:Play()
end

function NPCAnimation:Stop()
	-- Nil for a rig Start bailed on (no AnimationId, or no Animator).
	if self._trove then
		self._trove:Destroy()
	end
end

return NPCAnimation
