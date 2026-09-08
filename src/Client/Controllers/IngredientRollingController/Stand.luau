-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spring = require(Packages.Spring)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local RandomUtil = require(Shared.RandomUtil)
local GuiUtil = require(Shared.GuiUtil)
local Ingredients = require(Shared.Config.Ingredients)
local Rarity = require(Shared.Config.Rarity)
local RollingConfig = require(Shared.Config.Rolling)

-- Controllers
local EffectController = require(script.Parent.Parent.EffectController)
local SoundController = require(script.Parent.Parent.SoundController)

-- Assets
local Assets = ReplicatedStorage.Assets
local UI = Assets.UI

-- Required lazily to break the cycle: IngredientRollingController requires this class.
local IngredientRollingController

-- The board springs rest at ~0; once their position and velocity are both under this we stop animating
local SETTLE_EPSILON = 1e-3

-- The board swells and settles (POP_SCALE) while spinning SPIN_TURNS down to a straight stop
local SPIN_TURNS = 1

-- Flip to Vector3.xAxis / Vector3.zAxis if the board spins around the wrong axis in game.
local BOARD_SPIN_AXIS = Vector3.yAxis

local INTRO_SCALE = 0.3
local CYCLE_SCALE = 0.8
local CYCLE_RISE = 0.5 -- studs below the landing that each cycled ingredient pops up from

-- Driven off the live base each frame rather than PartFloat, so it follows a grid reflow
local RESULT_SPIN_SPEED = 0.5 -- radians/sec the result spins about Y
local RESULT_HOVER_AMPLITUDE = 0.1 -- studs the result bobs
local RESULT_HOVER_SPEED = 3 -- radians/sec the bob cycles
local RESULT_FLOAT_DELAY = 0.1 -- lets the landing spring settle before the float takes the pivot
local RESULT_HIGHLIGHT_DELAY = 0.7
local PROMPT_DISTANCE = 13

-- One rolling stand on a base: cycles ingredients off the server's stamp, lands on the result, and hands it to the buy prompt.

--
local Stand = {}
Stand.__index = Stand

-- Lift that seats a model on a surface whatever its authored pivot. Read at the landing scale (1).
local function getSeatLift(model: Model): number
	local boxCFrame, boxSize = model:GetBoundingBox()
	local localCenter = model:GetPivot():Inverse() * boxCFrame.Position
	return boxSize.Y / 2 - localCenter.Y
end

-- A bank should tick as one machine, so the first stand to reach a step plays it. Per base
local tickPlaying = {} -- [baseId] = true while this frame's tick has been played

-- From the base's fixed point, so the roll stays 3D without panning somewhere new every pull
local function playRollTick(baseId: string, emitter: BasePart)
	if tickPlaying[baseId] then
		return
	end

	tickPlaying[baseId] = true
	SoundController:PlaySound("NewShow", emitter)

	-- Deferred, so every stand's task.wait has resumed before the flag drops for the next step
	task.defer(function()
		tickPlaying[baseId] = nil
	end)
end

-- The sting each bank has earned this frame and where to play it from, held until the flush below
local pendingLanding = {} -- [baseId] = { IsCool: boolean, Emitter: BasePart }

-- One sting per bank; the rarest landing wins, so a frame-mate can't reduce a rare to a chirp
local function playLandingSound(baseId: string, ingredient: Ingredients.Ingredient, emitter: BasePart)
	local isCool = ingredient.Tier.Index >= Ingredients.COOL_TIER_INDEX
	local banked = pendingLanding[baseId]

	-- Upgraded, never added to -- only the tier moves, since the bank stings from one point
	if banked then
		banked.IsCool = banked.IsCool or isCool
		return
	end

	pendingLanding[baseId] = { IsCool = isCool, Emitter = emitter }

	-- Deferred so the whole bank has landed; on the first arrival it would sting on thread order
	task.defer(function()
		local landing = pendingLanding[baseId]
		pendingLanding[baseId] = nil

		SoundController:PlaySound(if landing.IsCool then "ShowCool" else "ShowNormal", landing.Emitter)
	end)
end

