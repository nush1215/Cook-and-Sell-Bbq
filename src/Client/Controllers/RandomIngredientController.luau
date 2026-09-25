-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Spr = require(Packages.Spr)

-- Assets
local UI = ReplicatedStorage.Assets.UI

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local RandomUtil = require(Shared.RandomUtil)
local StickIngredients = require(Shared.StickIngredients)
local Ingredients = require(Shared.Config.Ingredients)
local RollingConfig = require(Shared.Config.Rolling)
local RandomIngredient = require(Shared.Config.RandomIngredient)

-- Controllers
local EffectController
local SoundController
local CameraController

-- Modules
local Modules = script.Parent.Parent.Modules
local MeteorFall = require(Modules.MeteorFall)
local RockModule = require(Modules.RockModule)

-- Local Player
local LocalPlayer = Players.LocalPlayer

-- Studs above the landing the debris is centred, since RockModule rays down from its centre to find the ground
local IMPACT_LIFT = 2

-- The white flash the result lands with, fading off to leave only its rarity outline. The stand's own flash, on this reveal's highlight
local REVEAL_FLASH = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Trails the result appearing, so the burst reads as coming off it rather than being it
local SHOW_LOOT_DELAY = 0.1

-- Plays the Random Ingredient reveal for every purchase in view: a silhouette crashes in front of the buyer, rolls the stand's way, then flies into them. Only the buyer's client claims.
local RandomIngredientController = {
	RevealEvent = Network.Event("RandomIngredientReveal"),
	ClaimEvent = Network.Event("ClaimRandomIngredient"),
}

-- Clones an ingredient inert at REVEAL_DISPLAY_SIZE, returning it with that scale and the offset that seats its centre on a pose.
local function cloneRevealModel(ingredient: Ingredients.Ingredient): (Model, number, CFrame)
	local model = ingredient.Model:Clone()

	-- One size for everything, so a grape and a rib rack read as equals. Measured before the scale, seated after
	local displayScale = model:GetScale() * (RandomIngredient.REVEAL_DISPLAY_SIZE / StickIngredients.GetMaxExtent(model))
	model:ScaleTo(displayScale)

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
		end
	end

	-- An ingredient's authored pivot can sit anywhere on it, so poses seat its bounding-box centre instead
	return model, displayScale, StickIngredients.GetPivotToCenter(model):Inverse()
end

