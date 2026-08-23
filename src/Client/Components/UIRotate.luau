-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

--
local UIRotate = Component.new({
	Tag = script.Name,
})

function UIRotate:Start()
	self._cleaner = Trove.new()

	local uiElement = self.Instance
	local speed = uiElement:GetAttribute("Speed") or 0.25

	self._cleaner:Connect(RunService.Heartbeat, function(deltaTime)
		uiElement.Rotation += speed * 60 * deltaTime
	end)
end

function UIRotate:Stop()
	self._cleaner:Destroy()
end

return UIRotate
