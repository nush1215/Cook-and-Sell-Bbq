-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)
local Highlights = require(Shared.Config.Highlights)
local Structures = require(Shared.Config.Structures)
local CookStates = require(Shared.Config.CookStates)
local StickModel = require(Shared.StickModel)
local GuiUtil = require(Shared.GuiUtil)

-- Controllers
local Controllers = script.Parent.Parent
local SoundController = require(Controllers.SoundController)
local ShopController = require(Controllers.ShopController)
local UIController = require(Controllers.UIController)

-- Modules
local Modules = script.Parent.Parent.Parent.Modules
local EquippedItem = require(Modules.EquippedItem)
local EffectUtil = require(Modules.EffectUtil)

-- Assets
local UI = ReplicatedStorage.Assets.UI
local Particles = ReplicatedStorage.Assets.Particles

--
local LocalPlayer = Players.LocalPlayer

local GRILL_PROMPT_DISTANCE = 10
local KNOB_PROMPT_DISTANCE = 15
local GRILL_PROMPT_HOLD = 0.3
local KNOB_PROMPT_HOLD = 0.1
-- Stopping a cook is a timing call, so it fires on the press: any hold at all is spent inside the very
-- window the player is aiming at, and on a short skewer 0.3s is a good fraction of it.
local STOP_PROMPT_HOLD = 0
-- The button the take is offered on, which is the one thing on this griller that isn't the default E.
-- Roblox shows one prompt per button (ProximityPromptExclusivity.OnePerButton) and picks whichever the
-- player is nearer to, and the take is the only prompt here that's live at the same time as another:
-- a raw skewer can be lit or taken, so the knob's Cook and the skewer's Take BBQ are both up at once.
-- Sharing E meant the knob won from nearly anywhere someone stands -- it reaches five studs further and
-- sits on the near face -- and the take was built, enabled, and never drawn. The place prompt keeps E
-- alongside the knob because those two genuinely can't both be up: one wants the grate free and the
-- other wants it occupied.
local TAKE_PROMPT_KEY = Enum.KeyCode.F
local TAKE_PROMPT_GAMEPAD_KEY = Enum.KeyCode.ButtonY
local SKIP_COOK_PRODUCT = "SkipCook" -- the Products entry the skip button is priced from and buys
-- What the skip is worth offering on at all. A BBQ that's done in a few seconds isn't a wait worth
-- buying out of, and an offer that's up the moment the stove is lit is the game asking for money rather
-- than selling a way past something. The first is measured on the whole bar, which is what CookTime
-- stamps and what the player is actually watching -- so a quick ingredient, or a slower one on a fast
-- grill, goes without.
local SKIP_MIN_COOK_TIME = 10 -- seconds of bar below which the skip is never offered
local SKIP_REVEAL_DELAY = 5 -- seconds into a cook before it is
-- The tag that outlines an instance for as long as its prompt is on screen. Matches the
-- PromptSubjectHighlight component's file name, which is what it registers itself under.
local PROMPT_HIGHLIGHT_TAG = "PromptSubjectHighlight"
-- How see-through the preview of the BBQ in hand is while it's shown seated on the grill. The same
-- figure the build ghost uses, so a ghosted thing reads as ghosted wherever the game shows one.
local GHOST_TRANSPARENCY = 0.3
local KNOB_UI_FLOAT_AMPLITUDE = 0.15 -- how far the knob billboard bobs, in studs
local KNOB_UI_FLOAT_SPEED = 3 -- how fast the bob cycles, in radians per second

-- Cook animation tuning.
local SPIN_SPEED = math.rad(120) -- how fast the skewer turns while cooking, once up to speed
local SPIN_RAMP_TIME = 1 -- seconds the spin eases up to speed at the start, and back down in the wind-down after a finish
local COOK_MATERIAL_PROGRESS = 0.8 -- how far through the raw -> cooked browning before the cooked material/variant shows
-- The two colours the countdown on the cooking bar is written in: the word itself in gold so it's
-- the thing the eye lands on -- the same #ffd400 the shop, codes and the daily reward write their
-- figures in -- and the figure in the Perfect band's own green, taken from the config rather than
-- authored again so it's the colour the fill underneath is about to turn. The "in:" joining them is
-- left whatever the label was authored, so the two coloured runs are the word and the number.
local PERFECT_WORD_COLOR = Color3.fromRGB(255, 212, 0)
local PERFECT_COUNTDOWN_COLOR = CookStates.GetStateFromId("Perfect").BarColor
local PARTICLE_CLEANUP_PADDING = 0.5 -- extra seconds after the longest particle lifetime before the emitters are dropped
-- The cook effect a griller with no folder of its own under Assets.Particles.Cooking falls back on --
-- the plain sizzle every grill but the Electric one shows. See _showCookParticles.
local COOK_PARTICLE_DEFAULT = "Default"

-- The looped sizzle a lit grill carries, eased in and back out so the stove going on or off doesn't
-- crack in or cut dead.
local COOK_SOUND = "GrillCooking"
local COOK_SOUND_FADE_IN = 0.5
local COOK_SOUND_FADE_OUT = 1

-- The alarm the owner gets once their bar fills: a burst rung out on the grill itself, then another on
-- a gap, for as long as they leave the stove on. The bar itself can only warn someone who's stood there
-- watching it, and the skewer chars for as long as it's left.
local ALARM_SOUND = "Alarm"
local ALARM_DURATION = 5 -- seconds each burst rings for
local ALARM_INTERVAL = 2 -- seconds of silence between one burst ending and the next starting
local ALARM_FADE_IN = 0 -- an alarm should land on the beat, so it cracks in rather than ramping
local ALARM_FADE_OUT = 0.15 -- just enough that cutting the burst short doesn't click

-- Stove visuals: the charcoal glow, the LED and the knob handle.
local CHARCOAL_OFF_COLOR = Color3.fromRGB(25, 12, 7)
-- What the coals burn up to, when the Charcoal part doesn't say otherwise -- the attribute below is
-- what a grill authored to burn its own colour sets.
local CHARCOAL_GLOW_ATTRIBUTE = "GlowColor"
local CHARCOAL_DEFAULT_GLOW = Color3.fromRGB(255, 85, 0)
local CHARCOAL_FADE_TIME = 3 -- seconds the charcoal glow fades in at the start of a cook and back out at the end
local LED_ON_COLOR = Color3.fromRGB(0, 255, 0)
local LED_OFF_COLOR = Color3.fromRGB(255, 0, 0)
local HANDLE_ON_ROTATION = CFrame.Angles(0, math.rad(90), 0) -- how far the knob turns when the stove's on

-- Required lazily to break the cycle: GrillerController requires this class.
local GrillerController

--[[
    Class for a single placed griller, on every client, so a cooking skewer spins and browns for
    visitors too.

    The server clones the (static) skewer model onto the griller and mirrors the record onto its
    attributes (PlacedStickId / Cooking / Cooked / CookStartedAt / CookTime / CookIngredients). This
    class reads those and renders the cook locally: while Cooking it spins the skewer (fully
    client-authoritative -- it spins up, holds speed, and after the stop winds itself down onto a
    whole turn rather than ever reconciling to the server's static model), browns each ingredient part
    and then chars it off the elapsed time, swaps in the cooked material on the way, and lights the
    stove (LED, knob turn, charcoal glow). All of it derives from CookStartedAt, so it plays the same
    on every client and a mid-cook join picks up at the right progress.

    A cook doesn't end on its own -- nothing ends it but the player. The CookingUI bar runs 0 -> 1 and
    they pick the moment to turn the stove back off, which is what decides whether the skewer comes off
    raw, perfect or merely cooked. Past the end of the bar the fill has nowhere left to go, so it holds
    full while the title and its colour turn: the cook keeps burning on a wall clock from there, and
    the skewer chars with it. From that point the owner's own client also rings an alarm on the grill,
    on a burst and a gap, for as long as they leave it on -- a player who walked off has nothing else
    telling them. The bands and those timings both live in the CookStates config, so the bar this draws
    and the state the server settles on when the stop lands can't disagree.

    The grill's prompts and the cook knob only go up on grillers the local player owns, which the
    OwnerUserId attribute the base stamped on it is what says. A griller only exists while its owner
    does, so that never changes over one griller's life. Each one sits on the thing it acts on: the
    place on the body's GrillAttachment, the stove's switch on the knob, and the take on the skewer
    being taken. The take is offered on its own button (TAKE_PROMPT_KEY) because it's the only one of
    the three that's ever up alongside another: a raw skewer can be lit or taken, and Roblox draws one
    prompt per button. The Robux skip is the one offer that isn't a prompt -- it rides the cooking bar,
    which is already up for the whole stretch it's on offer for and is where the player is already
    looking.

    Every part of the griller is resolved once, here, and held for this class's whole life -- and the
    prompts above are parented to those parts, which under StreamingEnabled means they're destroyed the
    moment their part streams out. That's sound because the server streams a griller atomically (see
    Base:BuildStructure), so the model and its parts come and go together and GrillerController's tag
    handlers tear this class down and build a fresh one around each cycle. Nothing here re-resolves,
    and nothing here should need to; if a griller is ever made nonatomic again, this class is holding
    corpses and its prompts never come back.
]]

