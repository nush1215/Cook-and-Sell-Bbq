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

-- On each roll the board pops out by swelling its scale and settling back (POP_SCALE tunes how hard),
-- while spinning SPIN_TURNS fast turns and decelerating to a straight stop (off a target spring).
local SPIN_TURNS = 1

-- Flip to Vector3.xAxis / Vector3.zAxis if the board spins around the wrong axis in game.
local BOARD_SPIN_AXIS = Vector3.yAxis

local INTRO_SCALE = 0.3
local CYCLE_SCALE = 0.8
local CYCLE_RISE = 0.5 -- studs below the landing that each cycled ingredient pops up from

-- The landed result bobs and spins in place. Update drives it off the live base each frame (rather
-- than the shared PartFloat component) so it follows its stand when a grid reflow slides it.
local RESULT_SPIN_SPEED = 0.5 -- radians/sec the result spins about Y
local RESULT_HOVER_AMPLITUDE = 0.1 -- studs the result bobs
local RESULT_HOVER_SPEED = 3 -- radians/sec the bob cycles
local RESULT_FLOAT_DELAY = 0.1 -- lets the landing spring settle before the float takes the pivot
local RESULT_HIGHLIGHT_DELAY = 0.7
local PROMPT_DISTANCE = 13

--[[
    One rolling stand, on every client, so a pull is something visitors can watch.

    The server stamps the result onto the model (RolledIngredient / RolledAt) and Sync renders off that,
    which is what gets the roll to everyone -- player data reaches only its owner. That one read covers a
    pull happening now, one that landed before we were watching, and a stand emptied by a purchase.

    Everything a roll spawns is owned by the stand, so the next roll wipes the last and a roll still
    cycling when the stand is taken back drops what it has rather than stranding it.
]]

--
local Stand = {}
Stand.__index = Stand

-- How far a model's pivot sits above the bottom of its geometry, so lifting by this seats it on a surface
-- wherever its pivot is authored. Measured at the current scale, so read it at the landing scale (1).
local function getSeatLift(model: Model): number
	local boxCFrame, boxSize = model:GetBoundingBox()
	local localCenter = model:GetPivot():Inverse() * boxCFrame.Position
	return boxSize.Y / 2 - localCenter.Y
end

-- A bank of stands steps in lockstep, and should read as one machine ticking over rather than one tick
-- each -- so the first stand to reach a step plays it and the rest ride along. Per base, since two
-- players rolling at once are two machines and neither should swallow the other's ticks.
local tickPlaying = {} -- [baseId] = true while this frame's tick has been played

-- One tick per base per frame, emitted from the base's own fixed point rather than whichever stand got
-- there first, so the roll doesn't pan somewhere new every pull while staying 3D.
local function playRollTick(baseId: string, emitter: BasePart)
	if tickPlaying[baseId] then
		return
	end

	tickPlaying[baseId] = true
	SoundController:PlaySound("NewShow", emitter)

	-- Deferred rather than timed: every stand resuming from its task.wait runs before deferred threads,
	-- so the flag is up for all of them and drops in time for the next step.
	task.defer(function()
		tickPlaying[baseId] = nil
	end)
end

-- The sting each base's bank has earned this frame and the point to play it from, held until the
-- flush below.
local pendingLanding = {} -- [baseId] = { IsCool: boolean, Emitter: BasePart }

-- One sting per bank, or a four-stand base would stack the same sound four deep. The rarest landing of
-- the frame is the one that plays -- a rare shouldn't be reduced to a common's chirp by a frame-mate.
local function playLandingSound(baseId: string, ingredient: Ingredients.Ingredient, emitter: BasePart)
	local isCool = ingredient.Tier.Index >= Ingredients.COOL_TIER_INDEX
	local banked = pendingLanding[baseId]

	-- A banked landing is upgraded by a cool one, never added to. Only the tier moves -- every stand of
	-- the bank stings from the same point.
	if banked then
		banked.IsCool = banked.IsCool or isCool
		return
	end

	pendingLanding[baseId] = { IsCool = isCool, Emitter = emitter }

	-- Deferred so the whole bank has landed before anything sounds. Playing on the first stand to arrive
	-- would leave the sting to thread order, stinging normal for a rare that lands a moment later.
	task.defer(function()
		local landing = pendingLanding[baseId]
		pendingLanding[baseId] = nil

		SoundController:PlaySound(if landing.IsCool then "ShowCool" else "ShowNormal", landing.Emitter)
	end)
end

