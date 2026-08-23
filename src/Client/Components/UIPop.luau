-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)

--
local UIPop = Component.new({
	Tag = script.Name,
})

function UIPop:Start()
	local ui = self.Instance
	local uiScale = ui:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = ui
	end

	local popScale = ui:GetAttribute("PopScale") or 1.1
	local popDuration = ui:GetAttribute("PopDuration") or 0.5

	local tweenInfo = TweenInfo.new(popDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true)
	local popTween = TweenService:Create(uiScale, tweenInfo, { Scale = popScale })
	popTween:Play()
	self._tween = popTween
end

function UIPop:Stop()
	if self._tween then
		self._tween:Cancel()
		self._tween = nil
	end
end

return UIPop
