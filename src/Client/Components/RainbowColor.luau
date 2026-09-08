-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

--
local RainbowColor = Component.new({
	Tag = script.Name,
})

-- Cycles the tagged instance's Color property through a rainbow.

function RainbowColor:Start()
	self._cleaner = Trove.new()

	local instance = self.Instance

	local time = instance:GetAttribute("RainbowSpeed") or 2 -- amount of time it takes to get from 0 to 1
	local range = 10 -- amount of colors

	-- Check if instance uses Color3 (like BasePart) or ColorSequence (like UIStroke, UIGradient)
	local usesColor3 = instance:IsA("BasePart") or instance:IsA("MeshPart") or instance:IsA("Part")

	self._cleaner:Connect(RunService.Heartbeat, function()
		local loop = tick() % time / time

		if usesColor3 then
			-- For Color3, just use the first color in the sequence
			local color = Color3.fromHSV(loop, 1, 1)
			instance.Color = color
		else
			-- For ColorSequence, create the full sequence
			local colors = {}

			for i = 1, range + 1, 1 do
				local z = Color3.fromHSV(loop - ((i - 1) / range), 1, 1)

				if loop - ((i - 1) / range) < 0 then
					z = Color3.fromHSV((loop - ((i - 1) / range)) + 1, 1, 1)
				end

				local d = ColorSequenceKeypoint.new((i - 1) / range, z)
				table.insert(colors, d)
			end

			instance.Color = ColorSequence.new(colors)
		end
	end)
end

function RainbowColor:Stop()
	self._cleaner:Destroy()
end

return RainbowColor