-- The one ScreenGui the grill billboards live under. The cooking bar sits in PlayerGui adorned back
-- onto the griller rather than in the world, because that's what makes its skip button clickable.
local function getScreenGui(): ScreenGui
	local playerGui = LocalPlayer.PlayerGui
	local screenGui = playerGui:FindFirstChild("GrillBillboards")

	if screenGui == nil then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "GrillBillboards"
		screenGui.ResetOnSpawn = false
		screenGui.Parent = playerGui
	end

	return screenGui
end

-- How far the spin has turned by `elapsed`, expressed in full-speed seconds: it eases up from a
-- standstill to full speed over the first `ramp` seconds (integrated from a smoothstep so it accelerates
-- like a motor), then holds full speed for as long as the cook runs. No ramp-down here -- the wind-down
-- after a finish is its own closed form in Update, so this only ever accelerates.
local function rampedSpinDistance(elapsed: number, ramp: number): number
	local t = math.max(elapsed, 0)
	if t <= ramp then
		local x = t / ramp
		return ramp * (x ^ 3 - 0.5 * x ^ 4)
	end

	return 0.5 * ramp + (t - ramp)
end

-- Identifies a part by the geometry it draws rather than its name, so the cook animation can pair a raw
-- ingredient part to its cooked counterpart. The raw and cooked models are the same meshes with different
-- colours, but they don't always name their parts the same -- matching on name alone left every part but
-- the primary uncooked. The size tail keeps plain unmeshed parts pairable too.
local function meshKey(part: BasePart): string
	if part:IsA("MeshPart") then
		return part.MeshId
	end

	local mesh = part:FindFirstChildWhichIsA("SpecialMesh")
	return if mesh then mesh.MeshId else `{part.ClassName}:{part.Size}`
end

--
local Grill = {}
Grill.__index = Grill

function Grill.new(slot: Instance)
	--
	local cleaner = Trove.new()

	-- Everything here sits down inside the grill body (the attachments on Grill.Main.Base, the charcoal
	-- and the grates on Grill.Main), so it's all looked for the whole way down rather than by path -- the
	-- body gets re-nested as it's re-authored, and a lookup that names each level goes with it. The knob
	-- is authored at the top today, but it's found the same way for the same reason.
	local knob = slot:FindFirstChild("Knob", true)
	local attachment = slot:FindFirstChild("StickAttachment", true)
	local grillAttachment = slot:FindFirstChild("GrillAttachment", true)
	local grillModel = slot:FindFirstChild("Grill")

	-- Every part named Charcoal in the griller rather than the first one found, so a grill modelled with
	-- coals down its length lights all of them together. Each carries what it burns up to, read off the
	-- part rather than fixed here so a grill can burn its own colour without a code change -- and read
	-- once, since nothing writes it at runtime and these are lerped every frame of every cook on screen.
	local charcoals = {}
	for _, descendant in slot:GetDescendants() do
		if descendant.Name == "Charcoal" and descendant:IsA("BasePart") then
			table.insert(charcoals, {
				Part = descendant,
				GlowColor = descendant:GetAttribute(CHARCOAL_GLOW_ATTRIBUTE) or CHARCOAL_DEFAULT_GLOW,
				-- Where this one's glow had actually got to when the stove was switched off, so the
				-- cool-down starts from there rather than flaring up to full first (see _sync).
				CoolFrom = nil,
			})
		end
	end

	local self = setmetatable({
		--
		_slot = slot,

		-- Which placed griller this is, and whose it is. Both are stamped on by the base before it tags
		-- the model, so they're set by the time this class is ever built, and a griller only exists
		-- while its owner does -- so ownership is fixed for the whole life of one of these.
		_uid = slot:GetAttribute(Structures.UID_ATTRIBUTE),
		_ownerUserId = slot:GetAttribute(Structures.OWNER_ATTRIBUTE),

		-- Which griller this is, off the type the base stamps alongside the two above -- the tag this class
		-- is built from only says it's a griller. Resolved to the config entry once here rather than looked
		-- up per cook: a placed structure never changes what it is, and it's what the grate's effect and its
		-- extra sound both come off. Nil for a model the config has since dropped, which both readers below
		-- fall back on the shared set for.
		_structure = Structures.GetStructureFromId(slot:GetAttribute(Structures.TYPE_ATTRIBUTE)),

		-- Where the skewer seats, as an offset from the griller's own pivot rather than as the world pose
		-- it works out to. A world pose read here would be wrong twice over: a griller placed this
		-- session is still springing down onto its cell when this class is built (the server sets it
		-- PLACE_DROP_HEIGHT above its slot and LayoutStand drops it), and one that's later moved leaves
		-- any pose captured before the move behind. The offset holds through both -- see _seatedCFrame.
		_attachment = attachment,
		_seatOffset = attachment and slot:GetPivot():Inverse() * attachment.WorldCFrame,

		-- Where the grill body's own prompt hangs: the place. The take isn't one of them -- it rides on
		-- the skewer itself.
		_grillAttachment = grillAttachment,

		-- Stove parts, and their authored rest so turning the stove off can put them back. Captured
		-- before we ever touch them (the server no longer drives the stove).
		_knob = knob,
		_led = knob and knob:FindFirstChild("LED"),
		_handle = knob and knob:FindFirstChild("Handle"),
		_charcoals = charcoals,
		_handleRestOffset = nil,
		-- Whether the stove is currently *shown* lit, so the handle is only ever sprung when that
		-- actually changes. Springing it to where it already is would be harmless on a settled griller,
		-- but on one still dropping in it pins the knob to a pose the rest of the model hasn't reached.
		_stoveLit = false,

		-- The grill body itself, which the place cue adorns rather than the whole griller -- the griller
		-- holds the knob as well, and that carries its own cue on its own condition.
		_grillModel = grillModel,

		-- The grates the skewer sits on: what the cook's particles mount to, and what its sounds play from,
		-- so they come off the grill itself rather than a point in space.
		_gratesPart = slot:FindFirstChild("Grates", true),

		-- The server-cloned skewer model and the per-part raw -> cooked targets the colour lerp drives.
		_skewerModel = slot:FindFirstChild("Skewer"),
		_cookParts = nil,
		_materialApplied = false,

		-- Whether we're currently animating a cook, and the timing it derives from.
		_cooking = false,
		_cookStartedAt = nil,
		_cookTime = nil,

		-- The skewer currently on the grate, tracked so _sync can tell a fresh placement from a take.
		-- Seeded from the slot so a grill that's already loaded doesn't ring as we join.
		_placedStickId = slot:GetAttribute("PlacedStickId"),

		-- The wind-down that plays the spin out after a stop: { StartClock, StartAngle, Hold, Ramp }, the
		-- angle a cook lit before that wind-down landed carries in from it: { StartClock, Angle }, and the
		-- coals' own cool-down: { StartClock }, which each of them fades along from its own CoolFrom.
		_spinDown = nil,
		_spinCarry = nil,
		_stoveOff = nil,

		-- The cooking bar shown on the griller while it cooks, the authored fill size Update only swaps
		-- the X of, and the last band it was painted for. Plus the floating "cook me" billboard shown on
		-- the knob while the skewer's waiting to be lit.
		_cookingUI = nil,
		_cookingFillSize = nil,
		_cookingState = nil,
		_knobUI = nil,

		-- When this cook's perfect window opens and closes, on the synced server clock, as the timer on
		-- the bar counts down to. Solved off the cook's stamps the first frame it draws and dropped by
		-- _sync whenever one of those stamps moves.
		_perfectStartsAt = nil,
		_perfectEndsAt = nil,

		-- The cooking particles mounted on the grate while a cook runs.
		_cookEffect = nil,

		-- When the next alarm burst is due, on the local clock. Nil until the bar fills.
		_alarmNextAt = nil,

		--
		_prompt = nil,
		_knobPrompt = nil,
		_takeSkewerPrompt = nil,
		_takeSkewerModel = nil, -- the skewer model the take prompt was built on, so a swap rebuilds it

		-- The see-through BBQ preview: the skewer RefreshInteraction last worked out is worth previewing,
		-- the place prompt's own visibility, and the tool the model standing there was actually built
		-- from -- so a refresh that hasn't changed what's in hand leaves it alone rather than rebuilding
		-- it under the player. The first two are what decide whether it's up (see _refreshGhost).
		_ghostSource = nil,
		_promptShown = false,
		_ghostTool = nil,

		-- [id] = true for every Robux price this grill has already gone and asked for -- so a lookup that came back
		-- empty isn't tried again every time a sign is repainted.
		_requestedPrices = {},

		--
		_cleaner = cleaner,
		_promptCleaner = cleaner:Construct(Trove),
		_cookingUICleaner = cleaner:Construct(Trove),
		_knobCleaner = cleaner:Construct(Trove),
		_knobUICleaner = cleaner:Construct(Trove),
		_takeSkewerCleaner = cleaner:Construct(Trove),
		_ghostCleaner = cleaner:Construct(Trove),
		_particleCleaner = cleaner:Construct(Trove),
		_soundCleaner = cleaner:Construct(Trove),
		_alarmCleaner = cleaner:Construct(Trove),
	}, Grill)

	self._handleRestOffset = self._handle and slot:GetPivot():Inverse() * self._handle.CFrame

	-- The prompt/knob and the spin all need the griller's parts. The server streams a structure whole
	-- (see Base:BuildStructure), so reaching here without one means the structure's template is wrong
	-- rather than that it's merely late.
	if not attachment then
		warn(`[Griller] {slot.Name} has no StickAttachment, its cook won't render`)
		return self
	end

	-- The stove is the knob's alone -- its prompt, its glow, its LED and the "cook me" billboard all hang
	-- off the handle -- so a griller without one is a grill nobody can light. Warned rather than bailed
	-- on: the cook still renders for everyone watching it, and the owner is the only one who loses
	-- anything.
	if not self._handle then
		warn(`[Griller] {slot.Name} has no Knob.Handle, its stove can't be switched`)
	end

	-- The server rebuilds the skewer model on a place/remove/stop, so follow it in and out.
	cleaner:Connect(slot.ChildAdded, function(child)
		if child.Name == "Skewer" then
			self._skewerModel = child
			if self._cooking then
				self._materialApplied = false
				self:_rebuildCookParts()
			end

			-- Seated off the same expression the cook's first frame uses. The server seats it too, from
			-- its own live read of the griller's pivot, and the two only agree for as long as nothing has
			-- moved since this class captured its offset -- so re-seating here is what stops lighting the
			-- stove from turning the skewer to meet the client's idea of where it sits. A model arriving
			-- mid-cook or mid-wind-down is left alone: both of those already drive it every frame, and
			-- seating it here would show exactly the one frame they exist to hide.
			if not self._cooking and not self._spinDown then
				child:PivotTo(self:_seatedCFrame())
			end

			-- The take cue rides on this model, so it's wiped every time the server swaps one in. This is
			-- what puts it back -- and it covers the case where the new model lands after the attribute
			-- change that would otherwise have been our only cue.
			self:RefreshInteraction()
		end
	end)
	cleaner:Connect(slot.ChildRemoved, function(child)
		if child == self._skewerModel then
			self._skewerModel = nil
			self._cookParts = nil
		end
	end)

	-- The cook animation, the stove and the prompt all track these.
	local attributes = {
		"PlacedStickId",
		"Cooking",
		"Cooked",
		"CookStartedAt",
		"CookTime",
		"CookWindowStretch",
		"CookProgress",
		"CookInstability",
		"CookInstabilityPhase",
		"CookIngredients",
	}
	for _, attribute in attributes do
		cleaner:Connect(slot:GetAttributeChangedSignal(attribute), function()
			self:_sync()
		end)
	end

	-- Start from the off look; _sync lights the stove straight back up if this slot's already cooking.
	-- The charcoal is settled here rather than in _setStoveOff, which now hands it to Update's cool-down
	-- instead of snapping it dark.
	for _, charcoal in self._charcoals do
		charcoal.Part.Color = CHARCOAL_OFF_COLOR
	end

	self:_setStoveOff()
	self:_sync()

	return self
