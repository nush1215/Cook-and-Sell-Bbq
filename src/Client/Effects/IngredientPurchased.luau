-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local MathUtil = require(Shared.MathUtil)

--
local LocalPlayer = Players.LocalPlayer

-- How long the ingredient takes to arc into the player
local FLY_DURATION = 0.6

-- How far the bezier control point bows above the start/target midpoint (studs)
local ARC_HEIGHT = 8

-- How fast the ingredient spins on its way in (radians per second)
local SPIN_SPEED = 3

--
return function(ingredientModel: Model, targetPlayer: Player?)
	local player = targetPlayer or LocalPlayer
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	-- Without a target there's nothing to fly toward, so just clean up
	if not root then
		ingredientModel:Destroy()
		return
	end

	local startPos = ingredientModel:GetPivot().Position

	local elapsed = 0
	local spinCFrame = CFrame.identity

	local connection
	connection = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local alpha = math.clamp(elapsed / FLY_DURATION, 0, 1)

		-- Ease the arc so the ingredient accelerates into the player
		local t = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		-- Recompute the target/control each frame so the arc tracks a moving player
		local targetPos = root.Position
		local controlPos = (startPos + targetPos) / 2 + Vector3.new(0, ARC_HEIGHT, 0)
		local pos = MathUtil.QuadraticBezier(t, startPos, controlPos, targetPos)

		-- Shrink and spin as it flies in
		spinCFrame *= CFrame.Angles(0, SPIN_SPEED * dt, 0)
		ingredientModel:ScaleTo(MathUtil.Lerp(1, 0.3, t))
		ingredientModel:PivotTo(CFrame.new(pos) * spinCFrame)

		if alpha >= 1 then
			connection:Disconnect()
			ingredientModel:Destroy()
		end
	end)
end