function Stand.new(model: Model, owningBase: any)
	--
	local cleaner = Trove.new()

	-- Pop: an impulse spring, critically damped so the swell settles back with no dip below rest. Spin: a
	-- target spring pointed at a whole number of turns, so it whips round and eases to a straight stop.
	local popSpring = Spring.new(0)
	popSpring.Damper = 1
	popSpring.Speed = 16

	local spinSpring = Spring.new(0)
	spinSpring.Damper = 1
	spinSpring.Speed = 14

	local standBase: BasePart = model.Base
	local board: Model = model.Board

	--
	local self = setmetatable({
		--
		_model = model,
		_id = model.Name,
		_base = standBase,

		-- Owns the band this stand draws at, its lever, and whether the local player may buy off it.
		_owningBase = owningBase,
		_baseId = owningBase:GetId(),

		-- Bumped by anything that takes the stand back -- a wipe, a cull, the next roll -- so a cycle
		-- still yielding knows it's been cancelled and drops what it has.
		_rollToken = 0,

		-- The buy prompt, up only on the owner's own stands.
		_prompt = nil,

		_board = board,
		-- An offset from the base rather than a world pivot, so the board rides a slot slide. Recaptured
		-- at roll start, once the stand has settled at scale 1 (see PlayRoll).
		_boardRestOffset = standBase.CFrame:Inverse() * board:GetPivot(),
		_boardAnimating = false,

		--
		_popSpring = popSpring,
		_spinSpring = spinSpring,
		_currentModel = nil,
		_rolling = false,

		-- The active spring-driven roll model (intro or a cycle clone) and its spr params. Update
		-- re-points its pivot at the live landing, so it rides along if the stand slots slide.
		_rollingModel = nil,
		_rollingDamping = 0,
		_rollingFrequency = 0,

		-- Studs to raise the landing pivot so this model's base seats on the stand rather than its
		-- arbitrary authored pivot. Recomputed as each model is placed.
		_landingLift = 0,

		-- The landed result's own bob/spin, driven off the live base in Update so it follows reflows.
		_resultFloating = false,
		_resultFloatElapsed = 0,

		-- Holds the prompt cue back until the landing pulse has been and gone.
		_resultSettled = false,

		-- The RolledAt currently shown, so a sync telling us nothing new leaves a cycle alone. Dropped on
		-- a clear, so coming back into range re-reads.
		_shownRolledAt = nil,

		--
		_cleaner = cleaner,
		_rollCleaner = cleaner:Construct(Trove),
		_promptCleaner = cleaner:Construct(Trove),
	}, Stand)

	-- One handler for all three: they're written together and only mean anything together, so acting on
	-- a subset would pick the wrong animation.
	for _, attribute in { "RolledIngredient", "RolledAt", "RollSpeedLevel" } do
		cleaner:Connect(model:GetAttributeChangedSignal(attribute), function()
			self:Sync()
		end)
	end

	-- A stand can be built after the server stamped it (a rejoin, or walking into range), so read what's
	-- on it now rather than waiting for a change that already happened.
	self:Sync()

	return self
end

-- Where an ingredient rests: half the base's height, plus the landing gap and this ingredient's own seat
-- lift. Read fresh every frame, so a server-driven slot slide carries the roll along with it.
function Stand:_getLandingCFrame(): CFrame
	local height = self._base.Size.Y / 2 + RollingConfig.LANDING_GAP + self._landingLift
	return self._base.CFrame + Vector3.new(0, height, 0)
end

-- Per-frame driver for the board springs, the in-progress roll model and the landed result's bob. Each
-- re-derives from the stand's current pose, so a grid reflow carries them along rather than stranding them.
function Stand:Update(deltaTime: number)
	self:_updateBoard()
	self:_updateRollFollow()
	self:_updateResultFloat(deltaTime)
end

-- Keeps the active roll model springing toward the live landing. spr preserves the spring's motion and
-- only moves the goal, so the pop-in still plays while the model chases its stand across a reflow.
function Stand:_updateRollFollow()
	if not self._rollingModel then
		return
	end

	Spr.target(self._rollingModel, self._rollingDamping, self._rollingFrequency, { Pivot = self:_getLandingCFrame() })
end

