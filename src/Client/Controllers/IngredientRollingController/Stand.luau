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

-- The landing sting steps up from this tier on. Ingredients.Tiers is ordered commonest first, so the
-- cutoff is a position on that ladder rather than a list of ids -- a tier added above this one is
-- celebrated automatically, instead of quietly falling back to the plain sting because nobody
-- remembered to list it here.
local COOL_TIER_INDEX = table.find(Ingredients.Tiers, Ingredients.GetTierFromId("Rare")) :: number

--[[
    Class for a single rolling stand, on every client, so a pull is something visitors can watch.

    One instance per active stand under a base's Rolling.Stands folder. The server stamps what the
    stand rolled onto the model itself (RolledIngredient / RolledAt) and Sync renders off that, which
    is what gets the roll to everyone -- player data reaches only its owner. The same read covers a
    pull happening now (cycle to it), one that landed before we were watching (seat it), and a stand
    going empty on a purchase, so there's one path rather than one per case.

    The cycle steps through random ingredients, decelerating onto the result, then puts up its
    billboard -- which everyone sees, since what someone pulled and what it's worth is the part worth
    showing off. Only the buy prompt is the owner's. Everything a roll spawns is owned by the stand,
    so the next roll wipes the last one, and a roll still cycling when the stand is taken back drops
    what it has in the air rather than stranding it.
]]

--
local Stand = {}
Stand.__index = Stand

-- How far a model's pivot sits above the bottom of its geometry: lift the pivot by this to seat the
-- model's base on a surface, wherever its pivot happens to be authored. Measured at the model's
-- current scale, so read it while the model is at the scale it lands at (1). Mirrors the bounding-box
-- recentre in StickIngredients/IngredientManager, kept to the vertical axis.
local function getSeatLift(model: Model): number
	local boxCFrame, boxSize = model:GetBoundingBox()
	local localCenter = model:GetPivot():Inverse() * boxCFrame.Position
	return boxSize.Y / 2 - localCenter.Y
end

-- Every stand steps its cycle off the same waits, so a bank of them swaps ingredients on the same
-- frame -- and the roll should read as one machine ticking over, not one tick per stand. Shared
-- across instances deliberately: the first stand to reach a step plays it and the rest ride along.
-- Kept per base, since two players rolling at once are two machines and neither should swallow the
-- other's ticks.
local tickPlaying = {} -- [baseId] = true while this frame's tick has been played

-- Ticks for an ingredient appearing on a stand, once for however many of that base's stands are
-- cycling together. Emitted from the base's own fixed point rather than from whichever stand got there
-- first, so the roll doesn't pan somewhere new every pull -- it stays 3D, so a neighbour's pull still
-- rolls off from their base rather than sounding like it's on top of you.
local function playRollTick(baseId: string, emitter: BasePart)
	if tickPlaying[baseId] then
		return
	end

	tickPlaying[baseId] = true
	SoundController:PlaySound("NewShow", emitter)

	-- Deferred rather than timed: every stand resuming from its task.wait this frame runs before
	-- deferred threads do, so the flag is still up for all of them and drops in time for the next step.
	task.defer(function()
		tickPlaying[baseId] = nil
	end)
end

-- The sting each base's bank has earned this frame and the point to play it from, held until the
-- flush below.
local pendingLanding = {} -- [baseId] = { IsCool: boolean, Emitter: BasePart }

-- Stings the landed result, once for the bank however many stands land together -- they all land on
-- the same frame, so without this a four-stand base would stack the same sting four deep. The rarest
-- landing of the frame is the one that plays: a rare is what the pull is for, and it shouldn't be
-- reduced to a common's chirp because a neighbour landed one at the same moment.
local function playLandingSound(baseId: string, ingredient: Ingredients.Ingredient, emitter: BasePart)
	local isCool = (table.find(Ingredients.Tiers, ingredient.Tier) :: number) >= COOL_TIER_INDEX
	local banked = pendingLanding[baseId]

	-- A landing already banked for this frame is upgraded by a cool one, never added to. Only the tier
	-- moves -- every stand of the bank stings from the same point, so there's nothing to re-aim.
	if banked then
		banked.IsCool = banked.IsCool or isCool
		return
	end

	pendingLanding[baseId] = { IsCool = isCool, Emitter = emitter }

	-- Held rather than played on the spot, so the whole bank has landed before anything sounds: every
	-- stand resuming from its task.wait this frame runs before deferred threads do. Playing on the
	-- first stand to arrive would leave the sting to thread order -- a common landing a frame-mate
	-- ahead of a rare would sting normal, and the rare would then sting over the top of it.
	task.defer(function()
		local landing = pendingLanding[baseId]
		pendingLanding[baseId] = nil

		SoundController:PlaySound(if landing.IsCool then "ShowCool" else "ShowNormal", landing.Emitter)
	end)