end

-- The pose this griller belongs at, which isn't necessarily the one it's in. The server writes its cell
-- to SlotCFrame and the client springs the model there (LayoutStand), so between a griller appearing and
-- its drop-in landing the live pivot is up to PLACE_DROP_HEIGHT above where everything below wants to
-- measure from -- and a griller that's been moved slides to a new one the same way. Everything this class
-- seats reads through here, so none of it can end up hanging in the air over the grill.
function Grill:_settledPivot(): CFrame
	return self._slot:GetAttribute("SlotCFrame") or self._slot:GetPivot()
end

-- Where a skewer sits when it's seated on this griller: the same pose the server pivots the real one to.
function Grill:_seatedCFrame(): CFrame
	return self:_settledPivot() * self._seatOffset
end

-- Where the knob handle sits with the stove off. The stove turning on rotates it from here.
function Grill:_handleRestCFrame(): CFrame
	return self:_settledPivot() * self._handleRestOffset
end

-- Seconds since this cook started, off the synced server clock so every client agrees. Zero when
-- there's no cook stamped.
function Grill:_elapsed(): number
	if not self._cookStartedAt then
		return 0
	end

	return math.max(0, workspace:GetServerTimeNow() - self._cookStartedAt)
end

-- How long this cook's spin takes to reach full speed. Capped at half the cook so a very short one still
-- spends as long winding up as it does at speed. The wind-down reads it too and lands off the same
-- figure -- the two disagreeing is what used to rest the skewer short of a whole turn.
function Grill:_spinRamp(): number
	return math.min(SPIN_RAMP_TIME, math.max(self._cookTime or 0, 1e-3) / 2)
end

-- Current spin angle in radians past the seated orientation -- the closed form the cook's spin renders
-- from: eased up over the ramp, then SPIN_SPEED for as long as the cook's been running.
function Grill:_spinAngleNow(): number
	local ramp = self:_spinRamp()
	local angle = SPIN_SPEED * rampedSpinDistance(self:_elapsed(), ramp)

	-- A cook lit while the last one was still winding down opens from wherever that had turned to rather
	-- than from the seated orientation, and bleeds the offset away over the ramp -- so the re-light is
	-- continuous and the closed form above is back on its own within a second.
	local carry = self._spinCarry
	if carry then
		local bleed = math.clamp((os.clock() - carry.StartClock) / ramp, 0, 1)
		angle += carry.Angle * (1 - bleed * bleed * (3 - 2 * bleed))
	end

	return angle
end

-- How far the wind-down after a stop has turned by now, and whether it's finished. Full speed through
-- Hold, then the spin-up's smoothstep run in reverse over Ramp. Hold is sized so the rest lands exactly
-- on a whole turn, i.e. the seated orientation. Read by Update to render it, and by _sync to carry it
-- into a cook lit before it landed.
function Grill:_spinDownAngle(): (number, boolean)
	local spinDown = self._spinDown
	local elapsed = os.clock() - spinDown.StartClock

	if elapsed >= spinDown.Hold + spinDown.Ramp then
		return spinDown.StartAngle + SPIN_SPEED * (spinDown.Hold + 0.5 * spinDown.Ramp), true
	end

	local distance = elapsed -- full-speed seconds covered so far
	if elapsed > spinDown.Hold then
		local y = (spinDown.Hold + spinDown.Ramp - elapsed) / spinDown.Ramp
		distance = spinDown.Hold + 0.5 * spinDown.Ramp - spinDown.Ramp * (y ^ 3 - 0.5 * y ^ 4)
	end

	return spinDown.StartAngle + SPIN_SPEED * distance, false
end

-- Pairs the skewer's ingredient parts to their cooked counterparts, so the colour lerp and the material
-- swap read their targets straight off each part's CookedModel mesh (colour, material and variant). Each
-- ingredient child is tagged with its SkewerIndex, so duplicates line up with the CookIngredients list.
-- Parts within an ingredient are paired on mesh identity (see meshKey), claiming each cooked part once:
-- mesh and name first, then mesh alone, then -- if the two models hold the same number of parts -- by
-- traversal order. Name alone isn't enough, since the cooked model doesn't always name its parts the same.
function Grill:_rebuildCookParts()
	self._cookParts = nil

	local model = self._skewerModel
	local csv = self._slot:GetAttribute("CookIngredients")
	if not model or not csv or csv == "" then
		return
	end

	local ingredientIds = string.split(csv, ",")

	local childByIndex = {}
	for _, child in model:GetChildren() do
		local index = child:GetAttribute("SkewerIndex")
		if index then
			childByIndex[index] = child
		end
	end

	local parts = {}
	for index, ingredientId in ingredientIds do
		local child = childByIndex[index]
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)
		if not (child and ingredient) then
			continue
		end

		local rawParts = {}
		for _, descendant in child:GetDescendants() do
			if descendant:IsA("BasePart") then
				table.insert(rawParts, descendant)
			end
		end

		local cookedParts = {}
		for _, descendant in ingredient.CookedModel:GetDescendants() do
			if descendant:IsA("BasePart") then
				table.insert(cookedParts, descendant)
			end
		end

		-- Pass 1: same mesh and same name. Pass 2: same mesh, taking whichever copy is still going --
		-- which is what pairs the parts the cooked model renames. Each cooked part is claimed once, so
		-- an ingredient built from two of the same mesh still lands one target each.
		local pairing = {} -- [rawPart] = cookedPart
		local claimed = {}

		for pass = 1, 2 do
			for _, raw in rawParts do
				if pairing[raw] then
					continue
				end

				for _, cooked in cookedParts do
					if claimed[cooked] or meshKey(cooked) ~= meshKey(raw) then
						continue
					end
					if pass == 1 and cooked.Name ~= raw.Name then
						continue
					end

					pairing[raw] = cooked
					claimed[cooked] = true
					break
				end
			end
		end

		-- Pass 3: the models are copies of each other, so when they hold the same number of parts the
		-- leftovers line up by traversal order -- the last resort before a part just wouldn't brown.
		if #rawParts == #cookedParts then
			for partIndex, raw in rawParts do
				local cooked = cookedParts[partIndex]
				if not (pairing[raw] or claimed[cooked]) then
					pairing[raw] = cooked
					claimed[cooked] = true
				end
			end
		end

		local unpaired = 0
		for _, raw in rawParts do
			local cooked = pairing[raw]
			if not cooked then
				unpaired += 1
				continue
			end

			table.insert(parts, {
				Part = raw,
				FromColor = raw.Color,
				ToColor = cooked.Color,
				ToMaterial = cooked.Material,
				ToVariant = cooked.MaterialVariant,
			})
		end

		-- A real asset problem rather than something the code can paper over: the ingredient's Raw and
		-- Cooked models hold genuinely different geometry, so those parts stay raw through the cook.
		if unpaired > 0 then
			warn(
				`[Griller] {ingredient.Id}'s cooked model doesn't line up with its raw one, {unpaired} part(s) won't brown`
			)
		end
	end

	self._cookParts = parts