-- Swells and spins the board off its springs, then settles it straight. Idle outside a roll, so it can't
-- pin the board to a stale pose while the stand is still rising into its slot.
function Stand:_updateBoard()
	if not self._boardAnimating then
		return
	end

	local popSpring = self._popSpring
	local spinSpring = self._spinSpring

	local popSettled = math.abs(popSpring.Position) < SETTLE_EPSILON and math.abs(popSpring.Velocity) < SETTLE_EPSILON
	local spinSettled = math.abs(spinSpring.Position - spinSpring.Target) < SETTLE_EPSILON
		and math.abs(spinSpring.Velocity) < SETTLE_EPSILON

	-- Rebuilt from the live base so the board tracks its stand across a reflow instead of holding the
	-- world pivot captured at roll start.
	local rest = self._base.CFrame * self._boardRestOffset

	-- Both settled: snap to the exact rest pose once and stop driving the board. The spin spring
	-- rests on whole turns, so the un-rotated rest pivot is where it ended up anyway.
	if popSettled and spinSettled then
		self._boardAnimating = false
		self._board:ScaleTo(1)
		self._board:PivotTo(rest)
		return
	end

	self._board:ScaleTo(1 + popSpring.Position)
	self._board:PivotTo(rest * CFrame.fromAxisAngle(BOARD_SPIN_AXIS, spinSpring.Position))
end

-- Bobs and spins the landed result off the live base, so it tracks a reflow rather than the roll-start
-- pose PartFloat would pin it to.
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

-- Cycles random ingredients before landing on the one the server rolled, then puts its billboard and
-- prompt up. Yields for the length of the animation.
-- @param speedLevel the owner's Unlocks.RollSpeed, read off the stand's attribute rather than player
-- data -- a visitor can't read the owner's levels, and cycling at their own would land outside the
-- window the server gates the claim on. It squeezes the whole cycle rather than dropping steps.
function Stand:PlayRoll(ingredientId: string, speedLevel: number?)
	if self._rolling then
		return
	end

	local speedScale = RollingConfig.GetSpeedScale(speedLevel)

	-- Recaptured now: the layout may have slid this stand into its slot and scaled it to 1 since it was
	-- constructed, so the resting base->board relationship is only trustworthy here.
	self._boardRestOffset = self._base.CFrame:Inverse() * self._board:GetPivot()

	-- Claims the stand for this roll. The cycling model isn't on the roll cleaner until it lands, so
	-- without the token checks after each wait it'd be orphaned and the loop would clone over it.
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

	-- Swell the board, which along with the lever swing and the shake is what says the machine fired.
	-- It used to flash the stand as well, but that was a Highlight per stand held for the whole roll --
	-- six of Roblox's thirty-odd slots spent on one beat the pop already carries.
	self._popSpring:Impulse(RandomUtil.GetRandomFromMinMax(10, 15))

	-- Accumulated rather than set: the spring keeps its angle between rolls, so an absolute target would
	-- already be met after the first roll and the board would never spin again.
	self._spinSpring.Target += SPIN_TURNS * math.pi * 2
	self._boardAnimating = true

	-- Where a model goes to be blacked out. One container and one Highlight for every stand in the
	-- place, so the reveal can't be lost to a budget several bases rolling at once would blow.
	IngredientRollingController = IngredientRollingController or require(script.Parent)
	local silhouette = IngredientRollingController:GetSilhouetteContainer()

	local allIngredients = Ingredients.GetAllIngredients()

	-- One generator for the whole cycle: RandomUtil makes a fresh Random per call when not handed one,
	-- and the fillers below draw twenty-six times a roll on every stand of the bank.
	local rng = Random.new()

	-- Intro: an ingredient rises out of the stand and swells into place. Parented into the silhouette
	-- container, which blacks it out and -- being outside the stand entirely, as everything this class
	-- spawns is -- keeps the stand's entrance ScaleTo from blowing it up.
	local introModel = RandomUtil.GetRandomFromArray(allIngredients, nil, rng).Model:Clone()
	self._landingLift = getSeatLift(introModel)
	introModel:ScaleTo(INTRO_SCALE)
	introModel:PivotTo(self._base.CFrame)
	introModel.Parent = silhouette
	playRollTick(self._baseId, self._owningBase:GetSoundEmitter())

	Spr.target(introModel, 0.725, 2.2, { Pivot = self:_getLandingCFrame(), Scale = CYCLE_SCALE })
	self._rollingModel, self._rollingDamping, self._rollingFrequency = introModel, 0.725, 2.2

	task.wait(RollingConfig.INTRO_DURATION * speedScale)

	-- Stopped before destroying: spr keeps stepping a destroyed instance until its spring sleeps, and a
	-- Pivot spring on some rotations never does.
	Spr.stop(introModel)
	introModel:Destroy()

	-- Taken back while we were waiting, so there's nothing left to cycle onto.
	if self._rollToken ~= token then
		return
	end

	self._rollingModel = nil

	-- Swap in a random ingredient each step, waiting longer each time so it decelerates onto the real one.
	-- Every wait is squeezed by the speed level, so the cycle lands on GetRollDuration(speedLevel) --
	-- the window the server gates the claim on.
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

		-- The final model is the one meant to be read, so it lands beside the stand rather than in the
		-- silhouette container. Where it's parented *is* the reveal -- nothing else has to be undone,
		-- which is what keeps a cancelled roll from stranding the black on a model that's been dropped.
		model.Parent = if isFinalStep then self._model.Parent else silhouette

		-- The final step gets its own sting, so it doesn't tick as well -- both on one frame would mush.
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

		-- Taken back mid-cycle. Only this step's model is ours to drop: whatever took the stand owns the
		-- follow now, so resetting that would reach into a new roll. The black leaves with the model.
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
	-- After the model so it runs first (Trove cleans in reverse add order), stopping the landing springs
	-- before the model is destroyed or handed to the fly-in.
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