end

function Stand.new(model: Model, owningBase: any)
	--
	local cleaner = Trove.new()

	-- One Highlight reused for the whole cycle rather than one made and thrown away per step. Roblox
	-- only renders about thirty at once, and with several nearby bases cycling six stands each the
	-- per-step churn would blow that budget -- which doesn't fail loudly, it just silently stops
	-- drawing outlines everywhere else in the game.
	local silhouette = Instance.new("Highlight")
	silhouette.OutlineTransparency = 1
	silhouette.FillTransparency = 0
	silhouette.FillColor = Color3.fromRGB(0, 0, 0)
	silhouette.DepthMode = Enum.HighlightDepthMode.Occluded
	silhouette.Enabled = false
	silhouette.Parent = model
	cleaner:Add(silhouette)

	-- Pop: an impulse spring that swells the board's scale and settles it back with no dip below rest
	-- (critically damped). Spin: a target spring the roll points at a whole number of turns, so it
	-- whips around fast and eases to a straight stop.
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

		-- The base this stand belongs to, which owns the band it draws at, its lever, and the question
		-- of whether the local player is the one allowed to buy off it.
		_owningBase = owningBase,
		_baseId = owningBase:GetId(),

		-- Blacks a cycling ingredient out so it can't be read before it lands. Adorned onto each step's
		-- model in turn and dropped on the final one, which is the one meant to be seen.
		_silhouette = silhouette,

		-- Bumped by anything that takes the stand back -- a wipe, a cull, or the next roll -- so a cycle
		-- still yielding its way through knows it's been cancelled and drops what it has in the air.
		_rollToken = 0,

		-- The buy prompt, up only on the owner's own stands.
		_prompt = nil,

		_board = board,
		-- The board's rest pose as an offset from the base, so its live rest can be rebuilt from the
		-- base each frame and the board rides a slot slide instead of pinning to a stale world pivot.
		-- Recaptured at roll start once the stand has settled at scale 1 (see PlayRoll).
		_boardRestOffset = standBase.CFrame:Inverse() * board:GetPivot(),
		_boardAnimating = false,

		--
		_popSpring = popSpring,
		_spinSpring = spinSpring,
		_currentModel = nil,
		_rolling = false,

		-- The active spring-driven roll model (intro or a cycle clone) and its spr params. Update
		-- keeps re-pointing its pivot at the live landing so it rides along if the stand slots slide.
		_rollingModel = nil,
		_rollingDamping = 0,
		_rollingFrequency = 0,

		-- Studs to raise the landing pivot so the current roll model's base seats on the stand rather
		-- than its (arbitrary) authored pivot. Recomputed per model as each one is placed.
		_landingLift = 0,

		-- The landed result's own bob/spin, driven off the live base in Update so it follows reflows.
		_resultFloating = false,
		_resultFloatElapsed = 0,

		-- Whether the result has finished landing, which is what holds its prompt cue back until the
		-- pulse it lands with has been and gone.
		_resultSettled = false,

		-- The RolledAt of the pull currently on the stand, so a sync that isn't telling us anything new
		-- leaves an in-progress cycle alone. Dropped on a clear, so coming back into range re-reads.
		_shownRolledAt = nil,

		--
		_cleaner = cleaner,
		_rollCleaner = cleaner:Construct(Trove),
		_promptCleaner = cleaner:Construct(Trove),
	}, Stand)

	-- Read together on any of them changing rather than one handler each: they're written together and
	-- only mean anything together, so acting on some of them would pick the wrong animation.
	for _, attribute in { "RolledIngredient", "RolledAt", "RollSpeedLevel" } do
		cleaner:Connect(model:GetAttributeChangedSignal(attribute), function()
			self:Sync()
		end)
	end

	-- A stand can be built after the server has already stamped it -- a rejoin, or walking into range --
	-- so read what's on it now rather than waiting for a change that already happened.
	self:Sync()

	return self
end