end

-- Reads the slot's attributes and reconciles: starts or stops the cook (stove + part pairing) on a
-- Cooking edge, and keeps the prompt/knob current.
function Grill:_sync()
	local cooking = self._slot:GetAttribute("Cooking") == true

	-- On a finish edge, read the spin off the outgoing cook's stamps before the lines below overwrite
	-- them -- the wind-down continues from exactly this angle, and lands off the ramp that cook spun up
	-- along rather than the constant, so a cook too short to have reached full speed still rests square.
	local exitAngle, exitRamp
	if not cooking and self._cooking then
		exitAngle = self:_spinAngleNow()
		exitRamp = self:_spinRamp()
	end

	self._cookStartedAt = self._slot:GetAttribute("CookStartedAt")
	self._cookTime = self._slot:GetAttribute("CookTime")
	self._cookWindowStretch = self._slot:GetAttribute("CookWindowStretch")
	self._cookProgress = self._slot:GetAttribute("CookProgress")
	self._cookInstability = self._slot:GetAttribute("CookInstability")
	self._cookInstabilityPhase = self._slot:GetAttribute("CookInstabilityPhase")

	-- Dropped here rather than only on the cooking edge, because the six stamps above are what the
	-- window was solved from and they don't all land on the same frame: a cook whose CookInstability
	-- arrives behind its Cooking would otherwise count down to the window a steady grill would have
	-- had. Every one of them re-runs this, so the next frame re-solves against whatever's current.
	self._perfectStartsAt = nil
	self._perfectEndsAt = nil

	if cooking and not self._cooking then
		self._cooking = true

		-- A stove lit again before the last wind-down landed carries its angle into the new cook rather
		-- than dropping it: the closed form opens at the seated orientation, so restarting from there is
		-- a jump of up to a whole turn. _spinAngleNow bleeds the offset away over the ramp, so the two
		-- meet back up within a second and every client is drawing the same thing again from there.
		if self._spinDown then
			self._spinCarry = { StartClock = os.clock(), Angle = self:_spinDownAngle() % (2 * math.pi) }
			self._spinDown = nil
		end

		self._stoveOff = nil
		self._materialApplied = false
		self._skewerModel = self._slot:FindFirstChild("Skewer")
		self:_stopAlarm()
		self:_rebuildCookParts()
		self:_setStoveOn()
		self:_showCookingUI()
		self:_showCookParticles()
		self:_startCookSound()
	elseif not cooking and self._cooking then
		self._cooking = false
		self._cookParts = nil
		self._spinCarry = nil
		self:_setStoveOff()
		self:_hideCookingUI()
		self:_hideCookParticles()
		self:_stopCookSound()
		self:_stopAlarm()

		-- Each coal cools down from wherever its own glow had actually got to. A cook stopped in its first
		-- seconds has barely lit, so starting the fade from full would flare it up before dimming it.
		for _, charcoal in self._charcoals do
			charcoal.CoolFrom = charcoal.Part.Color
		end
		self._stoveOff = { StartClock = os.clock() }

		-- The spin is client-authoritative, so rather than reconciling to wherever the server seated
		-- the rebuilt model (the old snap), Update keeps turning it from the captured angle: full speed
		-- until the landing lines up, then a motor-like ease-out that rests exactly on a whole turn --
		-- the seated orientation -- so the swap underneath never shows.
		local residual = (exitAngle + SPIN_SPEED * 0.5 * exitRamp) % (2 * math.pi)
		self._spinDown = {
			StartClock = os.clock(),
			StartAngle = exitAngle,
			Hold = ((2 * math.pi - residual) % (2 * math.pi)) / SPIN_SPEED,
			Ramp = exitRamp,
		}
	end

	-- Not cooking is held as a state here rather than only as the transition above: the edge is what tears
	-- the cook's render down, but the alarm has to stay quiet for as long as there's nothing on the heat,
	-- however the client arrived at that. Without this a burst scheduled on a cook whose edge went by
	-- unseen is still due on a grill that's since had a fresh BBQ set down on it.
	if not cooking and self._alarmNextAt then
		self:_stopAlarm()
	end

	local placedStickId = self._slot:GetAttribute("PlacedStickId")

	-- A skewer arriving on an empty grate is the player setting one down; the take that clears it isn't.
	local skewer = self._slot:FindFirstChild("Skewer")
	if placedStickId and not self._placedStickId and skewer then
		SoundController:PlaySound("Place", self._gratesPart)
	end
	self._placedStickId = placedStickId

	-- An emptied slot takes any wind-down with it, so the next skewer placed starts out seated.
	if not placedStickId then
		self._spinDown = nil
	end

	self:RefreshInteraction()
end

-- Lights the stove: LED green, knob turned. The charcoal is authored as neon, so Update just drives its
-- colour off the cook timer -- the glow fades in there rather than here.
function Grill:_setStoveOn()
	if self._led then
		self._led.Color = LED_ON_COLOR
	end

	if self._stoveLit then
		return
	end
	self._stoveLit = true

	if self._handle then
		Spr.target(self._handle, 0.7, 3, { CFrame = self:_handleRestCFrame() * HANDLE_ON_ROTATION })
	end
end

-- Kills the stove: LED red, knob back to rest. The charcoal isn't touched here -- there's no scheduled
-- end for the glow to have faded toward any more, so Update cools it down from wherever it was off the
-- _stoveOff stamp instead (the material stays neon throughout).
function Grill:_setStoveOff()
	if self._led then
		self._led.Color = LED_OFF_COLOR
	end

	-- The knob is only turned back when it's actually been turned. It's authored at rest, so the off look
	-- a fresh griller starts on is already on screen -- and springing it there anyway would pin it to a
	-- pose the drop-in hasn't carried the rest of the griller down to yet, leaving the knob in the air.
	if not self._stoveLit then
		return
	end
	self._stoveLit = false

	if self._handle then
		Spr.target(self._handle, 0.7, 3, { CFrame = self:_handleRestCFrame() })
	end
end

-- Puts the cooking bar up over the griller's CookingUIAttachment, marks where the bands meet, takes
-- down the authored fill geometry so Update can swap its X without flattening the rest of it, and wires
-- the Robux skip that rides on it.
function Grill:_showCookingUI()
	self:_hideCookingUI()

	local attachment = self._slot:FindFirstChild("CookingUIAttachment", true)
	if not attachment then
		return
	end

	local cookingUI = UI.CookingUI:Clone()

	-- The authored Border is the template for the band marks: one copy per boundary, parked at its
	-- fraction and never touched again. The bands are fractions of the bar rather than seconds, so they
	-- sit in the same places whatever's on the grill and however long it takes to cook.
	local border = cookingUI.Bar.Border
	local position = border.Position

	for index, boundary in CookStates.BOUNDARIES do
		local marker = if index == 1 then border else border:Clone()
		marker.Position = UDim2.new(boundary, position.X.Offset, position.Y.Scale, position.Y.Offset)
		marker.Parent = cookingUI.Bar
	end

	-- The countdown is written as markup, and RichText is off on an authored label until someone turns
	-- it on. Started hidden rather than blanked: Update is what decides whether there's a window left
	-- to count down to at all, and it doesn't run until the frame after this, so until then the label
	-- would be showing whatever it was authored with.
	cookingUI.Timer.RichText = true
	cookingUI.Timer.Visible = false

	-- Left to RefreshInteraction below, so the bar's first frame doesn't show a visitor an offer that's
	-- the owner's alone.
	cookingUI.SkipCooking.Visible = false

	-- In PlayerGui adorned back onto the griller rather than parented to the attachment, because that's
	-- what makes the skip clickable. Adorned to the part the attachment hangs on rather than to the
	-- attachment itself: an Attachment adornee costs a billboard's buttons every tap on touch (the press
	-- lands, the release doesn't) -- the same thing that used to eat the NPC offer buttons. The offset the
	-- attachment gave is carried in world space instead, measured off a griller that's anchored and never
	-- moves again.
	cookingUI.Adornee = attachment.Parent
	cookingUI.StudsOffsetWorldSpace = attachment.WorldPosition - attachment.Parent.Position
	-- Both scale with the adornee's size, so whatever the template authored them to did nothing against a
	-- sizeless Attachment and would start shifting the bar now that it's a part.
	cookingUI.ExtentsOffset = Vector3.zero
	cookingUI.ExtentsOffsetWorldSpace = Vector3.zero
	cookingUI.Active = true
	cookingUI.Parent = getScreenGui()

	self._cookingUICleaner:Add(cookingUI)

	-- Answered on the release like every other button in the game: the griller is anchored, so unlike the
	-- NPC's billboard this one can't drift out from under a finger mid-tap.
	self._cookingUICleaner:Add(UIController:BindButtonClick(cookingUI.SkipCooking, function()
		GrillerController = GrillerController or require(script.Parent)
		GrillerController:RequestSkipCook(self._uid)
	end, true).Disconnect)

	-- RefreshInteraction is event-driven and nothing about the griller changes as the reveal delay runs
	-- out, so the wait brings it back through there itself. On the bar's own cleaner, so a cook ended
	-- inside the delay cancels it -- and a mid-cook join, already past the mark, schedules nothing. The
	-- cook length isn't the gate here (that's RefreshInteraction's); it just keeps every short cook from
	-- scheduling a wake-up whose only job would be to decide the button still isn't due.
	local untilReveal = SKIP_REVEAL_DELAY - self:_elapsed()
	if self._cookTime >= SKIP_MIN_COOK_TIME and untilReveal > 0 then
		self._cookingUICleaner:Add(task.delay(untilReveal, function()
			self:RefreshInteraction()
		end))
	end

	self._cookingUI = cookingUI
	self._cookingFillSize = cookingUI.Bar.BarContainer.Bar.Size
