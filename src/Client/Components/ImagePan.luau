-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

--
local ImagePan = Component.new({
	Tag = script.Name,
})

function ImagePan:Start()
	self._cleaner = Trove.new()

	local image: ImageLabel = self.Instance

	local panSpeed = image:GetAttribute("PanSpeed") or 0.025
	local panDirection = image:GetAttribute("PanDirection") or Vector2.new(-1, -1)

	local offset = Vector2.new(0, 0)

	self._cleaner:Connect(RunService.RenderStepped, function(deltaTime)
		offset = offset + panDirection * panSpeed * deltaTime
		image.Position = UDim2.new(-offset.X % 1, 0, -offset.Y % 1, 0)
	end)
end

function ImagePan:Stop()
	self._cleaner:Destroy()
end

return ImagePan