-- Puts an already-rolled ingredient straight onto the stand, skipping the cycle -- everything past the
-- landing in PlayRoll and nothing before it. A roll is held until bought, so one from a finished session
-- just has to be sitting there buyable.
function Stand:ShowResult(ingredientId: string)
	-- A roll cycling towards its own result owns the stand; so does a result already sitting on it.
	if self._rolling or self._currentModel then
		return
	end

	-- Data outlives the config, so it can name an ingredient that's since been removed.
	local ingredient = Ingredients.GetIngredientFromId(ingredientId)
	if not ingredient then
		return
	end

	self._rollCleaner:Clean()

	-- Read the seat lift off the fresh clone, while it's still at the scale it lands at.
	local model = ingredient.Model:Clone()
	self._landingLift = getSeatLift(model)
	model:PivotTo(self:_getLandingCFrame())

	-- Sibling of the stand, as above, and this path needs it most: a restore lands mid-entrance-ScaleTo,
	-- so parenting under the stand left it 1/LAYOUT_ENTRANCE_SCALE too big -- with no spring to undo it.
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

-- Puts the buy prompt and its cue on the landed result, on the local player's own base only -- the
-- billboard above stays up for everyone. Re-runnable, so gaining or losing the base moves the prompt
-- without rebuilding the result, which covers BaseId landing after the stands were already there.
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

	-- Held until the landing settles: the landing pulse and this cue are both Highlights on one model,
	-- and the nearest-Highlight rule would render whichever it liked.
	if self._resultSettled then
		model:AddTag("PromptSubjectHighlight")
	end
end

-- Reads what the server says is on this stand and puts it there -- the one path every client takes. A
-- recent stamp is a pull still in the air, so it cycles; an older one is simply seated; an empty stamp
-- means it's been bought.
function Stand:Sync()
	-- Nothing is drawn on a base too far off to make out.
	if not self._owningBase:IsRendered() then
		return
	end

	local ingredientId = self._model:GetAttribute("RolledIngredient")
	if not ingredientId then
		-- Only the owner buying empties a stamped stand, so that's who the ingredient flies to. A base
		-- whose owner has gone has its stands destroyed with it, so there's nothing left to fly.
		local owner = self._owningBase:GetOwner()
		if owner then
			self:Purchase(owner)
		else
			self:Clear()
		end

		return
	end

	local rolledAt = self._model:GetAttribute("RolledAt")

	-- Already showing this pull -- the second attribute landing, or a re-sync from something else.
	-- Rebuilding here would restart a cycle that's part way through.
	if self._shownRolledAt == rolledAt then
		return
	end

	-- Whatever is up belongs to the previous pull; Clear releases a cycle still running for it, and drops
	-- _shownRolledAt so walking back into range re-reads the stand.
	self:Clear()
	self._shownRolledAt = rolledAt

	-- Cycle only for a pull still in the air: a cycle always takes the full roll duration, so one started
	-- late would land after the pull it belongs to, possibly on something already bought.
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

-- Strips the landed ingredient down and hands it to the purchase fly-in, which arcs it into whoever
-- bought it -- the local player on their own stand, the base's owner when a visitor is watching. The
-- effect owns and destroys the model from there.
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

	-- Pop rather than Remove: the model has to outlive the cleaner so the fly-in can finish with it.
	self._rollCleaner:Pop(model)
	self._rollCleaner:Clean()

	-- The prompt is destroyed below, so drop our handle rather than pointing at one that's flown off.
	self._promptCleaner:Clean()
	self._prompt = nil

	model:RemoveTag("PromptSubjectHighlight")

	-- Off the model, which is where _showResult puts it -- under the PrimaryPart it was never found, and
	-- the billboard rode the fly-in all the way in.
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

-- Wipes what the last roll left, and releases a cycle still running for it -- the token bump is what
-- tells that cycle it's been taken over, so it drops its model rather than stranding it on the stand.
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