end

-- Drops the cooking bar. The bar lives in PlayerGui now rather than on the griller, so this is the only
-- thing that takes it down -- nothing on the grill streaming out carries it away any more. Grill:Destroy
-- calls this, and GrillerController tears the class down as the griller goes.
function Grill:_hideCookingUI()
	self._cookingUICleaner:Clean()
	self._cookingUI = nil

	-- Cleared so the next cook paints its title on the first frame rather than assuming it's still
	-- showing the band it left off on, and solves its own window rather than counting down to the
	-- one the last cook was heading for.
	self._cookingState = nil
	self._perfectStartsAt = nil
	self._perfectEndsAt = nil
end

-- Mounts the cooking particles on the grate and switches them on for the length of the cook.
--
-- Which set it mounts is the grill's own, off its CookEffect and so per model rather than per category:
-- this is the one thing about a cook that's meant to differ between two grillers rather than between a
-- griller and a stand -- the Electric Grill arcs and smokes where the rest sizzle. Every grill that
-- names none falls back on Default, so giving one its own effect is a folder in
-- Assets.Particles.Cooking and a CookEffect naming it, and nothing else.
function Grill:_showCookParticles()
	-- Drops anything still fading out from the last cook, and cancels its pending teardown.
	self._particleCleaner:Clean()

	if not self._gratesPart then
		return
	end

	-- Named by the config rather than taken off the grill's id, so the folder and the model needn't share
	-- a name.
	local effectName = (self._structure and self._structure.CookEffect) or COOK_PARTICLE_DEFAULT

	local folder = Particles.Cooking:FindFirstChild(effectName)
		or Particles.Cooking:FindFirstChild(COOK_PARTICLE_DEFAULT)

	-- Found rather than indexed, and warned rather than thrown: a grill with no effect authored for it
	-- should still cook. This is the same call that lights the stove and starts the bar, so erroring here
	-- would take the whole cook down over a missing folder.
	if not folder then
		warn(`[Grill] Assets.Particles.Cooking has no {effectName} or {COOK_PARTICLE_DEFAULT} folder`)
		return
	end

	local effect = EffectUtil.ParentEffectFolder(folder, self._gratesPart)
	for _, particle in effect.Particles do
		particle.Enabled = true
	end

	self._cookEffect = effect
	self._particleCleaner:Add(effect.Cleanup)
end

-- Switches the cooking particles off and drops them once what's already in the air has burned down, so the
-- smoke thins out rather than vanishing mid-frame.
function Grill:_hideCookParticles()
	local effect = self._cookEffect
	if not effect then
		return
	end
	self._cookEffect = nil

	local lifetime = 0
	for _, particle in effect.Particles do
		particle.Enabled = false
		lifetime = math.max(lifetime, particle.Lifetime.Max)
	end

	self._particleCleaner:Add(task.delay(lifetime + PARTICLE_CLEANUP_PADDING, effect.Cleanup))
end

-- Starts the sizzle on the grate for the length of the cook, easing it up so lighting the stove doesn't
-- crack in at full volume. Every client runs this off the slot's attributes, so anyone stood by the grill
-- hears it.
--
-- A grill carrying a CookSound gets that laid over the sizzle rather than in place of it, so it still
-- reads as a grill and the extra layer is what makes it read as its own kind of grill -- the Electric one
-- hums over the top of the same sizzle everything else has. Both layers ride the same fades, so they ramp
-- up and back out together instead of one cracking in underneath the other, and the cleaner below holds
-- both stoppers so one clean ends the pair.
function Grill:_startCookSound()
	-- Drops anything still fading out from the last cook.
	self:_stopCookSound()

	if not self._gratesPart then
		return
	end

	local sounds = { COOK_SOUND }

	local extra = self._structure and self._structure.CookSound
	if extra then
		table.insert(sounds, extra)
	end

	for _, soundName in sounds do
		local stop = SoundController:PlayLoopedSound(soundName, self._gratesPart, COOK_SOUND_FADE_IN, COOK_SOUND_FADE_OUT)
		if stop then
			self._soundCleaner:Add(stop)
		end
	end
end

-- Eases the sizzle back out and drops it: the cleaner is holding every stopper the controller handed
-- back, so cleaning it is what runs the fade -- on both layers at once where the grill carries two.
function Grill:_stopCookSound()
	self._soundCleaner:Clean()
end

-- Rings one burst of the alarm on the grate. Looped so a short clip fills the burst rather than ringing
-- once, and cut off after ALARM_DURATION with a short fade so it ends instead of clicking dead.
function Grill:_playAlarm()
	self._alarmCleaner:Clean()

	if not self._gratesPart then
		return
	end

	local stop = SoundController:PlayLoopedSound(ALARM_SOUND, self._gratesPart, ALARM_FADE_IN, ALARM_FADE_OUT)
	if not stop then
		return
	end

	-- Held so a cook ending mid-burst silences it. The delay drops it out of the cleaner as it stops, so
	-- a burst that already rang out isn't faded a second time by the next Clean.
	self._alarmCleaner:Add(stop)
	self._alarmCleaner:Add(task.delay(ALARM_DURATION, function()
		self._alarmCleaner:Remove(stop)
	end))
end

-- Silences whatever's ringing and takes the schedule down with it, so the next cook starts from quiet.
function Grill:_stopAlarm()
	self._alarmNextAt = nil
	self._alarmCleaner:Clean()
end