function Stand.new(model: Model, owningBase: any)
	local cleaner = Trove.new()

	-- Pop is an impulse spring; spin is a target spring on whole turns, so it eases to a straight stop
	local popSpring = Spring.new(0)
	popSpring.Damper = 1
	popSpring.Speed = 16

	local spinSpring = Spring.new(0)
	spinSpring.Damper = 1
	spinSpring.Speed = 14

	local standBase: BasePart = model.Base
	local board: Model = model.Board

	local self = setmetatable({
		_model = model,
		_id = model.Name,
		_base = standBase,

		-- Owns the band this stand draws at, its lever, and whether the local player may buy off it.
		_owningBase = owningBase,
		_baseId = owningBase:GetId(),

		-- Bumped by anything taking the stand back, so a yielding cycle knows it's been cancelled
		_rollToken = 0,

		-- The buy prompt, up only on the owner's own stands.
		_prompt = nil,

		_board = board,
		-- An offset from the base, so the board rides a slot slide. Recaptured at roll start (see PlayRoll)
		_boardRestOffset = standBase.CFrame:Inverse() * board:GetPivot(),
		_boardAnimating = false,

		_popSpring = popSpring,
		_spinSpring = spinSpring,
		_currentModel = nil,
		_rolling = false,

		-- The active roll model and its spr params; Update re-points it so it rides a slot slide
		_rollingModel = nil,
		_rollingDamping = 0,
		_rollingFrequency = 0,

		-- Studs to seat this model's base on the stand rather than its authored pivot. Recomputed per model
		_landingLift = 0,

		-- The landed result's own bob/spin, driven off the live base in Update so it follows reflows.
		_resultFloating = false,
		_resultFloatElapsed = 0,

		-- Holds the prompt cue back until the landing pulse has been and gone.
		_resultSettled = false,

		-- The RolledAt shown, so a sync with nothing new leaves a cycle alone. Dropped on a clear
		_shownRolledAt = nil,

		_cleaner = cleaner,
		_rollCleaner = cleaner:Construct(Trove),
		_promptCleaner = cleaner:Construct(Trove),
	}, Stand)

	-- One handler for all three -- written together, so acting on a subset picks the wrong animation
	for _, attribute in { "RolledIngredient", "RolledAt", "RollSpeedLevel" } do
		cleaner:Connect(model:GetAttributeChangedSignal(attribute), function()
			self:Sync()
		end)
	end

	-- A stand can be built after the stamp, so read what's on it now rather than await a change
	self:Sync()

	return self
end

-- Where an ingredient rests. Read fresh each frame, so a slot slide carries the roll with it.
function Stand:_getLandingCFrame(): CFrame
	local height = self._base.Size.Y / 2 + RollingConfig.LANDING_GAP + self._landingLift
	return self._base.CFrame + Vector3.new(0, height, 0)
end

-- Per-frame driver for the board springs, roll model and result bob, all re-derived from the live pose.
function Stand:Update(deltaTime: number)
	self:_updateBoard()
	self:_updateRollFollow()
	self:_updateResultFloat(deltaTime)
end

-- Keeps the roll model springing at the live landing; spr moves only the goal, so the pop-in still plays.
function Stand:_updateRollFollow()
	if not self._rollingModel then
		return
	end

	Spr.target(self._rollingModel, self._rollingDamping, self._rollingFrequency, { Pivot = self:_getLandingCFrame() })
end

-- Swells and spins the board, then settles it straight. Idle outside a roll, so it can't pin a stale pose.
function Stand:_updateBoard()
	if not self._boardAnimating then
		return
	end

	local popSpring = self._popSpring
	local spinSpring = self._spinSpring

	local popSettled = math.abs(popSpring.Position) < SETTLE_EPSILON and math.abs(popSpring.Velocity) < SETTLE_EPSILON
	local spinSettled = math.abs(spinSpring.Position - spinSpring.Target) < SETTLE_EPSILON
		and math.abs(spinSpring.Velocity) < SETTLE_EPSILON

	-- Rebuilt from the live base, so the board tracks a reflow instead of the pivot captured at roll start
	local rest = self._base.CFrame * self._boardRestOffset

	-- Snapped once and left; the spin spring rests on whole turns, so un-rotated is where it ended up
	if popSettled and spinSettled then
		self._boardAnimating = false
		self._board:ScaleTo(1)
		self._board:PivotTo(rest)
		return
	end

	self._board:ScaleTo(1 + popSpring.Position)
	self._board:PivotTo(rest * CFrame.fromAxisAngle(BOARD_SPIN_AXIS, spinSpring.Position))
end

