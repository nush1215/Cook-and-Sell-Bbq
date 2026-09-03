-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

--
local UISparkles = Component.new({
	Tag = script.Name,
})

local DEFAULT_SPARKLE_MAX_SIZE = Vector2.new(0.3, 0.8)
local DEFAULT_SPARKLE_DURATION = 1
local DEFAULT_SPARKLE_IMAGE = "rbxassetid://14198353638"
local DEFAULT_SPARKLE_RATE = 2
local DEFAULT_SPARKLE_COLOR = Color3.fromRGB(253, 255, 149)

local SPARKLE_MIN_POSITION = 0.05
local SPARKLE_MAX_POSITION = 0.95
local SPARKLE_EDGE_BAND = 0.1
local SPARKLE_Y_SLOTS = 6
local SPARKLE_MIN_SCALE = 0.5
local SPARKLE_SHRINK_SCALE = 0
local SPARKLE_SPIN_SPEED = 100

local nextSparkleSeed = 0

-- Randomizes the row order so consecutive sparkles are less likely to overlap.
local function shuffleSlots(rng: Random, slots: { number })
	for i = #slots, 2, -1 do
		local j = rng:NextInteger(1, i)
		slots[i], slots[j] = slots[j], slots[i]
	end
end

-- Picks a scale position from one side band and one vertical row slot.
local function pickSparklePosition(rng: Random, onLeft: boolean, ySlot: number): Vector2
	local slotSize = (SPARKLE_MAX_POSITION - SPARKLE_MIN_POSITION) / SPARKLE_Y_SLOTS
	local slotStart = SPARKLE_MIN_POSITION + (ySlot - 1) * slotSize
	local y = rng:NextNumber(slotStart, slotStart + slotSize)
	local x = if onLeft
		then rng:NextNumber(SPARKLE_MIN_POSITION, SPARKLE_MIN_POSITION + SPARKLE_EDGE_BAND)
		else rng:NextNumber(SPARKLE_MAX_POSITION - SPARKLE_EDGE_BAND, SPARKLE_MAX_POSITION)

	return Vector2.new(x, y)
end

-- Grows then shrinks a sparkle until it is removed.
local function playSparkleEffect(sparkle: ImageLabel, uiScale: UIScale, peakScale: number, duration: number)
	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

	local growTween = TweenService:Create(uiScale, tweenInfo, { Scale = peakScale })
	growTween:Play()
	growTween.Completed:Wait()

	if sparkle.Parent then
		local shrinkTween = TweenService:Create(uiScale, tweenInfo, { Scale = SPARKLE_SHRINK_SCALE })
		shrinkTween:Play()
		shrinkTween.Completed:Wait()
	end
end

function UISparkles:Start()
	local ui = self.Instance

	-- Resolve the top-most frame (the GuiObject directly under the ScreenGui).
	local root = ui:FindFirstAncestorWhichIsA("ScreenGui")
	local rootFrame = root:FindFirstChildOfClass("Frame") or root:FindFirstChildOfClass("ImageLabel")
	if not rootFrame or rootFrame and not rootFrame.Name == "Holder" then
		--	warn("UISparkles: Start: No root frame found")
		return
	end

	--
	local sparkleMaxSize = ui:GetAttribute("SparkleMaxSize") or DEFAULT_SPARKLE_MAX_SIZE
	local sparkleDuration = ui:GetAttribute("SparkleDuration") or DEFAULT_SPARKLE_DURATION
	local sparkleImage = ui:GetAttribute("SparkleImage") or DEFAULT_SPARKLE_IMAGE
	local sparkleRate = ui:GetAttribute("SparkleRate") or DEFAULT_SPARKLE_RATE
	local sparkleColor = ui:GetAttribute("SparkleColor") or DEFAULT_SPARKLE_COLOR

	--
	self._cleaner = Trove.new()

	if sparkleRate <= 0 then
		return
	end

	nextSparkleSeed += 1
	local seed = nextSparkleSeed

	self._cleaner:Add(task.spawn(function()
		local rng = Random.new(seed)
		local onLeft = rng:NextInteger(1, 2) == 1
		local ySlots = table.create(SPARKLE_Y_SLOTS)
		local ySlotIndex = SPARKLE_Y_SLOTS + 1

		task.wait(rng:NextNumber(0, 1 / sparkleRate))

		while true do
			-- Pause spawning while the UI is hidden; resume once it is shown again.
			while not rootFrame.Visible do
				rootFrame:GetPropertyChangedSignal("Visible"):Wait()
			end

			if ySlotIndex > SPARKLE_Y_SLOTS then
				for i = 1, SPARKLE_Y_SLOTS do
					ySlots[i] = i
				end
				shuffleSlots(rng, ySlots)
				ySlotIndex = 1
			end

			local sparklePosition = pickSparklePosition(rng, onLeft, ySlots[ySlotIndex])
			local peakScale = rng:NextNumber(SPARKLE_MIN_SCALE, 1)
			onLeft = rng:NextInteger(1, 2) == 1
			ySlotIndex += 1

			local sparkle = Instance.new("ImageLabel")
			local uiScale = Instance.new("UIScale")
			local sparkleCleaner = Trove.new()

			uiScale.Scale = 0
			uiScale.Parent = sparkle

			sparkle.ImageColor3 = sparkleColor
			sparkle.BackgroundTransparency = 1
			sparkle.ImageTransparency = 0
			sparkle.Image = sparkleImage
			sparkle.ZIndex = 1000
			sparkle.ScaleType = Enum.ScaleType.Fit
			sparkle.AnchorPoint = Vector2.new(0.5, 0.5)
			sparkle.Size = UDim2.fromScale(sparkleMaxSize.X, sparkleMaxSize.Y)
			sparkle.Position = UDim2.fromScale(sparklePosition.X, sparklePosition.Y)

			sparkleCleaner:Add(sparkle)
			sparkle.Parent = ui

			sparkleCleaner:Add(RunService.Heartbeat:Connect(function(deltaTime)
				sparkle.Rotation = (sparkle.Rotation + SPARKLE_SPIN_SPEED * deltaTime) % 360
			end))

			self._cleaner:Add(sparkleCleaner)
			sparkleCleaner:Add(task.spawn(function()
				playSparkleEffect(sparkle, uiScale, peakScale, sparkleDuration)
				self._cleaner:Remove(sparkleCleaner)
			end))

			task.wait(1 / sparkleRate)
		end
	end))
end

function UISparkles:Stop()
	-- Nil for a UI Start bailed on (no root frame to gate on).
	if self._cleaner then
		self._cleaner:Destroy()
	end
end

return UISparkles