-- Blacks the cycling model out so the ingredient can't be read before it lands, off the one Highlight
-- this stand keeps. Disabled rather than just un-adorned: an enabled Highlight with nothing to adorn
-- falls back to its own parent, which here is the stand itself.
function Stand:_setSilhouette(model: Model?)
	self._silhouette.Adornee = model
	self._silhouette.Enabled = model ~= nil
end

-- Where an ingredient rests on the stand: above the live base by half the base's height, the landing
-- gap, and the current ingredient's own seat lift, so its base sits on the stand whatever its size.
-- Read fresh every frame so a server-driven slot slide carries the roll along with it.
function Stand:_getLandingCFrame(): CFrame
	local height = self._base.Size.Y / 2 + RollingConfig.LANDING_GAP + self._landingLift
	return self._base.CFrame + Vector3.new(0, height, 0)
end

-- Per-frame driver for the stand's live animations: the board's pop/spin springs, the in-progress
-- roll model, and the landed result's bob/spin. Each re-derives from the stand's current pose so a
-- grid reflow that slides the stand carries them along instead of stranding them at the old slot.
function Stand:Update(deltaTime: number)
	self:_updateBoard()
	self:_updateRollFollow()
	self:_updateResultFloat(deltaTime)
end

-- Keeps the active roll model (the intro, then each cycle clone) springing toward the live landing.
-- spr preserves the spring's motion and only the pivot goal moves, so the pop-in still plays while
-- the model chases its stand across a reflow.
function Stand:_updateRollFollow()
	if not self._rollingModel then
		return
	end

	Spr.target(self._rollingModel, self._rollingDamping, self._rollingFrequency, { Pivot = self:_getLandingCFrame() })
end

-- Swells and spins the board off the pop/spin springs, then settles it straight. Idle outside a
-- roll: the board is left to the server-driven layout, so this can't pin it to a stale pose while
-- the stand is still rising into its slot or sliding across a reflow.
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

-- Bobs and spins the landed result above its stand's live base, so it tracks the stand through a
-- reflow rather than the roll-start landing pose PartFloat would otherwise pin it to.
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

