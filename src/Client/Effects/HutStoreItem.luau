-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

-- Shared
local Shared = ReplicatedStorage.Shared
local MathUtil = require(Shared.MathUtil)
local StickIngredients = require(Shared.StickIngredients)
local Ingredients = require(Shared.Config.Ingredients)
local Sticks = require(Shared.Config.Sticks)

--
local FLY_DURATION = 0.7

-- How far the bezier control point bows above the start/target midpoint (studs)
local ARC_HEIGHT = 8

-- How fast the item spins on its way in (radians per second)
local SPIN_SPEED = 3

-- What it shrinks to by the time it lands, as a fraction of its carried size
local END_SCALE = 0.2

-- A store-all flies one per unit up to this, so a big stack reads as many going in without spawning them all
local MAX_FLYERS = 5
local LAUNCH_INTERVAL = 0.08

-- Matches HeldItem's carry height, so the flight starts where the item was shown above their head
local HOLD_BASE_HEIGHT = 2.7

-- Flies one copy of `template` from above the character into `targetPosition`, shrinking and fading as it goes.
local function launchFlyer(template: Model, root: BasePart, targetPosition: Vector3)
	-- The character can respawn or stream out between a store-all's launches
	if not root:IsDescendantOf(workspace) then
		return
	end

	local model = template:Clone()

	-- [part or decal] = its authored transparency, so the fade starts from how it looks and a hidden part stays hidden
	local fades = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			fades[descendant] = descendant.Transparency
		elseif descendant:IsA("Decal") then
			fades[descendant] = descendant.Transparency
		end
	end

	local startScale = model:GetScale()
	local startPosition = root.Position
		+ Vector3.new(0, HOLD_BASE_HEIGHT + StickIngredients.GetMaxExtent(model) / 2, 0)
	local controlPosition = (startPosition + targetPosition) / 2 + Vector3.new(0, ARC_HEIGHT, 0)

	model:PivotTo(CFrame.new(startPosition) * StickIngredients.GetPivotToCenter(model):Inverse())
	model.Parent = workspace.Effects

	local elapsed = 0
	local spin = CFrame.identity

	local connection
	connection = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local alpha = math.clamp(elapsed / FLY_DURATION, 0, 1)
		local t = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		spin *= CFrame.Angles(0, SPIN_SPEED * dt, 0)
		model:ScaleTo(startScale * MathUtil.Lerp(1, END_SCALE, t))

		-- Centre re-read after the scale, which pulls it in toward the pivot
		local position = MathUtil.QuadraticBezier(t, startPosition, controlPosition, targetPosition)
		model:PivotTo(CFrame.new(position) * spin * StickIngredients.GetPivotToCenter(model):Inverse())

		for instance, baseTransparency in fades do
			instance.Transparency = MathUtil.Lerp(baseTransparency, 1, t)
		end

		if alpha >= 1 then
			connection:Disconnect()
			model:Destroy()
		end
	end)
end

-- Flies a stored item off `player` and into the hut at `targetPosition`, one flyer per unit up to a few.
return function(targetPosition: Vector3, player: Player, kind: string, id: string, amount: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	-- A far-off player's character can be streamed out, leaving nothing to fly from
	if not root then
		return
	end

	-- An id can outlive its config entry in old data
	local item = if kind == "Ingredients" then Ingredients.GetIngredientFromId(id) else Sticks.GetStickFromId(id)
	if not item then
		return
	end

	for index = 1, math.min(amount, MAX_FLYERS) do
		task.delay((index - 1) * LAUNCH_INTERVAL, launchFlyer, item.Model, root, targetPosition)
	end
end