-- Bobs and spins the result off the live base, so it tracks a reflow rather than the roll-start pose.
function Stand:_updateResultFloat(deltaTime: number)
	if not self._resultFloating or not self._currentModel then
		return
	end

	self._resultFloatElapsed += deltaTime

	local landing = self:_getLandingCFrame()
	local hover = CFrame.new(0, math.sin(self._resultFloatElapsed * RESULT_HOVER_SPEED) * RESULT_HOVER_AMPLITUDE, 0)
	local spin = CFrame.fromAxisAngle(Vector3.yAxis, self._resultFloatElapsed * RESULT_SPIN_SPEED)

	self._currentModel:PivotTo(landing * hover * spin)
end

-- Cycles to the server's result, then raises its billboard and prompt. speedLevel squeezes the whole cycle rather than dropping steps.
function Stand:PlayRoll(ingredientId: string, speedLevel: number?)
	if self._rolling then
		return
	end

	local speedScale = RollingConfig.GetSpeedScale(speedLevel)

	-- Recaptured now, since the layout may have slid and rescaled the stand since it was constructed
	self._boardRestOffset = self._base.CFrame:Inverse() * self._board:GetPivot()

	-- Claims the stand: the cycling model joins the cleaner only on landing, so the token checks free it
	self._rollToken += 1
	local token = self._rollToken

	self._rolling = true
	self._rollCleaner:Clean()
	self._promptCleaner:Clean()
	self._prompt = nil
	self._currentModel = nil
	self._rollingModel = nil
	self._resultFloating = false
	self._resultSettled = false

	-- The pop, lever and shake are what say the machine fired; a per-stand Highlight cost too many slots
	self._popSpring:Impulse(RandomUtil.GetRandomFromMinMax(10, 15))

	-- Accumulated, since the spring keeps its angle -- an absolute target would already be met
	self._spinSpring.Target += SPIN_TURNS * math.pi * 2
	self._boardAnimating = true

	-- One container and Highlight for every stand in the place, so several bases rolling can't blow the budget
	IngredientRollingController = IngredientRollingController or require(script.Parent)
	local silhouette = IngredientRollingController:GetSilhouetteContainer()

	local allIngredients = Ingredients.GetAllIngredients()

	-- One generator for the cycle -- the fillers draw twenty-six times a roll on every stand of the bank
	local rng = Random.new()

	-- Parented into the silhouette container, which blacks it out and escapes the stand's entrance ScaleTo
	local introModel = RandomUtil.GetRandomFromArray(allIngredients, nil, rng).Model:Clone()
	self._landingLift = getSeatLift(introModel)
	introModel:ScaleTo(INTRO_SCALE)
	introModel:PivotTo(self._base.CFrame)
	introModel.Parent = silhouette
	playRollTick(self._baseId, self._owningBase:GetSoundEmitter())

	Spr.target(introModel, 0.725, 2.2, { Pivot = self:_getLandingCFrame(), Scale = CYCLE_SCALE })
	self._rollingModel, self._rollingDamping, self._rollingFrequency = introModel, 0.725, 2.2

	task.wait(RollingConfig.INTRO_DURATION * speedScale)

	-- Stopped first -- spr keeps stepping a destroyed instance until its spring sleeps, which some never do
	Spr.stop(introModel)
	introModel:Destroy()

	-- Taken back while we were waiting, so there's nothing left to cycle onto.
	if self._rollToken ~= token then
		return
	end

	self._rollingModel = nil

	-- Waits lengthen so it decelerates onto the real one, squeezed to land on GetRollDuration(speedLevel)
	local waitTime = RollingConfig.CYCLE_INITIAL_WAIT * speedScale
	local currentModel

	for step = RollingConfig.CYCLE_STEPS, 1, -1 do
		local isFinalStep = step == 1
		local ingredient = if isFinalStep
			then Ingredients.GetIngredientFromId(ingredientId)
			else RandomUtil.GetRandomFromArray(allIngredients, nil, rng)

		local model = ingredient.Model:Clone()
		self._landingLift = getSeatLift(model)
		model:ScaleTo(CYCLE_SCALE)
		model:PivotTo(self:_getLandingCFrame() * CFrame.new(0, -CYCLE_RISE, 0))

		-- Where it's parented is the reveal, so a cancelled roll can't strand the black on a dropped model
		model.Parent = if isFinalStep then self._model.Parent else silhouette

		-- The final step gets its own sting rather than a tick -- both on one frame would mush
		if isFinalStep then
			playLandingSound(self._baseId, ingredient, self._owningBase:GetSoundEmitter())
		else
			playRollTick(self._baseId, self._owningBase:GetSoundEmitter())
		end

		if currentModel then
			Spr.stop(currentModel)
			currentModel:Destroy()
		end
		currentModel = model

		Spr.target(model, 0.5, 3, { Scale = 1, Pivot = self:_getLandingCFrame() })
		self._rollingModel, self._rollingDamping, self._rollingFrequency = model, 0.5, 3

		if isFinalStep then
			EffectController:RunEffect("HighlightPulse", { model, Color3.fromRGB(255, 255, 255), 1, 0 })
			break
		end

		task.wait(waitTime)

		-- Only this step's model is ours -- whatever took the stand owns the follow now
		if self._rollToken ~= token then
			Spr.stop(currentModel)
			currentModel:Destroy()
			return
		end

		waitTime = math.min(
			waitTime + RollingConfig.CYCLE_WAIT_INCREMENT * speedScale,
			RollingConfig.CYCLE_MAX_WAIT * speedScale
		)
	end

	self._currentModel = currentModel
	self._rollCleaner:Add(currentModel)
	-- After the model so it cleans first, stopping the springs before the model is destroyed or handed on
	self._rollCleaner:Add(function()
		Spr.stop(currentModel)
	end)
	self._rolling = false

	-- Let the landing spring settle, then hand the pivot from spr to Update's result float.
	self._rollCleaner:Add(task.delay(RESULT_FLOAT_DELAY, function()
		Spr.stop(currentModel, "Pivot")
		self._rollingModel = nil
		self._resultFloatElapsed = 0
		self._resultFloating = true

		task.wait(RESULT_HIGHLIGHT_DELAY)
		self._resultSettled = true
		self:RefreshInteraction()
	end))

	self:_showResult(Ingredients.GetIngredientFromId(ingredientId), currentModel)