-- Cycles random ingredients on the stand before landing on the one the server rolled, then puts
-- its billboard and purchase prompt up. Yields for the length of the animation.
-- @param speedLevel the base owner's Unlocks.RollSpeed, off the stand's own attribute rather than
-- player data -- a visitor can't read the owner's levels, and cycling at their own would land the
-- roll outside the window the server gates the claim on. The whole cycle is squeezed by it, so a
-- fast roll is the same steps played quicker rather than fewer of them.
function Stand:PlayRoll(ingredientId: string, speedLevel: number?)
	if self._rolling then
		return
	end

	local speedScale = RollingConfig.GetSpeedScale(speedLevel)

	-- Recapture the board's rest offset from the live parts: the server-driven layout may have slid
	-- this stand into its slot and scaled it up to 1 since it was constructed, so the resting
	-- base->board relationship is only trustworthy now. Update rebuilds the world rest from it each
	-- frame, so the board still follows a later slot slide mid-roll.
	self._boardRestOffset = self._base.CFrame:Inverse() * self._board:GetPivot()

	-- Claim the stand for this roll. Anything that takes it back mid-cycle bumps the token, and the
	-- checks after each wait below drop out on it -- the cycling model isn't on the roll cleaner until
	-- it lands, so without this it'd be orphaned on the stand and the loop would keep cloning over it.
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

	-- Swell the board's scale and send the spin spring off toward a fresh set of whole turns, then pulse the
	-- whole stand. The cycling ingredients silhouette themselves, so the nearest-Highlight rule keeps
	-- them black while the stand's own parts light up.
	self._popSpring:Impulse(RandomUtil.GetRandomFromMinMax(10, 15))

	-- Accumulate rather than set: the spring keeps its angle between rolls, so an absolute target
	-- would already be met on every roll after the first and the board would never spin again.
	self._spinSpring.Target += SPIN_TURNS * math.pi * 2
	self._boardAnimating = true
	EffectController:RunEffect("HighlightPulse", { self._model, Color3.fromRGB(255, 255, 255), 1, 0.4 })

	local allIngredients = Ingredients.GetAllIngredients()

	-- One generator for the whole cycle: RandomUtil makes a fresh Random per call when it isn't handed
	-- one, and the fillers below draw twenty-six times a roll on every stand of the bank.
	local rng = Random.new()

	-- Intro: an ingredient rises out of the stand and swells into place. Parented as a sibling of the
	-- stand rather than under it (here and everywhere else this class spawns a model), so the client's
	-- entrance ScaleTo on the stand can't blow the ingredient's size up; Update keeps it glued.
	local introModel = RandomUtil.GetRandomFromArray(allIngredients, nil, rng).Model:Clone()
	self._landingLift = getSeatLift(introModel)
	introModel:ScaleTo(INTRO_SCALE)
	introModel:PivotTo(self._base.CFrame)
	self:_setSilhouette(introModel)
	introModel.Parent = self._model.Parent
	playRollTick(self._baseId, self._owningBase:GetSoundEmitter())

	Spr.target(introModel, 0.725, 2.2, { Pivot = self:_getLandingCFrame(), Scale = CYCLE_SCALE })
	self._rollingModel, self._rollingDamping, self._rollingFrequency = introModel, 0.725, 2.2

	task.wait(RollingConfig.INTRO_DURATION * speedScale)

	-- Every model a roll spawns is stopped before it's destroyed: spr keeps stepping a destroyed
	-- instance until its spring sleeps, and a Pivot spring on some rotations never does.
	Spr.stop(introModel)
	introModel:Destroy()

	-- Taken back while we were waiting, so there's nothing left to cycle onto.
	if self._rollToken ~= token then
		return
	end

	self._rollingModel = nil

	-- Cycle: swap in a random ingredient each step, waiting longer every time so it decelerates
	-- onto the real one on the final step. Every wait is squeezed by the speed level, so the whole
	-- cycle lands on RollingConfig.GetRollDuration(speedLevel) -- which is the window the server
	-- gates the claim on.
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

		-- The final model is the one meant to be read, so the silhouette comes off it rather than
		-- moving on -- and the pulse below then lands on an ingredient you can actually see.
		self:_setSilhouette(if isFinalStep then nil else model)

		model.Parent = self._model.Parent

		-- The final step lands the real ingredient and gets its own sting below, so it doesn't tick
		-- as well -- the two would fire on the same frame and mush together.
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

		-- Taken back mid-cycle. Only this step's model is ours to drop -- whatever took the stand has
		-- either wiped it (and cleared the silhouette and the follow with it) or started its own roll
		-- and owns both now, so touching them here would reach into the new roll.
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
	-- Added after the model so it runs first (Trove cleans in reverse add order): a Clear, a Purchase or
	-- a teardown stops the landing springs before the model is destroyed or handed to the fly-in, and it
	-- also covers the delayed Pivot stop below being cancelled with the rest of the cleaner.
	self._rollCleaner:Add(function()
		Spr.stop(currentModel)
	end)
	self._rolling = false

	-- Let the landing spring settle (the follow keeps it tracking the live base until here), then
	-- hand the pivot from spr to Update's result float and let the prompt highlight in.
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

-- Puts an already-rolled ingredient straight onto the stand, skipping the cycle. A roll is held until
-- it's bought, a rejoin included, so one that landed in a session that's over has nothing left to
-- animate -- it just has to be sitting there, buyable, the way they left it. This is everything past
-- the landing in PlayRoll and nothing before it.
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

	-- Sibling of the stand, as above -- and this is the path that most needs it: a restore lands the
	-- instant the base is built, right in the middle of the stand's entrance ScaleTo, so parenting it
	-- under the stand left it 1/LAYOUT_ENTRANCE_SCALE times too big. Nothing here re-asserts a scale
	-- the way the roll's springs do, so there'd be nothing to undo it.
	model.Parent = self._model.Parent

	self._currentModel = model
	self._rollCleaner:Add(model)

	-- Straight into the float Update drives: there's no landing spring to let settle first, and no
	-- reason to delay the prompt's highlight when nothing just landed for it to talk over.
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

-- Puts the buy prompt and its cue on the landed result, on the local player's own base only. The
-- billboard above stays up for everyone -- what someone pulled and what it's worth is the part worth
-- showing off -- it's only the purchase that's theirs. Re-runnable, so gaining or losing the base
-- takes the prompt up or down without the result being rebuilt, which is what covers BaseId landing
-- after the stands were already there.
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
		prompt.HoldDuration = 0.5
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.MaxActivationDistance = PROMPT_DISTANCE
		prompt.ActionText = "Buy"
		prompt.Parent = model.PrimaryPart

		self._prompt = prompt
		self._promptCleaner:Add(prompt)
		self._promptCleaner:Connect(prompt.Triggered, function()
			IngredientRollingController = IngredientRollingController or require(script.Parent)
			IngredientRollingController:RequestPurchase(self._id)
		end)
	end

	-- Held back until the landing has settled: the pulse a result lands with and this cue are both
	-- Highlights on the one model, and the nearest-Highlight rule would render whichever it liked.
	if self._resultSettled then
		model:AddTag("PromptSubjectHighlight")
	end