-- Plays one purchase's reveal where the server landed it, starting on the server's clock so every client crashes together.
function RandomIngredientController:PlayRandomIngredientReveal(
	buyer: Player?,
	uid: string,
	ingredientId: string,
	landingCFrame: CFrame,
	startAt: number,
	isFirstOfDay: boolean
)
	-- A buyer who left before this arrived replicates as nil, and there's nobody left to fly it into
	if not buyer then
		return
	end

	local isBuyer = buyer == LocalPlayer

	-- Queued by the server behind their last one
	local untilStart = startAt - workspace:GetServerTimeNow()
	if untilStart > 0 then
		task.wait(untilStart)
	end

	-- Bystanders too far off to see it skip it; the buyer's always plays, since the claim hangs off its end
	if not isBuyer then
		local character = LocalPlayer.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		local distance = rootPart and (rootPart.Position - landingCFrame.Position).Magnitude

		if not distance or distance > RandomIngredient.REVEAL_VIEW_DISTANCE then
			return
		end
	end

	local ingredient = Ingredients.GetIngredientFromId(ingredientId)
	local hoverCFrame = landingCFrame * CFrame.new(0, RandomIngredient.REVEAL_HOVER_HEIGHT, 0)
	local speedScale = RandomIngredient.REVEAL_ROLL_DURATION / RollingConfig.AUTHORED_DURATION
	local rng = Random.new()

	-- Only what the pool can land flashes past, so every silhouette is something it could be
	local fillers = {}
	for _, entry in RandomIngredient.Pool do
		table.insert(fillers, Ingredients.GetIngredientFromId(entry.Id))
	end

	-- The discounted first buy of the day baits with its own mix, leaning on the Mythic
	local edgeTierWeights = if isFirstOfDay
		then RandomIngredient.REVEAL_EDGE_TIER_WEIGHTS_FIRST_OF_DAY
		else RandomIngredient.REVEAL_EDGE_TIER_WEIGHTS

	-- What the roll can edge onto before landing: pool entries at a bait tier, other than what they actually got
	local edgeByTier = {}
	for _, filler in fillers do
		local tierId = filler.Tier.Id
		if edgeTierWeights[tierId] and filler ~= ingredient then
			edgeByTier[tierId] = edgeByTier[tierId] or {}
			table.insert(edgeByTier[tierId], filler)
		end
	end

	-- A tier is drawn first, so one Mythic isn't drowned out by four Epics; a tier with nothing to show can't be drawn
	local edgeTiers = {}
	for tierId, candidates in edgeByTier do
		table.insert(edgeTiers, { candidates, edgeTierWeights[tierId] })
	end

	local edgeCandidates = RandomUtil.GetResultFromWeight(edgeTiers, rng)
	local edgeIngredient = edgeCandidates and RandomUtil.GetRandomFromArray(edgeCandidates, nil, rng)

	-- One per reveal rather than the stands' shared silhouette, since each shown ingredient outlines in its own rarity
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.new(0, 0, 0)
	highlight.FillTransparency = 0
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded

	-- Hands the highlight to `model`, outlined in its rarity. Parented rather than adorned, so it leaves with the model
	local function highlightShown(model: Model, shown: Ingredients.Ingredient)
		highlight.OutlineColor = shown.Tier.TextColor
		highlight.Parent = model
	end

	-- The roll's billboard hangs off its own anchor over a full-size result, never the models, so it stays put while they pop and grow
	local labelAnchor = Instance.new("Part")
	labelAnchor.Anchored = true
	labelAnchor.CanCollide = false
	labelAnchor.CanQuery = false
	labelAnchor.CanTouch = false
	labelAnchor.CastShadow = false
	labelAnchor.Transparency = 1
	labelAnchor.Size = Vector3.one
	labelAnchor.CFrame = hoverCFrame * CFrame.new(0, RandomIngredient.REVEAL_DISPLAY_SIZE / 2, 0)

	-- Just the BillboardGui, which renders at whatever part it's under, so its authored size is never touched
	local billboard = UI.RollingIngredientInfo.UI:Clone()
	local rarityStroke = billboard.Rarity:FindFirstChildWhichIsA("UIStroke")
	billboard.Parent = labelAnchor

	-- The whole reveal starts at this and only the roll grows it, so the crash lands small too
	local startScale = RandomIngredient.REVEAL_ROLL_START_SCALE

	-- The crash. The landing faces the buyer, so its back is away from them and its left is their right
	local meteorIngredient = RandomUtil.GetRandomFromArray(fillers, nil, rng)
	local meteor, meteorScale, meteorSeat = cloneRevealModel(meteorIngredient)

	-- The seat offset was measured at full size, so it's shrunk with the model or it lands off-centre
	meteor:ScaleTo(meteorScale * startScale)
	meteorSeat = meteorSeat.Rotation + meteorSeat.Position * startScale

	local groundedCFrame = landingCFrame * CFrame.new(0, meteor:GetExtentsSize().Y / 2, 0) * meteorSeat
	highlightShown(meteor, meteorIngredient)
	meteor.Parent = workspace

	local cancelFall = MeteorFall.Play(meteor, {
		Duration = RandomIngredient.REVEAL_FALL_DURATION,
		LandingCFrame = groundedCFrame,
		EntryOffset = -landingCFrame.LookVector * RandomIngredient.REVEAL_ENTRY_BACK
			- landingCFrame.RightVector * RandomIngredient.REVEAL_ENTRY_SIDE
			+ Vector3.new(0, RandomIngredient.REVEAL_ENTRY_HEIGHT, 0),
	})

	task.wait(RandomIngredient.REVEAL_FALL_DURATION)

	-- Pinned here rather than off OnLanded, which a frame's rounding can put after this resumes
	cancelFall()
	meteor:PivotTo(groundedCFrame)

	-- Their own base's invisible parts are passed over, or the debris copies their invisibility off the ground rays
	local baseId = buyer:GetAttribute("BaseId")
	local baseModel = baseId and workspace.Base:FindFirstChild(baseId)
	if baseModel then
		RockModule.IgnoreInvisibleParts(baseModel)
	end

	local impactCFrame = CFrame.new(landingCFrame.Position + Vector3.new(0, IMPACT_LIFT, 0))
	RockModule.Explosion(
		impactCFrame,
		RandomIngredient.REVEAL_EXPLOSION_ROCKS,
		RandomIngredient.REVEAL_EXPLOSION_MIN_SIZE,
		RandomIngredient.REVEAL_EXPLOSION_MAX_SIZE,
		false
	)
	RockModule.Crater(
		impactCFrame,
		RandomIngredient.REVEAL_CRATER_RADIUS,
		RandomIngredient.REVEAL_CRATER_MIN_ROCKS,
		RandomIngredient.REVEAL_CRATER_MAX_ROCKS,
		false
	)

	SoundController:PlaySound("CrateCrash", landingCFrame)

	if isBuyer then
		local shake = RandomIngredient.REVEAL_SHAKE
		CameraController:ShakeCustom(shake.Magnitude, shake.Roughness, shake.FadeIn, shake.FadeOut)
	end

	task.wait(RandomIngredient.REVEAL_IMPACT_PAUSE)

	-- The landed silhouette lifts into place as the roll's intro, the way a stand's first model springs up off it
	SoundController:PlaySound("NewShow", hoverCFrame)
	Spr.target(meteor, 0.725, 2.2, { Pivot = hoverCFrame * meteorSeat })

	task.wait(RollingConfig.INTRO_DURATION * speedScale)

	-- Spr stopped first, or it steps the destroyed model; the highlight's lifted off for the first step to take this same frame
	Spr.stop(meteor)
	highlight.Parent = nil
	meteor:Destroy()

	-- The stand's cycle: waits lengthen so it decelerates onto the real one, stretched to REVEAL_ROLL_DURATION
	local waitTime = RollingConfig.CYCLE_INITIAL_WAIT * speedScale
	local resultModel, resultScale, resultSeat

	-- Growth runs off time rather than steps, since the early steps fly by and would do all the growing in a blink
	local cycleDuration = (RollingConfig.AUTHORED_DURATION - RollingConfig.INTRO_DURATION) * speedScale
	local cycleElapsed = 0

	-- Up with the first step, which fills its text before this frame renders
	labelAnchor.Parent = workspace

	for step = RollingConfig.CYCLE_STEPS, 1, -1 do
		local isFinalStep = step == 1

		-- The last step before the result is the tease, so the roll looks to slow onto something good and slip past it
		local isEdgeStep = step == 2

		local stepIngredient = if isFinalStep
			then ingredient
			elseif isEdgeStep and edgeIngredient then edgeIngredient
			else RandomUtil.GetRandomFromArray(fillers, nil, rng)

		local model, displayScale, seatOffset = cloneRevealModel(stepIngredient)

		-- The seat offset was measured at full size, so it shrinks with the model or a small one hangs off-centre
		local growth = if isFinalStep then 1 else math.min(cycleElapsed / cycleDuration, 1)
		local stepFactor = startScale + (1 - startScale) * growth
		local stepScale = displayScale * stepFactor
		local stepSeat = seatOffset.Rotation + seatOffset.Position * stepFactor

		model:ScaleTo(stepScale * RollingConfig.CYCLE_SCALE)
		model:PivotTo(hoverCFrame * CFrame.new(0, -RollingConfig.CYCLE_RISE, 0) * stepSeat)

		-- Moved on before the last model is destroyed below, which would take the highlight down with it
		highlightShown(model, stepIngredient)
		model.Parent = workspace

		-- Every step's rarity shows, but the name stays ??? until the result
		billboard.IngredientName.Text = if isFinalStep then stepIngredient.Name else "???"
		billboard.Rarity.Text = stepIngredient.Tier.Id
		billboard.Rarity.TextColor3 = stepIngredient.Tier.TextColor

		if rarityStroke then
			rarityStroke.Color = stepIngredient.Tier.StrokeColor
		end

		-- The final step gets the reveal's own sting rather than a tick
		SoundController:PlaySound(if isFinalStep then "RandomReveal" else "NewShow", hoverCFrame)

		if resultModel then
			Spr.stop(resultModel)
			resultModel:Destroy()
		end

		resultModel, resultScale, resultSeat = model, stepScale, stepSeat
		Spr.target(model, 0.5, 3, { Scale = stepScale, Pivot = hoverCFrame * stepSeat })

		-- The reveal: the black fill flashes white and fades off, leaving the real one outlined in its rarity
		if isFinalStep then
			highlight.FillColor = Color3.new(1, 1, 1)
			TweenService:Create(highlight, REVEAL_FLASH, { FillTransparency = 1 }):Play()

			-- The result hovers a good while past this, so it's still there to burst off
			task.delay(SHOW_LOOT_DELAY, function()
				EffectController:RunEffect("RandomIngredientShowLoot", model)
			end)

			break
		end

		-- Held on the tease even with nothing good to show, since GetRevealDuration counts the hold either way
		task.wait(if isEdgeStep then waitTime + RandomIngredient.REVEAL_EDGE_HOLD else waitTime)

		-- The planned wait, not the edge hold, so the result still lands at full size on schedule
		cycleElapsed += waitTime

		waitTime = math.min(
			waitTime + RollingConfig.CYCLE_WAIT_INCREMENT * speedScale,
			RollingConfig.CYCLE_MAX_WAIT * speedScale
		)
	end

	-- Let the landing spring settle, then float it the way a stand's result floats while its name is up
	task.wait(RollingConfig.RESULT_FLOAT_DELAY)
	Spr.stop(resultModel, "Pivot")

	local elapsed = 0
	while elapsed < RandomIngredient.REVEAL_HOLD_DURATION - RollingConfig.RESULT_FLOAT_DELAY do
		elapsed += RunService.RenderStepped:Wait()

		local hover = CFrame.new(
			0,
			math.sin(elapsed * RollingConfig.RESULT_HOVER_SPEED) * RollingConfig.RESULT_HOVER_AMPLITUDE,
			0
		)
		local spin = CFrame.Angles(0, elapsed * RollingConfig.RESULT_SPIN_SPEED, 0)

		resultModel:PivotTo(hoverCFrame * hover * spin * resultSeat)
	end

	-- Handed to the fly-in at its display size, which the effect shrinks from and destroys on arrival
	Spr.stop(resultModel)
	resultModel:ScaleTo(resultScale)
	labelAnchor:Destroy()

	EffectController:RunEffect("IngredientPurchased", { resultModel, buyer })

	-- On take-off rather than arrival, so the tool reaches their hand about as the model does
	if isBuyer then
		self.ClaimEvent:FireServer(uid)
	end
end

function RandomIngredientController:OnInit()
	EffectController = require(script.Parent.EffectController)
	SoundController = require(script.Parent.SoundController)
	CameraController = require(script.Parent.CameraController)
end

function RandomIngredientController:OnStart()
	self.RevealEvent:OnClientEvent(
		function(
			buyer: Player?,
			uid: string,
			ingredientId: string,
			landingCFrame: CFrame,
			startAt: number,
			isFirstOfDay: boolean
		)
			self:PlayRandomIngredientReveal(buyer, uid, ingredientId, landingCFrame, startAt, isFirstOfDay)
		end
	)
end

return RandomIngredientController