end

-- Seats an already-rolled ingredient with no cycle -- a held roll from a finished session just has to be there.
function Stand:ShowResult(ingredientId: string)
	-- A roll cycling towards its own result owns the stand; so does a result already sitting on it
	if self._rolling or self._currentModel then
		return
	end

	-- Data outlives the config, so it can name an ingredient that's since been removed
	local ingredient = Ingredients.GetIngredientFromId(ingredientId)
	if not ingredient then
		return
	end

	self._rollCleaner:Clean()

	-- Read the seat lift off the fresh clone, while it's still at the scale it lands at.
	local model = ingredient.Model:Clone()
	self._landingLift = getSeatLift(model)
	model:PivotTo(self:_getLandingCFrame())

	-- This path needs it most: a restore lands mid-entrance-ScaleTo, with no spring to undo the scale
	model.Parent = self._model.Parent

	self._currentModel = model
	self._rollCleaner:Add(model)

	-- Straight into the float: no landing spring to settle, and nothing for the prompt cue to talk over.
	self._resultFloatElapsed = 0
	self._resultFloating = true
	self._resultSettled = true

	self:_showResult(ingredient, model)
end

-- Puts the ingredient's billboard and purchase prompt on the landed model.
function Stand:_showResult(ingredient: Ingredients.Ingredient, model: Model)
	local info = UI.IngredientInfo:Clone()
	local billboard = info.UI

	local tier = ingredient.Tier

	billboard.IngredientName.Text = ingredient.Name
	billboard.Rarity.Text = Rarity.FormatChance(ingredient.Chance)
	billboard.Price.Text = `${GuiUtil.ConvertNumberWithSuffix(ingredient.Price)}`

	billboard.Rarity.TextColor3 = tier.TextColor

	local stroke = billboard.Rarity:FindFirstChildWhichIsA("UIStroke")
	if stroke then
		stroke.Color = tier.StrokeColor
	end

	info.CFrame = CFrame.new(0, model:GetExtentsSize().Y / 2, 0)
	info.Parent = model

	self:RefreshInteraction()
end

