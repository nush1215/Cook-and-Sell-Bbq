-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

--
local UIStroke = Component.new({
	Tag = script.Name,
})

local ORIGINAL_HEIGHT = 1080

function UIStroke:Start()
	-- Made before the early returns below so Stop always has something to destroy.
	self._cleaner = Trove.new()

	--
	local camera = workspace.CurrentCamera
	local stroke: UIStroke = self.Instance

	if stroke:HasTag("IgnoreUIStroke") then
		return
	end

	if stroke.StrokeSizingMode == Enum.StrokeSizingMode.ScaledSize then
		return
	end

	--
	local defaultThickness = stroke.Thickness
	local ratio = defaultThickness / ORIGINAL_HEIGHT

	stroke.Thickness = math.ceil(camera.ViewportSize.Y * ratio)

	-- On the cleaner: the camera outlives every stroke, so a bare connection here would pin each destroyed
	-- stroke -- and its whole cloned UI -- for the rest of the session.
	self._cleaner:Connect(camera:GetPropertyChangedSignal("ViewportSize"), function()
		stroke.Thickness = math.ceil(camera.ViewportSize.Y * ratio)
	end)
end

function UIStroke:Stop()
	self._cleaner:Destroy()
end

return UIStroke