-- Per-frame while cooking: spins the skewer, glows the charcoal, browns its ingredient colours and then
-- chars them, swaps in the cooked material on the way, and fills the cooking bar. All local writes to the
-- anchored, server-owned model, so they never fight the server. Everything derives from the elapsed time, so
-- a rebuilt model self-corrects and every client renders the same thing.
function Grill:Update()
	if not self._attachment then
		return
	end

	-- Wind-down after a stopped cook: keep turning from where the cook left off, on the closed form in
	-- _spinDownAngle. The server may have swapped the settled model in underneath, and pivoting whatever
	-- is on the grate every frame is what bridges that swap.
	if not self._cooking then
		-- The glow keeps cooling on its own clock rather than the spin's, since an emptied slot drops the
		-- wind-down (below) while the charcoal still has heat left in it.
		local stoveOff = self._stoveOff
		if stoveOff then
			local cool = math.clamp((os.clock() - stoveOff.StartClock) / CHARCOAL_FADE_TIME, 0, 1)
			cool = cool * cool * (3 - 2 * cool) -- smoothstep, so it eases out rather than ramping flat

			for _, charcoal in self._charcoals do
				charcoal.Part.Color = charcoal.CoolFrom:Lerp(CHARCOAL_OFF_COLOR, cool)
			end

			if cool >= 1 then
				self._stoveOff = nil
			end
		end

		if self._spinDown then
			local model = self._skewerModel
			local angle, finished = self:_spinDownAngle()

			-- The landing is a whole turn on from where the cook left off, so resting the skewer on the
			-- seated pose is the same orientation it was just drawn at rather than a snap back to it.
			if finished then
				self._spinDown = nil
				if model and model.Parent then
					model:PivotTo(self:_seatedCFrame())
				end
			elseif model and model.Parent then
				model:PivotTo(self:_seatedCFrame() * CFrame.Angles(0, angle, 0))
			end
		end
		return
	end

	local model = self._skewerModel
	if not model or not model.Parent then
		return
	end

	-- Spin the skewer as a closed-form function of elapsed: eased up from a standstill over the first
	-- SPIN_RAMP_TIME so it accelerates like a motor, then turning at a steady speed until the stop edge
	-- hands off to the wind-down above. Deriving it from the synced clock keeps it framerate-proof and
	-- consistent across every client.
	--
	-- Ahead of the stamp check below, and deliberately not gated by it: whatever skewer is on the grate
	-- turns for as long as this client believes a cook is running. The server rebuilds the model on a
	-- record write and seats it square, so a frame this skipped would draw it at the seated orientation
	-- and pop -- and the model it'd be skipping for is the one the player is looking at. If it does turn
	-- out to be a fresh BBQ rather than the one on the heat, the stop edge's wind-down settles it a frame
	-- later, which is continuous where the pop isn't.
	model:PivotTo(self:_seatedCFrame() * CFrame.Angles(0, self:_spinAngleNow(), 0))

	-- The server stamps every skewer it puts down with the cook it belongs to, and leaves the stamp off a
	-- settled or freshly-placed one. A model that isn't carrying the cook we're holding isn't the skewer on
	-- the heat -- a new BBQ set down before the attributes that clear the last cook have landed is exactly
	-- that -- so none of the render below runs against it, the alarm included. Nothing is lost by waiting:
	-- the slot's ChildAdded brings the real one in and rebuilds its parts, and every line below derives
	-- from the cook's own clock, so the frame it starts on draws the same thing it would have.
	if not self._cookStartedAt or model:GetAttribute("CookStartedAt") ~= self._cookStartedAt then
		return
	end

	-- Read rather than floored. The 1e-3 the spin divides by is fine for an angle, but here it would put
	-- every frame of a cook stamped without a CookTime past the end of the bar -- and ring for it.
	local cookTime = self._cookTime
	if not cookTime or cookTime <= 0 then
		return
	end

	-- Warped once, here, rather than at each of the things that read it. Everything below hangs off this
	-- one local -- the bar's fill, the state it resolves to, the browning, the charring past the end -- so
	-- a cook that was stamped with a widened window slows down as one piece rather than having its bar
	-- creep while the food carries on at the old rate. A cook resumed from an earlier pull enters part-way
	-- along the same way, so the bar opens where it left off with the food already that far browned.
	--
	-- An unstable grill bends it the same way and the same one-piece rule applies: the bar lurches and
	-- the food browns and chars in the same lurches, so the grate always agrees with the bar over it.
	--
	-- The stove and the spin are the two things that deliberately don't read this: they're the grill
	-- starting up rather than the food cooking, so they ramp from a standstill on every light no matter
	-- how far along the skewer on it already is -- and on an unstable grill they turn steadily while the
	-- bar wobbles, since it's the heat that's unreliable and not the motor. The spin especially has to
	-- stay off it: the wind-down in _sync sizes its hold off a steady SPIN_SPEED so the skewer lands on a
	-- whole turn and the server's model swap never shows, and a wobbled angle breaks that outright --
	-- which is also why the spin is rendered above this rather than below it.
	local elapsed = CookStates.GetBarElapsed(
		self:_elapsed(),
		cookTime,
		self._cookWindowStretch,
		self._cookProgress,
		self._cookInstability,
		self._cookInstabilityPhase
	)
	local progress = math.clamp(elapsed / cookTime, 0, 1)
	local overtime = elapsed - cookTime

	-- The browning runs raw -> cooked over the raw band and lands exactly on the raw -> cooked boundary,
	-- so the food looks done the moment the bar says it is, then holds that colour for the rest of the
	-- bar -- nothing on the bar burns any more. The charring is its own ramp past the end of it, driven
	-- by GetOvertimeColor off the seconds since the bar filled.
	local brown = math.clamp(progress / CookStates.RAW_END, 0, 1)

	-- Fade the charcoal glow in over the first CHARCOAL_FADE_TIME and hold it there. There's no finish to
	-- fade back out toward now the player picks the moment, so the cool-down is the wind-down's job.
	-- Off the raw seconds since the light rather than the bar above: the coals went out when the stove
	-- did, so a skewer resumed part-cooked still sets them alight from cold.
	local glow = math.clamp(self:_elapsed() / CHARCOAL_FADE_TIME, 0, 1)
	glow = glow * glow * (3 - 2 * glow) -- smoothstep, so the glow eases in rather than ramping flat
	for _, charcoal in self._charcoals do
		charcoal.Part.Color = CHARCOAL_OFF_COLOR:Lerp(charcoal.GlowColor, glow)
	end

	local cookingUI = self._cookingUI
	if cookingUI then
		-- Only the X scale is ours: the authored size carries the rest, so a fill inset in the place file
		-- stays inset. The band marks are static, so nothing else on the bar moves.
		local fill = cookingUI.Bar.BarContainer.Bar
		local fillSize = self._cookingFillSize
		fill.Size = UDim2.new(progress, fillSize.X.Offset, fillSize.Y.Scale, fillSize.Y.Offset)

		-- The title and the fill's colour only change on a band edge, so they're written there rather
		-- than every frame -- and on the bar they land on the same frame the fill crosses that band's
		-- mark, so all three are saying the same thing at once. Past the end of the bar the fill has
		-- nowhere left to go, so it sits full and the colour and title carry the warning -- along with
		-- the alarm below, for the one player who can act on it.
		local stateId = CookStates.GetStateFromCook(elapsed, cookTime)
		if stateId ~= self._cookingState then
			self._cookingState = stateId

			local state = CookStates.GetStateFromId(stateId)
			local title = cookingUI.Title

			-- Snapped rather than eased: the band colours are far enough apart that a lerp between them
			-- runs through olive and brown, so the bar would spend most of the cook reading as neither.
			fill.BackgroundColor3 = state.BarColor
			title.Text = state.Name

			-- Driven off the config's own list, so the states are only ever spelled out in one place.
			for _, cookState in CookStates.GetAllStates() do
				title[`{cookState.Id}Gradient`].Enabled = cookState.Id == stateId
			end
		end

		-- Where the perfect window opens and closes in real time. Solved once per cook rather than per
		-- frame: every stamp it derives from is fixed for the cook's whole run, and _sync drops these
		-- the moment one of them isn't. Both ends are inverted off the same map the bar above is drawn
		-- from, so the countdown reaching zero and the fill reaching the band mark are the same frame
		-- -- on a grill whose bar surges and stalls its way there just as much as on a steady one.
		if not self._perfectStartsAt then
			self._perfectStartsAt = self._cookStartedAt
				+ CookStates.GetElapsedForBar(
					CookStates.RAW_END * cookTime,
					cookTime,
					self._cookWindowStretch,
					self._cookProgress,
					self._cookInstability,
					self._cookInstabilityPhase
				)
			self._perfectEndsAt = self._cookStartedAt
				+ CookStates.GetElapsedForBar(
					CookStates.PERFECT_END * cookTime,
					cookTime,
					self._cookWindowStretch,
					self._cookProgress,
					self._cookInstability,
					self._cookInstabilityPhase
				)
		end

		-- Off the same synced clock _elapsed reads, so every client at the grill counts the same figure
		-- down. Written every frame, unlike the title above it: the band edges are the thing that only
		-- changes occasionally, and this is the thing that has to tick.
		local now = workspace:GetServerTimeNow()
		local timer = cookingUI.Timer

		if now < self._perfectEndsAt then
			-- "ends" slotted in after the word rather than made a second label, so "Perfect" stays in the
			-- same place on the line and only the sense of it changes as the window opens.
			local opening = now < self._perfectStartsAt
			local remaining = (if opening then self._perfectStartsAt else self._perfectEndsAt) - now
			local countdown = GuiUtil.ConvertSecondsToCountdown(remaining)

			timer.Visible = true
			timer.Text = `{GuiUtil.Colorize("Perfect", PERFECT_WORD_COLOR)}{if opening then "" else " ends"} in: {GuiUtil.Colorize(
				countdown,
				PERFECT_COUNTDOWN_COLOR
			)}`
		else
			-- Past the window there's nothing left to aim for -- the fill, the title, the badge and the
			-- alarm are all saying "get it off" by then, and a countdown to the burn would only be
			-- another way of saying it.
			timer.Visible = false
		end
	end

	-- Once the bar has nowhere left to go, ring the owner's alarm on the grill: a burst, a gap, and again
	-- for as long as the stove's left on. Only theirs -- a visitor stood by a full grill isn't the one who
	-- can do anything about it.
	if overtime >= 0 and self._ownerUserId == LocalPlayer.UserId then
		if not self._alarmNextAt or os.clock() >= self._alarmNextAt then
			-- Re-derived from now rather than advanced by the interval, so a hitch can't queue two bursts
			-- back to back.
			self._alarmNextAt = os.clock() + ALARM_DURATION + ALARM_INTERVAL
			self:_playAlarm()
		end
	end

	if not self._cookParts then
		return
	end

	-- Past the end of the bar the browning is long finished, so the char ramp takes over from the cooked
	-- colour outright. It lands exactly on each burnt state's own tinted colour as that state takes over
	-- -- the same colour StickModel paints the model the server rebuilds underneath -- so a stop there
	-- shows no seam.
	for _, part in self._cookParts do
		part.Part.Color = if overtime > 0
			then CookStates.GetOvertimeColor(part.ToColor, overtime)
			else part.FromColor:Lerp(part.ToColor, brown)
	end

	if not self._materialApplied and brown >= COOK_MATERIAL_PROGRESS then
		for _, part in self._cookParts do
			part.Part.Material = part.ToMaterial
			part.Part.MaterialVariant = part.ToVariant
		end
		self._materialApplied = true
	end
