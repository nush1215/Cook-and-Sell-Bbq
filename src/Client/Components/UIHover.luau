-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)

--
local UIHover = Component.new({
	Tag = script.Name,
})

function UIHover:Start()
	local ui = self.Instance
	local offset = ui:GetAttribute("Offset") or Vector2.new(0, 0.05)
	local speed = ui:GetAttribute("Speed") or 1

	local udim2 = UDim2.fromScale(ui.Position.X.Scale + offset.X, ui.Position.Y.Scale + offset.Y)
	local hoverTween = TweenService:Create(
		ui,
		TweenInfo.new(speed, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Position = udim2 }
	)
	hoverTween:Play()
	self._tween = hoverTween
end

-- Repeats forever, so it must be cancelled by hand or TweenService keeps stepping the destroyed UI
function UIHover:Stop()
	self._tween:Cancel()
	self._tween = nil
end

return UIHover
