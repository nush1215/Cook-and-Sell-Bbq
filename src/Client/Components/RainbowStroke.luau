-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

-- Constants
local RAINBOW_SPEED = 5 -- higher = slower

--
local RainbowStroke = Component.new({
	Tag = script.Name,
})

function RainbowStroke:Start()
	--
	local uiStroke = self.Instance

	--
	self._cleaner = Trove.new()

	--
	self._cleaner:Add(RunService.Heartbeat:Connect(function()
		-- Calculate hue based on time (0 to 1)
		local hue = (tick() % RAINBOW_SPEED) / RAINBOW_SPEED

		-- Convert HSV to RGB for rainbow effect
		local rainbowColor = Color3.fromHSV(hue, 1, 1)

		-- Apply the rainbow color to the UIStroke
		uiStroke.Color = rainbowColor
	end))
end

function RainbowStroke:Stop()
	self._cleaner:Destroy()
end

return RainbowStroke
