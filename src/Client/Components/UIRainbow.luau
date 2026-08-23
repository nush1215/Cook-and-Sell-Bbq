-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

--
local RainbowUI = Component.new({
	Tag = script.Name,
})

function RainbowUI:Start()
	self._cleaner = Trove.new()

	--
	local ui = self.Instance

	-- A stroke takes the sequence directly; anything else gets a gradient of its own, which is ours to
	-- take back with the component.
	local rainbowGradient = ui
	if not ui:IsA("UIStroke") then
		rainbowGradient = self._cleaner:Add(Instance.new("UIGradient"))
		rainbowGradient.Parent = ui
	end

	local time = ui:GetAttribute("RainbowSpeed") or 2 -- amount of time it takes to get from 0 to 1
	local range = 10 -- amount of colors

	--
	self._cleaner:Connect(RunService.Heartbeat, function()
		local loop = tick() % time / time
		local colors = {}

		for i = 1, range + 1, 1 do
			local z = Color3.fromHSV(loop - ((i - 1) / range), 1, 1)

			if loop - ((i - 1) / range) < 0 then
				z = Color3.fromHSV((loop - ((i - 1) / range)) + 1, 1, 1)
			end

			local d = ColorSequenceKeypoint.new((i - 1) / range, z)
			table.insert(colors, d)
		end

		rainbowGradient.Color = ColorSequence.new(colors)
	end)
end

function RainbowUI:Stop()
	self._cleaner:Destroy()
end

return RainbowUI