end

-- A Robux price as it goes on a label, reading "-" until the MarketplaceService lookup lands (or if it
-- failed), matching how ShopController:GetPrice reports one it couldn't get.
--
-- The skip button is only repainted when something about the griller changes, so a price that wasn't
-- cached yet when it went up would read "-" for as long as it stands. The lookup yields, so it goes on
-- its own thread and brings the whole griller back through RefreshInteraction once it lands. Each id is
-- asked for once rather than retried -- a failed lookup would otherwise spin here, since nothing caches
-- the failure.
-- @param id A Products or Gamepasses id -- ShopController resolves a price for either
function Grill:_robuxPriceText(id: string): string
	local price = ShopController:GetCachedPrice(id)

	if not price and not self._requestedPrices[id] then
		self._requestedPrices[id] = true

		task.spawn(function()
			ShopController:GetPrice(id)
			self:RefreshInteraction()
		end)
	end

	return `{GuiUtil.ROBUX_ICON}{price or "-"}`
end

-- Seats a see-through copy of the BBQ in hand where the real one would land, so the player can see what
-- they're about to put down before they put it down -- or takes the current one back down when there's
-- nothing to preview. Reads the two halves of that off the class rather than taking them as arguments,
-- since the prompt's own shown/hidden is what calls this half the time and RefreshInteraction the other.
-- Only rebuilt when what's in hand changes: a refresh that leaves the preview identical would otherwise
-- pop the model.
function Grill:_refreshGhost()
	local tool = if self._promptShown then self._ghostSource else nil

	if tool == self._ghostTool then
		return
	end

	self._ghostCleaner:Clean()
	self._ghostTool = tool

	if not tool then
		return
	end

	-- Built off the tool's own attributes through the same builder every other skewer visual goes
	-- through, so what's previewed is exactly the model the place would put down.
	local model = StickModel.BuildStickModel({
		StickId = tool:GetAttribute("StickId"),
		Ingredients = HttpService:JSONDecode(tool:GetAttribute("Ingredients")),
		Cooked = tool:GetAttribute("Cooked"),
		CookState = tool:GetAttribute("CookState"),
		Sauce = tool:GetAttribute("Sauce"),
		Mutation = tool:GetAttribute("Mutation"),
	})
	if not model then
		return
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			-- A floor rather than a set, so a part authored see-through isn't made more solid than the
			-- skewer it's standing in for.
			descendant.Transparency = math.max(descendant.Transparency, GHOST_TRANSPARENCY)
		elseif descendant:IsA("ParticleEmitter") then
			-- A sauce or a mutation hangs real emitters on every ingredient, and a preview throwing off
			-- sparks reads as a BBQ that's already down.
			descendant:Destroy()
		end
	end

	-- Anything but "Skewer": that's the name the slot's ChildAdded keys the server's real model on.
	model.Name = "GhostSkewer"
	model:PivotTo(self:_seatedCFrame())
	model.Parent = self._slot

	self._ghostCleaner:Add(model)
end

