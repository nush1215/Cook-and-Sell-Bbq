-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

--
local UISway = Component.new({
	Tag = script.Name,
})

function UISway:Start()
	local ui = self.Instance

	self._cleaner = Trove.new()

	local amplitude = ui:GetAttribute("Amplitude") or 5 -- max rotation in degrees
	local speed = ui:GetAttribute("Speed") or 1 -- cycles per second
	local offset = ui:GetAttribute("Offset") or 0 -- phase offset in seconds

	self._defaultRotation = ui.Rotation

	self._cleaner:Add(RunService.RenderStepped:Connect(function()
		ui.Rotation = self._defaultRotation + amplitude * math.sin((tick() + offset) * speed * math.pi * 2)
	end))

	self._cleaner:Add(function()
		ui.Rotation = self._defaultRotation
	end)
end

function UISway:Stop()
	self._cleaner:Destroy()
end

return UISway
