-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
local GuiUtil = require(Shared.GuiUtil)

-- Controllers
local Controllers = script.Parent.Parent
local SoundController = require(Controllers.SoundController)
local ShopController = require(Controllers.ShopController)

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
-- Longer than the place/take hold on the same attachment, and for the opposite reason to the stop above:
-- this one opens a Robux purchase, so it's the one prompt on the grill worth making hard to brush past.
local SKIP_PROMPT_HOLD = 0.5
local SKIP_COOK_PRODUCT = "SkipCook" -- the Products entry the skip prompt is priced from and buys
local KNOB_UI_FLOAT_AMPLITUDE = 0.15 -- how far the knob billboard bobs, in studs
local KNOB_UI_FLOAT_SPEED = 3 -- how fast the bob cycles, in radians per second

-- Cook animation tuning.
local SPIN_SPEED = math.rad(120) -- how fast the skewer turns while cooking, once up to speed
local SPIN_RAMP_TIME = 1 -- seconds the spin eases up to speed at the start, and back down in the wind-down after a finish
local COOK_MATERIAL_PROGRESS = 0.8 -- how far through the raw -> cooked browning before the cooked material/variant shows
local PARTICLE_CLEANUP_PADDING = 0.5 -- extra seconds after the longest particle lifetime before the emitters are dropped

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
local CHARCOAL_ON_COLOR = Color3.fromRGB(255, 85, 0)
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

    The place/stop/take prompt and the cook knob only go up on grillers the local player owns, which
    the OwnerUserId attribute the base stamped on it is what says. A griller only exists while its
    owner does, so that never changes over one griller's life.
]]

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

	local knob = slot:FindFirstChild("Knob")
	local attachment = slot:FindFirstChild("StickAttachment")
	local grillModel = slot:FindFirstChild("GrillModel")
	local grate = grillModel and grillModel:FindFirstChild("Grate")

	local self = setmetatable({
		--
		_slot = slot,

		-- Which placed griller this is, and whose it is. Both are stamped on by the base before it tags
		-- the model, so they're set by the time this class is ever built, and a griller only exists
		-- while its owner does -- so ownership is fixed for the whole life of one of these.
		_uid = slot:GetAttribute(Structures.UID_ATTRIBUTE),
		_ownerUserId = slot:GetAttribute(Structures.OWNER_ATTRIBUTE),

		-- The skewer spins about the attachment where the server seated it; captured once, since a
		-- griller doesn't move again once it's been placed.
		_attachment = attachment,
		_baseCFrame = attachment and attachment.WorldCFrame,

		-- Stove parts, and their authored rest so turning the stove off can put them back. Captured
		-- before we ever touch them (the server no longer drives the stove).
		_knob = knob,
		_led = knob and knob:FindFirstChild("LED"),
		_handle = knob and knob:FindFirstChild("Handle"),
		_charcoal = slot:FindFirstChild("Charcoal"),
		_handleRestCFrame = nil,

		-- The grill body itself, which the place/claim cue adorns -- the slot holds the knob and the
		-- attachments too, so highlighting it would outline those as well.
		_grillModel = grillModel,

		-- The grate the skewer sits on: what the cook's particles mount to, and what its sounds play from,
		-- so they come off the grill itself rather than a point in space.
		_gratePart = grate and grate:FindFirstChild("Mesh"),

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

		-- The wind-down that plays the spin out after a stop: { StartClock, StartAngle, Hold }, and the
		-- charcoal's own cool-down from wherever its glow had got to: { StartClock, StartColor }.
		_spinDown = nil,
		_stoveOff = nil,

		-- The cooking bar shown on the slot while it cooks, the authored fill size Update only swaps the
		-- X of, and the last band it was painted for. Plus the floating "cook me" billboard shown on the
		-- knob while the skewer's waiting to be lit.
		_cookingUI = nil,
		_cookingFillSize = nil,
		_cookingState = nil,
		_knobUI = nil,

		-- The cooking particles mounted on the grate while a cook runs.
		_cookEffect = nil,

		-- When the next alarm burst is due, on the local clock. Nil until the bar fills.
		_alarmNextAt = nil,

		--
		_prompt = nil,
		_skipPrompt = nil,
		_knobPrompt = nil,
		_takeSkewerPrompt = nil,

		-- [id] = true for every Robux price this grill has already gone and asked for -- so a lookup that came back
		-- empty isn't tried again every time a sign is repainted.
		_requestedPrices = {},

		--
		_cleaner = cleaner,
		_promptCleaner = cleaner:Construct(Trove),
		_knobCleaner = cleaner:Construct(Trove),
		_knobUICleaner = cleaner:Construct(Trove),
		_takeSkewerCleaner = cleaner:Construct(Trove),
		_particleCleaner = cleaner:Construct(Trove),
		_soundCleaner = cleaner:Construct(Trove),
		_alarmCleaner = cleaner:Construct(Trove),
	}, Grill)

	self._handleRestCFrame = self._handle and self._handle.CFrame

	-- The prompt/knob and the spin all need the griller's parts. GrillerController waits on them before
	-- building this class, so reaching here without one means the structure's template is wrong.
	if not attachment then
		warn(`[Griller] {slot.Name} has no StickAttachment, its cook won't render`)
		return self
	end

	-- The server rebuilds the skewer model on a place/remove/stop, so follow it in and out.
	cleaner:Connect(slot.ChildAdded, function(child)
		if child.Name == "Skewer" then
			self._skewerModel = child
			if self._cooking then
				self._materialApplied = false
				self:_rebuildCookParts()
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
	if self._charcoal then
		self._charcoal.Color = CHARCOAL_OFF_COLOR
	end

	self:_setStoveOff()
	self:_sync()

	return self
end

-- Seconds since this cook started, off the synced server clock so every client agrees. Zero when
-- there's no cook stamped.
function Grill:_elapsed(): number
	if not self._cookStartedAt then
		return 0
	end

	return math.max(0, workspace:GetServerTimeNow() - self._cookStartedAt)
end

-- Current spin angle in radians past the seated orientation -- the closed form the cook's spin renders
-- from: eased up over the ramp, then SPIN_SPEED for as long as the cook's been running.
function Grill:_spinAngleNow(): number
	local cookTime = math.max(self._cookTime or 0, 1e-3)
	local ramp = math.min(SPIN_RAMP_TIME, cookTime / 2)
	return SPIN_SPEED * rampedSpinDistance(self:_elapsed(), ramp)
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
	-- them -- the wind-down continues from exactly this angle.
	local exitAngle
	if not cooking and self._cooking then
		exitAngle = self:_spinAngleNow()
	end

	self._cookStartedAt = self._slot:GetAttribute("CookStartedAt")
	self._cookTime = self._slot:GetAttribute("CookTime")
	self._cookWindowStretch = self._slot:GetAttribute("CookWindowStretch")
	self._cookProgress = self._slot:GetAttribute("CookProgress")

	if cooking and not self._cooking then
		self._cooking = true
		self._spinDown = nil
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
		self:_setStoveOff()
		self:_hideCookingUI()
		self:_hideCookParticles()
		self:_stopCookSound()
		self:_stopAlarm()

		-- The glow cools down from wherever it had actually got to. A cook stopped in its first seconds
		-- has barely lit, so starting the fade from full would flare it up before dimming it.
		if self._charcoal then
			self._stoveOff = { StartClock = os.clock(), StartColor = self._charcoal.Color }
		end

		-- The spin is client-authoritative, so rather than reconciling to wherever the server seated
		-- the rebuilt model (the old snap), Update keeps turning it from the captured angle: full speed
		-- until the landing lines up, then a motor-like ease-out that rests exactly on a whole turn --
		-- the seated orientation -- so the swap underneath never shows.
		local residual = (exitAngle + SPIN_SPEED * 0.5 * SPIN_RAMP_TIME) % (2 * math.pi)
		self._spinDown = {
			StartClock = os.clock(),
			StartAngle = exitAngle,
			Hold = ((2 * math.pi - residual) % (2 * math.pi)) / SPIN_SPEED,
		}
	end

	local placedStickId = self._slot:GetAttribute("PlacedStickId")

	-- A skewer arriving on an empty grate is the player setting one down; the take that clears it isn't.
	local skewer = self._slot:FindFirstChild("Skewer")
	if placedStickId and not self._placedStickId and skewer then
		SoundController:PlaySound("Place", self._gratePart)
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

	if self._handle and self._handleRestCFrame then
		Spr.target(self._handle, 0.7, 3, { CFrame = self._handleRestCFrame * HANDLE_ON_ROTATION })
	end
end

-- Kills the stove: LED red, knob back to rest. The charcoal isn't touched here -- there's no scheduled
-- end for the glow to have faded toward any more, so Update cools it down from wherever it was off the
-- _stoveOff stamp instead (the material stays neon throughout).
function Grill:_setStoveOff()
	if self._led then
		self._led.Color = LED_OFF_COLOR
	end

	if self._handle and self._handleRestCFrame then
		Spr.target(self._handle, 0.7, 3, { CFrame = self._handleRestCFrame })
	end
end

-- Puts the cooking bar up on the slot's TimerUIAttachment, marks where the bands meet, and takes down
-- the authored fill geometry so Update can swap its X without flattening the rest of it.
function Grill:_showCookingUI()
	self:_hideCookingUI()

	local attachment = self._slot:FindFirstChild("TimerUIAttachment")
	if not attachment then
		return
	end

	local cookingUI = UI.CookingUI:Clone()
	cookingUI.Parent = attachment

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

	self._cookingUI = cookingUI
	self._cookingFillSize = cookingUI.Bar.BarContainer.Bar.Size
end

-- Drops the cooking bar.
function Grill:_hideCookingUI()
	if self._cookingUI then
		self._cookingUI:Destroy()
		self._cookingUI = nil
	end

	-- Cleared so the next cook paints its title on the first frame rather than assuming it's still
	-- showing the band it left off on.
	self._cookingState = nil
end

-- Mounts the cooking particles on the grate and switches them on for the length of the cook.
function Grill:_showCookParticles()
	-- Drops anything still fading out from the last cook, and cancels its pending teardown.
	self._particleCleaner:Clean()

	if not self._gratePart then
		return
	end

	local effect = EffectUtil.ParentEffectFolder(Particles.Cooking, self._gratePart)
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
function Grill:_startCookSound()
	-- Drops anything still fading out from the last cook.
	self:_stopCookSound()

	if not self._gratePart then
		return
	end

	local stop = SoundController:PlayLoopedSound(COOK_SOUND, self._gratePart, COOK_SOUND_FADE_IN, COOK_SOUND_FADE_OUT)
	if stop then
		self._soundCleaner:Add(stop)
	end
end

-- Eases the sizzle back out and drops it: the cleaner is holding the stopper the controller handed back,
-- so cleaning it is what runs the fade.
function Grill:_stopCookSound()
	self._soundCleaner:Clean()
end

-- Rings one burst of the alarm on the grate. Looped so a short clip fills the burst rather than ringing
-- once, and cut off after ALARM_DURATION with a short fade so it ends instead of clicking dead.
function Grill:_playAlarm()
	self._alarmCleaner:Clean()

	if not self._gratePart then
		return
	end

	local stop = SoundController:PlayLoopedSound(ALARM_SOUND, self._gratePart, ALARM_FADE_IN, ALARM_FADE_OUT)
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
	if not self._baseCFrame then
		return
	end

	-- Wind-down after a stopped cook: keep turning from where the cook left off (the server has already
	-- swapped in the settled model underneath, and pivoting it every frame is what bridges that swap) --
	-- full speed through Hold, then the spin-up's smoothstep run in reverse over SPIN_RAMP_TIME. Hold is
	-- sized so the rest lands exactly on a whole turn, i.e. the seated orientation.
	if not self._cooking then
		-- The glow keeps cooling on its own clock rather than the spin's, since an emptied slot drops the
		-- wind-down (below) while the charcoal still has heat left in it.
		local stoveOff = self._stoveOff
		if stoveOff and self._charcoal then
			local cool = math.clamp((os.clock() - stoveOff.StartClock) / CHARCOAL_FADE_TIME, 0, 1)
			cool = cool * cool * (3 - 2 * cool) -- smoothstep, so it eases out rather than ramping flat
			self._charcoal.Color = stoveOff.StartColor:Lerp(CHARCOAL_OFF_COLOR, cool)

			if cool >= 1 then
				self._stoveOff = nil
			end
		end

		local spinDown = self._spinDown
		if spinDown then
			local model = self._skewerModel
			local u = os.clock() - spinDown.StartClock
			if u >= spinDown.Hold + SPIN_RAMP_TIME then
				self._spinDown = nil
				if model and model.Parent then
					model:PivotTo(self._baseCFrame)
				end
			elseif model and model.Parent then
				local distance = u -- full-speed seconds covered so far
				if u > spinDown.Hold then
					local y = (spinDown.Hold + SPIN_RAMP_TIME - u) / SPIN_RAMP_TIME
					distance = spinDown.Hold + 0.5 * SPIN_RAMP_TIME - SPIN_RAMP_TIME * (y ^ 3 - 0.5 * y ^ 4)
				end
				model:PivotTo(self._baseCFrame * CFrame.Angles(0, spinDown.StartAngle + SPIN_SPEED * distance, 0))
			end
		end
		return
	end

	local model = self._skewerModel
	if not model or not model.Parent then
		return
	end

	local cookTime = math.max(self._cookTime or 0, 1e-3)

	-- Warped once, here, rather than at each of the things that read it. Everything below hangs off this
	-- one local -- the bar's fill, the state it resolves to, the browning, the charring past the end -- so
	-- a cook that was stamped with a widened window slows down as one piece rather than having its bar
	-- creep while the food carries on at the old rate. A cook resumed from an earlier pull enters part-way
	-- along the same way, so the bar opens where it left off with the food already that far browned.
	--
	-- The stove and the spin are the two things that deliberately don't read this: they're the grill
	-- starting up rather than the food cooking, so they ramp from a standstill on every light no matter
	-- how far along the skewer on it already is.
	local elapsed = CookStates.GetBarElapsed(self:_elapsed(), cookTime, self._cookWindowStretch, self._cookProgress)
	local progress = math.clamp(elapsed / cookTime, 0, 1)
	local overtime = elapsed - cookTime

	-- The browning runs raw -> cooked over the raw band and lands exactly on the raw -> cooked boundary,
	-- so the food looks done the moment the bar says it is, then holds that colour for the rest of the
	-- bar -- nothing on the bar burns any more. The charring is its own ramp past the end of it, driven
	-- by GetOvertimeColor off the seconds since the bar filled.
	local brown = math.clamp(progress / CookStates.RAW_END, 0, 1)

	-- Spin the skewer as a closed-form function of elapsed: eased up from a standstill over the first
	-- SPIN_RAMP_TIME so it accelerates like a motor, then turning at a steady speed until the stop edge
	-- hands off to the wind-down above. Deriving it from the synced clock keeps it framerate-proof and
	-- consistent across every client.
	model:PivotTo(self._baseCFrame * CFrame.Angles(0, self:_spinAngleNow(), 0))

	-- Fade the charcoal glow in over the first CHARCOAL_FADE_TIME and hold it there. There's no finish to
	-- fade back out toward now the player picks the moment, so the cool-down is the wind-down's job.
	-- Off the raw seconds since the light rather than the bar above: the coals went out when the stove
	-- did, so a skewer resumed part-cooked still sets them alight from cold.
	if self._charcoal then
		local glow = math.clamp(self:_elapsed() / CHARCOAL_FADE_TIME, 0, 1)
		glow = glow * glow * (3 - 2 * glow) -- smoothstep, so the glow eases in rather than ramping flat
		self._charcoal.Color = CHARCOAL_OFF_COLOR:Lerp(CHARCOAL_ON_COLOR, glow)
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

-- A Robux price as it goes on a prompt, reading "-" until the MarketplaceService lookup lands (or if it
-- failed), matching how ShopController:GetPrice reports one it couldn't get.
--
-- The skip prompt is only repainted when something about the griller changes, so a price that wasn't
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

-- Puts the grill's prompts and cues up on grillers the local player owns and takes them down otherwise,
-- so visitors just see the result. The grill prompt carries whichever verb it's actually offering --
-- place it, stop the cook, take it back off; the knob is the stove's own switch, reading Cook or Stop
-- Cooking; and the skewer wears its own take prompt so the two aren't both reaching for the same one.
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
	local canCook = owned and placed ~= nil and not cooking and not cooked
	local canStop = owned and cooking
	-- The take is the one of these that can be held off from outside. Gated here rather than on the
	-- prompts themselves so the whole offer goes with it: both attachments' prompts and the skewer's own
	-- glow all read this, so none of them is left saying take me while the take is shut.
	local canTake = owned and placed ~= nil and not cooking and not GrillerController:IsTakeLocked()

	-- Prompt: up whenever the local player owns the base.
	if owned and not self._prompt then
		local promptAttachment = self._slot:FindFirstChild("GrillPromptAttachment")
		if promptAttachment then
			local prompt = Instance.new("ProximityPrompt")
			prompt.RequiresLineOfSight = false
			prompt.Style = Enum.ProximityPromptStyle.Custom
			prompt.MaxActivationDistance = GRILL_PROMPT_DISTANCE
			prompt.Parent = promptAttachment

			self._prompt = prompt
			self._promptCleaner:Add(prompt)
			self._promptCleaner:Connect(prompt.Triggered, function()
				GrillerController = GrillerController or require(script.Parent)
				GrillerController:RequestToggle(self._uid)
			end)

			-- The skip shares this attachment and this cleaner: the two are never up at the same time (one
			-- offers the grill while it's idle, the other while it's cooking) and they come and go with the
			-- same ownership, so they're built and dropped together.
			local skipPrompt = Instance.new("ProximityPrompt")
			skipPrompt.RequiresLineOfSight = false
			skipPrompt.Style = Enum.ProximityPromptStyle.Custom
			skipPrompt.MaxActivationDistance = GRILL_PROMPT_DISTANCE
			skipPrompt.ActionText = "Skip Cooking"
			skipPrompt.Parent = promptAttachment

			self._skipPrompt = skipPrompt
			self._promptCleaner:Add(skipPrompt)
			self._promptCleaner:Connect(skipPrompt.Triggered, function()
				GrillerController = GrillerController or require(script.Parent)
				GrillerController:RequestSkipCook(self._uid)
			end)
		end
	elseif not owned and self._prompt then
		self._promptCleaner:Clean()
		self._prompt = nil
		self._skipPrompt = nil
	end

	-- Place and take only. Stopping a cook belongs to the knob and nowhere else: it's the stove's switch,
	-- and a second way to do it on the grill body meant the timing call that decides what the BBQ is worth
	-- could be taken from two places that look nothing alike. The prompt is simply down for the length of
	-- a cook.
	if self._prompt then
		self._prompt.Enabled = canPlace or canTake
		self._prompt.HoldDuration = GRILL_PROMPT_HOLD

		-- Only a skewer ever goes on a grill -- a bare stick has nothing to cook. Once it's off the heat
		-- the take reads the same whether it came off raw, cooked or burnt: it's the same action, and the
		-- bar has already said which one they got.
		self._prompt.ActionText = if canPlace then "Place BBQ" else "Take BBQ"
	end

	-- The one thing the grill body offers through a cook, which is exactly the stretch the prompt above is
	-- down for -- so the attachment is never showing two at once. This isn't a second way to stop a cook:
	-- it doesn't settle the BBQ on the player's timing, it buys the result outright, which is why it can
	-- live on the body while the knob keeps the timing call to itself.
	if self._skipPrompt then
		self._skipPrompt.Enabled = canStop
		self._skipPrompt.HoldDuration = SKIP_PROMPT_HOLD
		self._skipPrompt.ObjectText = self:_robuxPriceText(SKIP_COOK_PRODUCT)
	end

	-- Knob: the stove's switch, so it's up both while there's something to light and while there's a
	-- cook to stop. Keeping one prompt across both means the cook doesn't tear it down and rebuild it
	-- underneath a player who's standing at it.
	local knobEligible = canCook or canStop

	if knobEligible and not self._knobPrompt then
		if self._knob then
			-- Sits on the knob part itself -- it has no attachment of its own, and it's small enough that
			-- the prompt lands where the label needs to be. Shares the slot prompt's key, so Roblox shows
			-- whichever of the two you're standing nearer to.
			local prompt = Instance.new("ProximityPrompt")
			prompt.RequiresLineOfSight = false
			prompt.Style = Enum.ProximityPromptStyle.Custom
			prompt.MaxActivationDistance = KNOB_PROMPT_DISTANCE
			prompt.Parent = self._knob.Handle

			self._knobPrompt = prompt
			self._knobCleaner:Add(prompt)
			self._knobCleaner:Connect(prompt.Triggered, function()
				SoundController:PlaySound("KnobSwitch", self._knob.Handle)

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

	-- The skewer wears its own take prompt on its own attachment, so reaching for the one on the skewer
	-- and the one on the grill body both work. Shares the grill prompt's key, so Roblox shows whichever
	-- you're nearer to.
	if canTake and not self._takeSkewerPrompt then
		local takeAttachment = self._slot:FindFirstChild("TakeSkewerAttachment")
		if takeAttachment then
			local prompt = Instance.new("ProximityPrompt")
			prompt.RequiresLineOfSight = false
			prompt.HoldDuration = GRILL_PROMPT_HOLD
			prompt.Style = Enum.ProximityPromptStyle.Custom
			prompt.MaxActivationDistance = GRILL_PROMPT_DISTANCE
			prompt.ActionText = "Take BBQ"
			prompt.Parent = takeAttachment

			self._takeSkewerPrompt = prompt
			self._takeSkewerCleaner:Add(prompt)
			self._takeSkewerCleaner:Connect(prompt.Triggered, function()
				GrillerController = GrillerController or require(script.Parent)
				GrillerController:RequestToggle(self._uid)
			end)
		end
	elseif not canTake and self._takeSkewerPrompt then
		self._takeSkewerCleaner:Clean()
		self._takeSkewerPrompt = nil
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
		local skewer = EquippedItem.GetSkewer()
		local canPlaceHeld = canPlace and skewer ~= nil and skewer:GetAttribute("Cooked") ~= true

		self._grillModel:SetAttribute("HighlightColor", Highlights.PLACE)
		if canPlaceHeld then
			self._grillModel:AddTag(Highlights.TAG)
		else
			self._grillModel:RemoveTag(Highlights.TAG)
		end
	end

	-- "Take this off" rides on the skewer itself rather than the grill, so it outlines the thing being
	-- claimed. Off through the whole cook -- while it's on the heat there's nothing to claim, and the bar
	-- is already carrying the player's attention. The server rebuilds this model on every record write,
	-- which is why the slot's ChildAdded brings us back here to re-tag the new one.
	if self._skewerModel then
		self._skewerModel:SetAttribute("HighlightColor", Highlights.CLAIM)
		if canTake then
			self._skewerModel:AddTag(Highlights.TAG)
		else
			self._skewerModel:RemoveTag(Highlights.TAG)
		end
	end
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
		self._skewerModel:RemoveTag(Highlights.TAG)
	end

	self._cleaner:Destroy()
	self = nil
end

return Grill