-- Puts the buy prompt on the result, owner only. Re-runnable, so a late BaseId still moves it.
function Stand:RefreshInteraction()
	local model = self._currentModel
	local owned = model ~= nil and self._owningBase:IsOwned()

	if not owned then
		self._promptCleaner:Clean()
		self._prompt = nil

		if model then
			model:RemoveTag("PromptSubjectHighlight")
		end

		return
	end

	if not self._prompt then
		local prompt = Instance.new("ProximityPrompt")
		prompt.RequiresLineOfSight = false
		prompt.HoldDuration = 0.4
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.MaxActivationDistance = PROMPT_DISTANCE
		prompt.ActionText = "Buy"
		prompt.Parent = model.PrimaryPart

		self._prompt = prompt
		self._promptCleaner:Add(prompt)
		self._promptCleaner:Connect(prompt.Triggered, function()
			IngredientRollingController = IngredientRollingController or require(script.Parent)
			IngredientRollingController:RequestPurchase(self._id, self._model:GetAttribute("RolledIngredient"))
		end)
	end

	-- Held until the landing settles -- two Highlights on one model render in no defined order
	if self._resultSettled then
		model:AddTag("PromptSubjectHighlight")
	end
end

-- Draws whatever the server says is on the stand: a recent stamp cycles, an older one seats, an empty one clears.
function Stand:Sync()
	-- Nothing is drawn on a base too far off to make out.
	if not self._owningBase:IsRendered() then
		return
	end

	local ingredientId = self._model:GetAttribute("RolledIngredient")
	if not ingredientId then
		-- Only the owner buying empties a stamped stand; a base whose owner left has no stands to fly from
		local owner = self._owningBase:GetOwner()
		if owner then
			self:Purchase(owner)
		else
			self:Clear()
		end

		return
	end

	local rolledAt = self._model:GetAttribute("RolledAt")

	-- Already showing this pull, and rebuilding would restart a cycle part way through
	if self._shownRolledAt == rolledAt then
		return
	end

	-- Clear releases the previous pull's cycle and drops _shownRolledAt, so walking back re-reads
	self:Clear()
	self._shownRolledAt = rolledAt

	-- Only for a pull still in the air -- a late cycle would land after its pull, maybe on something bought
	local isFresh = (workspace:GetServerTimeNow() - rolledAt) < RollingConfig.ROLL_ANIMATION_GRACE
	if not (isFresh and self._owningBase:IsAnimating()) then
		self:ShowResult(ingredientId)
		return
	end

	-- So the roll reads as something someone did rather than a bank of stands lighting up on their own.
	self._owningBase:SwingLeverForPull(rolledAt)

	task.spawn(function()
		local played, err = pcall(function()
			self:PlayRoll(ingredientId, self._model:GetAttribute("RollSpeedLevel"))
		end)

		-- A throw mid-roll would leave the stand flagged as rolling and deadlock the lever's wait.
		if not played then
			warn(err)
			self:Clear()
		end
	end)
end

-- Whether the stand is still cycling towards its result.
function Stand:IsRolling(): boolean
	return self._rolling
end

-- Hands the landed ingredient to the purchase fly-in, which owns and destroys the model from there.
function Stand:Purchase(targetPlayer: Player?)
	local model = self._currentModel
	if not model then
		return
	end

	self._currentModel = nil
	self._rollingModel = nil
	self._resultFloating = false
	self._resultSettled = false
	self._shownRolledAt = nil

	-- Popped, not removed -- the model has to outlive the cleaner for the fly-in to finish with it
	self._rollCleaner:Pop(model)
	self._rollCleaner:Clean()

	-- The prompt is destroyed below, so drop our handle rather than pointing at one that's flown off.
	self._promptCleaner:Clean()
	self._prompt = nil

	model:RemoveTag("PromptSubjectHighlight")

	-- Off the model, where _showResult puts it -- under the PrimaryPart it rode the fly-in all the way in
	local info = model:FindFirstChild("IngredientInfo")
	if info then
		info:Destroy()
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ProximityPrompt") or descendant:IsA("Highlight") then
			descendant:Destroy()
		end
	end

	EffectController:RunEffect("IngredientPurchased", { model, targetPlayer })
end

-- Wipes the last roll and bumps the token, which is what tells a running cycle it's been taken over.
function Stand:Clear()
	self._rollToken += 1

	self._rollCleaner:Clean()
	self._promptCleaner:Clean()

	self._prompt = nil
	self._currentModel = nil
	self._rollingModel = nil
	self._rolling = false
	self._resultFloating = false
	self._resultSettled = false

	-- Dropped so walking back into range re-reads rather than deciding it's already showing what's on it.
	self._shownRolledAt = nil
end

function Stand:Destroy()
	self._cleaner:Destroy()
	self = nil
end

return Stand
