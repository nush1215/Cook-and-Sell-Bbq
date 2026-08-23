-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local RandomUtil = require(Shared.RandomUtil)

-- Modules
local Modules = script.Parent.Parent.Modules
local UIConfetti = require(Modules.UIConfetti)

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- Confetti image asset ids to spawn from (fill these in with your own images).
local CONFETTI_IMAGES = {}

local SIDE_AMOUNT = 25
local SIDE_FORCE_X = NumberRange.new(20, 30)
local SIDE_FORCE_Y = NumberRange.new(50, 120)
local SIDE_GRAVITY = 0.75

local RAIN_DURATION = 3
local RAIN_RATE = 0.08
local RAIN_PER_TICK = 5
local RAIN_FORCE_X = NumberRange.new(-5, 5)
local RAIN_FORCE_Y = NumberRange.new(4, 10)
local RAIN_GRAVITY = 0.65

-- Overrides forwarded to UIConfetti; anything omitted falls back to the constants above.
type ConfettiConfig = {
	Images: { string }?, -- images of the confetti rain
	Amount: number?, -- number of confetti to spawn
	Duration: number?, -- duration of the confetti rain
	Rate: number?, -- rate of the confetti rain
	PerTick: number?, -- number of confetti to spawn per tick
	ForceX: NumberRange?, -- force of the confetti rain
	ForceY: NumberRange?, -- force of the confetti rain
	Gravity: number?, -- gravity of the confetti rain
	Colors: { Color3 }?, -- colors of the confetti rain
	Spin: boolean?, -- whether to spin the confetti rain
	Scale: number?, -- scale of the confetti rain
	ScaleType: Enum.ScaleType?, -- ImageLabel ScaleType for the confetti images (defaults to Stretch)
}

--
-- UIConfetti:Update(dt) is frame-rate independent (it scales its motion by dt), so we run exactly
-- one update per frame. This is judder-free at any fps and plays at the same wall-clock speed
-- whether the client is at 30, 60 or 144 -- low fps takes bigger steps, high refresh smaller ones.
-- Clamp dt so a single long frame (a hitch or a tabbed-out window) can't fling particles a huge
-- distance in one jump; the effect just advances a bounded amount that frame instead.
local MAX_DT = 1 / 15

local ConfettiController = {
	_active = {},
	_connection = nil,
}

-- Drives every active particle from one RenderStepped loop, swap-removing and
-- destroying each as it leaves the screen. The loop only runs while particles
-- exist and disconnects itself once the list empties.
function ConfettiController:_ensureRunning()
	if self._connection then
		return
	end

	self._connection = RunService.RenderStepped:Connect(function(dt)
		if dt > MAX_DT then
			dt = MAX_DT
		end

		local active = self._active
		local count = #active
		local i = 1

		while i <= count do
			local confetti = active[i]
			confetti:Update(dt)

			if confetti.OutOfBounds then
				confetti:Destroy()
				-- Swap the tail into this slot so removal stays O(1); reprocess the same index.
				active[i] = active[count]
				active[count] = nil
				count -= 1
			else
				i += 1
			end
		end

		if count == 0 then
			self._connection:Disconnect()
			self._connection = nil
		end
	end)
end

-- Fires a one-shot confetti burst inward from the bottom-left and bottom-right corners.
function ConfettiController:FireSidesConfetti(config: ConfettiConfig?)
	config = config or {}

	local images = config.Images or CONFETTI_IMAGES
	if #images == 0 then
		warn("ConfettiController:FireSidesConfetti requires confetti images")
		return
	end

	local amount = config.Amount or SIDE_AMOUNT
	local forceX = config.ForceX or SIDE_FORCE_X
	local forceY = config.ForceY or SIDE_FORCE_Y
	local gravity = config.Gravity or SIDE_GRAVITY
	local scale = config.Scale or 1
	local active = self._active

	-- forceXSign -1 pushes particles toward the right, +1 toward the left.
	local function spawnSide(positionX: number, forceXSign: number)
		for _ = 1, amount do
			local confetti = UIConfetti.new({
				Position = Vector2.new(positionX, 1),
				Force = Vector2.new(
					forceXSign * RandomUtil.GetRandomFromMinMax(forceX.Min, forceX.Max),
					RandomUtil.GetRandomFromMinMax(forceY.Min, forceY.Max)
				),
				Gravity = Vector2.new(0, gravity),
				Parent = self.UI,
				Images = images,
				Colors = config.Colors,
				Spin = config.Spin,
				Scale = scale,
				ScaleType = config.ScaleType,
			})

			confetti:Toggle()
			table.insert(active, confetti)
		end
	end

	spawnSide(0, -1)
	spawnSide(1, 1)

	self:_ensureRunning()
end

-- Rains confetti down from the top edge for the given duration, spawning small
-- batches over time so it reads as continuous rainfall rather than one wall.
function ConfettiController:FireConfettiRain(config: ConfettiConfig?)
	config = config or {}

	local images = config.Images or CONFETTI_IMAGES
	if #images == 0 then
		warn("ConfettiController:FireConfettiRain requires confetti images")
		return
	end

	local duration = config.Duration or RAIN_DURATION
	local rate = config.Rate or RAIN_RATE
	local perTick = config.PerTick or RAIN_PER_TICK
	local forceX = config.ForceX or RAIN_FORCE_X
	local forceY = config.ForceY or RAIN_FORCE_Y
	local gravity = config.Gravity or RAIN_GRAVITY
	local scale = config.Scale or 1
	local active = self._active

	task.spawn(function()
		local elapsed = 0

		while elapsed < duration do
			for _ = 1, perTick do
				local confetti = UIConfetti.new({
					Position = Vector2.new(RandomUtil.GetRandomFromMinMax(0, 1), -0.1),
					-- Negative Y force sends particles downward; gravity keeps accelerating them.
					Force = Vector2.new(
						RandomUtil.GetRandomFromMinMax(forceX.Min, forceX.Max),
						-RandomUtil.GetRandomFromMinMax(forceY.Min, forceY.Max)
					),
					Gravity = Vector2.new(0, gravity),
					Parent = self.UI,
					Images = images,
					Colors = config.Colors,
					Spin = config.Spin,
					Scale = scale,
					ScaleType = config.ScaleType,
				})

				confetti:Toggle()
				table.insert(active, confetti)
			end

			self:_ensureRunning()
			elapsed += task.wait(rate)
		end
	end)
end

function ConfettiController:OnInit()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ConfettiUI"
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 100
	screenGui.Parent = PlayerGui

	self.UI = screenGui
end

return ConfettiController