end

-- Reads what the server says is on this stand and puts it there, which is the one path every client
-- takes -- the owner's and a visitor's alike. A stamp from a moment ago is a pull still in the air, so
-- it cycles; an older one landed somewhere we weren't watching (a session that's over, or before we
-- walked up), so it's simply seated. An empty stamp means it's been bought.
function Stand:Sync()
	-- Nothing is drawn on a base too far off to make out, so there's nothing to put back until it's near.
	if not self._owningBase:IsRendered() then
		return
	end

	local ingredientId = self._model:GetAttribute("RolledIngredient")
	if not ingredientId then
		-- The only thing that empties a stamped stand is the owner buying what was on it, so that's who
		-- the ingredient flies to. A base whose owner has gone has its stands destroyed along with it,
		-- so there's nobody to find and nothing left to fly.
		local owner = self._owningBase:GetOwner()
		if owner then
			self:Purchase(owner)
		else
			self:Clear()
		end

		return
	end

	local rolledAt = self._model:GetAttribute("RolledAt")

	-- Already showing this pull: the second of the two attributes landing, or a re-sync from something
	-- other than the roll changing. Rebuilding here would restart a cycle that's part way through.
	if self._shownRolledAt == rolledAt then
		return
	end

	-- Whatever is up belongs to the pull before this one, and Clear is what releases a cycle still
	-- running for it. It drops _shownRolledAt too, so walking back into range re-reads the stand.
	self:Clear()
	self._shownRolledAt = rolledAt

	-- Cycle only for a pull that's still in the air, and only where it's near enough to be worth the
	-- models a cycle clones. A cycle always takes the full roll duration, so one started late would
	-- land after the pull it belongs to -- possibly on something already bought.
	local isFresh = (workspace:GetServerTimeNow() - rolledAt) < RollingConfig.ROLL_ANIMATION_GRACE
	if not (isFresh and self._owningBase:IsAnimating()) then
		self:ShowResult(ingredientId)
		return
	end

	-- The lever swings with the roll, so it reads as something someone did rather than a bank of stands
	-- lighting up on their own.
	self._owningBase:SwingLeverForPull(rolledAt)

	task.spawn(function()
		local played, err = pcall(function()
			self:PlayRoll(ingredientId, self._model:GetAttribute("RollSpeedLevel"))
		end)

		-- A stand that throws mid-roll would stay flagged as rolling and deadlock the lever's wait, so
		-- clear it back down rather than leaving the lever dead.
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

	-- Pop rather than Remove: the model has to outlive the cleaner so the fly-in can finish with
	-- it. Cleaning afterwards still kills the prompt connection and the deferred float thread.
	self._rollCleaner:Pop(model)
	self._rollCleaner:Clean()

	-- The prompt is destroyed with the rest below, so drop our handle on it rather than leaving one
	-- pointing at a prompt that's flown off with the model.
	self._promptCleaner:Clean()
	self._prompt = nil

	model:RemoveTag("PromptSubjectHighlight")

	-- Off the model, which is where _showResult puts it -- looking under the PrimaryPart never found it,
	-- and the billboard rode the fly-in all the way in.
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

-- Wipes whatever the last roll left on the stand, and releases a cycle still running for it: the token
-- bump is what tells that cycle it's been taken over, so it drops the model it has in the air instead
-- of leaving it stranded on the stand and cloning the next one over the top of it.
function Stand:Clear()
	self._rollToken += 1

	self._rollCleaner:Clean()
	self._promptCleaner:Clean()
	self:_setSilhouette(nil)

	self._prompt = nil
	self._currentModel = nil
	self._rollingModel = nil
	self._rolling = false
	self._resultFloating = false
	self._resultSettled = false

	-- Dropped so walking back into range re-reads the stand rather than deciding it's already showing
	-- what's on it.
	self._shownRolledAt = nil
end

function Stand:Destroy()
	self._cleaner:Destroy()
	self = nil
end

return Stand