-- Puts the grill's prompts and cues up on grillers the local player owns and takes them down otherwise,
-- so visitors just see the result. Each prompt sits on the thing it acts on: the body offers the place,
-- the knob is the stove's own switch reading Cook or Stop Cooking, and the take rides on the skewer
-- that's being taken. The Robux skip comes through here too, but it's a button on the cooking bar rather
-- than a prompt, so all this decides for it is whether it's shown and what it costs.
function Grill:RefreshInteraction()
	if not self._attachment then
		return
	end

	-- Every cue below hangs off this, so a griller someone else built is scenery: no prompt, no
	-- highlight, nothing to walk into.
	local owned = self._ownerUserId == LocalPlayer.UserId
	local placed = self._slot:GetAttribute("PlacedStickId")
	local cooking = self._slot:GetAttribute("Cooking") == true
	local cooked = self._slot:GetAttribute("Cooked") == true

	GrillerController = GrillerController or require(script.Parent)

	-- What the slot is offering right now. A cook can only be stopped; a skewer sitting there raw can be
	-- lit or taken; one that's already been through the heat can only be taken (it can't cook twice).
	local canPlace = owned and placed == nil
	-- Holding a BBQ the grill would actually take is a stricter thing than the grate merely being free,
	-- and it's what the body's glow and the ghost preview both hang off -- neither has anything to say
	-- to someone stood there empty-handed. A cooked skewer can't go back on the heat.
	local heldSkewer = EquippedItem.GetSkewer()
	local canPlaceHeld = canPlace and heldSkewer ~= nil and heldSkewer:GetAttribute("Cooked") ~= true
	local canCook = owned and placed ~= nil and not cooking and not cooked
	local canStop = owned and cooking
	-- The take is the one of these that can be held off from outside. Gated here rather than on the prompt
	-- itself so the whole offer goes with it: the skewer's prompt and its outline both read this, so
	-- neither is left saying take me while the take is shut.
	local canTake = owned and placed ~= nil and not cooking and not GrillerController:IsTakeLocked()

	-- The take goes up first, ahead of everything else this decides. It's the only offer here that has to
	-- be built fresh rather than merely re-labelled -- the server rebuilds the skewer on every record write
	-- and the prompt goes down with it -- so it's the only one an error further down this function can cost
	-- outright. The place prompt and the knob's would still be standing from the refresh before; the take
	-- would simply never come back, on a griller whose other prompts all looked fine. Nothing below feeds
	-- it, so it costs nothing to settle it here.
	--
	-- The take rides on the skewer itself, so what's reached for is the thing that comes off. The model it
	-- was built on is what's tracked rather than the prompt alone -- otherwise a swap would leave a
	-- destroyed prompt standing in for one and the new skewer would go without.
	local takeModel = if canTake then self._skewerModel else nil

	if takeModel ~= self._takeSkewerModel then
		self._takeSkewerCleaner:Clean()
		self._takeSkewerPrompt = nil
		self._takeSkewerModel = takeModel

		-- Hung off a part rather than the model: the custom prompt UI adorns whatever the prompt is
		-- parented to, and a Model is no use to a BillboardGui. Same fallback the cooking bar uses, since
		-- not every stick model is authored with a PrimaryPart.
		local host = takeModel and (takeModel.PrimaryPart or takeModel:FindFirstChildWhichIsA("BasePart", true))

		if host then
			local prompt = Instance.new("ProximityPrompt")
			prompt.RequiresLineOfSight = false
			prompt.HoldDuration = GRILL_PROMPT_HOLD
			prompt.Style = Enum.ProximityPromptStyle.Custom
			prompt.MaxActivationDistance = GRILL_PROMPT_DISTANCE
			-- Its own button rather than the E the rest of the griller offers on -- see TAKE_PROMPT_KEY.
			-- The knob's Cook is up at the same time as this on a raw skewer, and one button only ever
			-- draws one prompt.
			prompt.KeyboardKeyCode = TAKE_PROMPT_KEY
			prompt.GamepadKeyCode = TAKE_PROMPT_GAMEPAD_KEY
			prompt.ActionText = "Take BBQ"
			prompt.Parent = host

			self._takeSkewerPrompt = prompt
			self._takeSkewerCleaner:Add(prompt)
			self._takeSkewerCleaner:Connect(prompt.Triggered, function()
				GrillerController = GrillerController or require(script.Parent)
				GrillerController:RequestToggle(self._uid)
			end)
		elseif takeModel then
			-- A skewer with nothing to hang the prompt on is a BBQ that can't be taken back off, and the
			-- only way off a grill is this prompt. Said out loud rather than skipped quietly, the way the
			-- constructor calls out a griller missing its attachment or its knob.
			warn(`[Griller] {self._slot.Name}'s skewer has no part to hang the take prompt on`)
		end
	end

	-- "Take this off" rides on the skewer itself rather than the grill, so it outlines the thing being
	-- claimed. Tied to that prompt being on screen rather than breathing for as long as there's something
	-- to claim: the prompt now sits on the skewer too, so the outline is what picks it out from behind the
	-- label. Off through the whole cook -- while it's on the heat there's nothing to claim, and the bar is
	-- already carrying the player's attention. Tagged after the prompt above is in, since the component
	-- resolves the prompt once as it starts and gives up if there isn't one. The server rebuilds this
	-- model on every record write, which is why the slot's ChildAdded brings us back here to re-tag it.
	if self._skewerModel then
		self._skewerModel:SetAttribute("HighlightColor", Highlights.CLAIM)
		if canTake then
			self._skewerModel:AddTag(PROMPT_HIGHLIGHT_TAG)
		else
			self._skewerModel:RemoveTag(PROMPT_HIGHLIGHT_TAG)
		end
	end

	-- TEMPORARY (take-prompt investigation) -- remove once the cooked-BBQ case is understood. Fires on the
	-- exact failure: the owner has a BBQ sat on the grate that isn't cooking, so a take should be on offer,
	-- and there's no prompt. Whichever of these reads wrong names the cause.
	if owned and placed ~= nil and not cooking and not self._takeSkewerPrompt then
		warn(
			`[Griller][take] {self._slot.Name} placed={placed} cooking={cooking} cooked={cooked} `
				.. `takeLocked={GrillerController:IsTakeLocked()} skewerModel={self._skewerModel and self._skewerModel:GetFullName()} `
				.. `takeModel={takeModel and takeModel:GetFullName()}`
		)
	end

	-- Prompt: up whenever the local player owns the base.
	if owned and not self._prompt then
		local promptAttachment = self._grillAttachment
		if promptAttachment then
			local prompt = Instance.new("ProximityPrompt")
			prompt.RequiresLineOfSight = false
			prompt.Style = Enum.ProximityPromptStyle.Custom
			prompt.MaxActivationDistance = GRILL_PROMPT_DISTANCE
			-- Fixed, unlike the verb this used to carry: the body only ever offers the place now.
			prompt.ActionText = "Place BBQ"
			prompt.Parent = promptAttachment

			self._prompt = prompt
			self._promptCleaner:Add(prompt)
			self._promptCleaner:Connect(prompt.Triggered, function()
				GrillerController = GrillerController or require(script.Parent)
				GrillerController:RequestToggle(self._uid)
			end)

			-- The ghost is this prompt's own picture of what pressing it would do, so it comes and goes
			-- with the label rather than with the eligibility behind it -- a see-through BBQ sat on every
			-- free grill across the base would just be clutter. Only the ghost from here, never the whole
			-- refresh: that writes Enabled, and the tutorial holds prompts shut by writing it straight back
			-- whenever something re-enables one, so the two would sit there flipping it at each other.
			self._promptCleaner:Connect(prompt.PromptShown, function()
				self._promptShown = true
				self:_refreshGhost()
			end)
			self._promptCleaner:Connect(prompt.PromptHidden, function()
				self._promptShown = false
				self:_refreshGhost()
			end)
		end
	elseif not owned and self._prompt then
		self._promptCleaner:Clean()
		self._prompt = nil
	end

	-- Place only. Taking belongs to the skewer, and stopping a cook to the knob and nowhere else: the
	-- knob's is the timing call that decides what the BBQ is worth, and a second way to make it on the
	-- grill body meant it could be taken from two places that look nothing alike. So the body offers the
	-- place while the grate is free, and is down the rest of the time.
	if self._prompt then
		self._prompt.Enabled = canPlace
		self._prompt.HoldDuration = GRILL_PROMPT_HOLD
	end

	-- The skip rides the cooking bar, which only exists while there's a cook to skip. Down for visitors:
	-- the bar is everyone's, the offer to buy the cook out is the owner's. And down through the beat that
	-- teaches the timing, which the tutorial holds (see GrillerController:SetSkipLocked). The last two are
	-- what it's worth offering on at all -- a cook short enough to just wait out never carries it, and one
	-- long enough only starts carrying it once the player has actually been stood there waiting. This isn't
	-- a second way to stop a cook -- it doesn't settle the BBQ on the player's timing, it buys the result
	-- outright, which is why it can sit on the bar while the knob keeps the timing call to itself.
	if self._cookingUI then
		local skip = self._cookingUI.SkipCooking
		local canSkip = owned
			and not GrillerController:IsSkipLocked()
			and self._cookTime >= SKIP_MIN_COOK_TIME
			and self:_elapsed() >= SKIP_REVEAL_DELAY

		skip.Visible = canSkip
		-- Only priced on a grill that's actually offering it: the lookup is a MarketplaceService round
		-- trip, and a visitor stood on a busy base has no use for the figure on any of them.
		if canSkip then
			skip.Price.Text = self:_robuxPriceText(SKIP_COOK_PRODUCT)
		end
	end

	-- Knob: the stove's switch, so it's up both while there's something to light and while there's a
	-- cook to stop. Keeping one prompt across both means the cook doesn't tear it down and rebuild it
	-- underneath a player who's standing at it.
	local knobEligible = canCook or canStop

	if knobEligible and not self._knobPrompt then
		-- The handle rather than the knob: the knob is a model, and both the prompt and its click want the
		-- part. It's also the capture that already carries the knob's own nil guard, so a griller whose
		-- template is missing one goes without the prompt rather than throwing here.
		if self._handle then
			-- Sits on the knob part itself -- it has no attachment of its own, and it's small enough that
			-- the prompt lands where the label needs to be. Keeps the slot prompt's key, which costs
			-- nothing: the place wants the grate free and this wants it occupied, so the two are never up
			-- together. The take is the one that had to move off E, since a raw skewer offers both at once.
			local prompt = Instance.new("ProximityPrompt")
			prompt.RequiresLineOfSight = false
			prompt.Style = Enum.ProximityPromptStyle.Custom
			prompt.MaxActivationDistance = KNOB_PROMPT_DISTANCE
			prompt.Parent = self._handle

			self._knobPrompt = prompt
			self._knobCleaner:Add(prompt)
			self._knobCleaner:Connect(prompt.Triggered, function()
				SoundController:PlaySound("KnobSwitch", self._handle)

				GrillerController = GrillerController or require(script.Parent)
				if self._slot:GetAttribute("Cooking") then
					GrillerController:RequestStopCook(self._uid)
				else
					GrillerController:RequestCook(self._uid)
				end
			end)
		end
	elseif not knobEligible and self._knobPrompt then
		self._knobCleaner:Clean()
		self._knobPrompt = nil
	end

	if self._knobPrompt then
		-- Asserted rather than left alone. This prompt's eligibility is its existence -- it's built and
		-- torn down off knobEligible and nothing here otherwise writes Enabled -- so without this, anything
		-- that forced it down stayed down forever. The tutorial does exactly that, holding both stop
		-- prompts shut through the raw band and handing them back by calling this.
		self._knobPrompt.Enabled = true
		self._knobPrompt.ActionText = if canStop then "Stop Cooking" else "Cook"
		self._knobPrompt.HoldDuration = if canStop then STOP_PROMPT_HOLD else KNOB_PROMPT_HOLD
	end

	-- Billboard over the knob calling out that it's ready to cook, which reads from any distance where
	-- the prompt only shows up close. PartFloat bobs the attachment itself so the label drifts; no spin,
	-- since a billboard faces the camera regardless. On its own cleaner rather than the prompt's, since
	-- the prompt now stays up through the cook to stop it and this label would be lying by then.
	if canCook and not self._knobUI and self._handle then
		local holder = UI.KnobUIAttachment:Clone()
		holder.Parent = self._handle
		holder:SetAttribute("CanSpin", false)
		holder:SetAttribute("HoverAmplitude", KNOB_UI_FLOAT_AMPLITUDE)
		holder:SetAttribute("HoverSpeed", KNOB_UI_FLOAT_SPEED)
		holder:AddTag("PartFloat")

		self._knobUI = holder
		self._knobUICleaner:Add(holder)
	elseif not canCook and self._knobUI then
		self._knobUICleaner:Clean()
		self._knobUI = nil
	end

	-- The knob breathes on the same condition its prompt goes up, so the glow and the prompt are never
	-- out of step -- which through a cook makes the glow the "turn me off" cue.
	if self._knob then
		self._knob:SetAttribute("HighlightColor", Highlights.OPERATE)
		if knobEligible then
			self._knob:AddTag(Highlights.TAG)
		else
			self._knob:RemoveTag(Highlights.TAG)
		end
	end

	-- The grill body carries the one cue that has nothing else to sit on: "put the raw skewer you're
	-- holding here", while the slot's free. It lives in the place file like the rest of the slot's parts,
	-- so a slot without one just goes without.
	if self._grillModel then
		self._grillModel:SetAttribute("HighlightColor", Highlights.PLACE)
		if canPlaceHeld then
			self._grillModel:AddTag(Highlights.TAG)
		else
			self._grillModel:RemoveTag(Highlights.TAG)
		end
	end

	-- What the ghost would preview, worked out here with the rest of what's on offer rather than in
	-- _refreshGhost -- which the prompt's own shown/hidden also calls, and which has no business
	-- deciding eligibility a second time. Shown only while that prompt is actually up.
	self._ghostSource = if canPlaceHeld then heldSkewer else nil
	self:_refreshGhost()
end

function Grill:Destroy()
	self:_hideCookingUI()

	-- The grill, knob and skewer are all the base's or the server's, not ours, so they outlive this
	-- class -- leave and they'd keep breathing with nothing driving them.
	if self._grillModel then
		self._grillModel:RemoveTag(Highlights.TAG)
	end
	if self._knob then
		self._knob:RemoveTag(Highlights.TAG)
	end
	if self._skewerModel then
		self._skewerModel:RemoveTag(PROMPT_HIGHLIGHT_TAG)
	end

	self._cleaner:Destroy()
	self = nil
end

return Grill
