-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)

--
local UIPulse = Component.new({
	Tag = script.Name,
})

function UIPulse:Start()
	local ui = self.Instance
	local uiScale = ui:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = ui

		-- Ours to take back on Stop; a UIScale that was already there is left alone.
		self._ownedScale = uiScale
	end

	local pulseScale = ui:GetAttribute("PulseScale") or 1.1
	local pulseDuration = ui:GetAttribute("PulseDuration") or 0.5

	local tweenInfo = TweenInfo.new(pulseDuration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	local pulseTween = TweenService:Create(uiScale, tweenInfo, { Scale = pulseScale })
	pulseTween:Play()
	self._tween = pulseTween
end

-- The tween repeats forever, so it has to be cancelled by hand or TweenService keeps stepping it (and
-- holding the UI) after the element is gone.
function UIPulse:Stop()
	self._tween:Cancel()
	self._tween = nil

	if self._ownedScale then
		self._ownedScale:Destroy()
		self._ownedScale = nil
	end
end

return UIPulse
