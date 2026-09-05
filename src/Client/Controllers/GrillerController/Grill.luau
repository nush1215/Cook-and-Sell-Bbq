-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

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

local GRILL_PROMPT_DISTANCE = 15
local GRILL_PROMPT_HOLD = 0.3
-- Matches the place, so a player watching the bar from where they can see it can still call the stop.
local TAKE_PROMPT_DISTANCE = 15
-- The same E as every other prompt -- OnePerButton means standing close to the skewer wins it
local TAKE_PROMPT_KEY = Enum.KeyCode.E
local TAKE_PROMPT_GAMEPAD_KEY = Enum.KeyCode.ButtonY
local SKIP_COOK_PRODUCT = "SkipCook" -- the Products entry the skip button is priced from and buys
-- A short cook isn't worth buying out of, and an instant offer reads as a shakedown
local SKIP_MIN_COOK_TIME = 10 -- seconds of bar below which the skip is never offered
local SKIP_REVEAL_DELAY = 5 -- seconds into a cook before it is
-- Matches the PromptSubjectHighlight component's file name, which is what it registers under.
local PROMPT_HIGHLIGHT_TAG = "PromptSubjectHighlight"
local GHOST_TRANSPARENCY = 0.3 -- same figure the build ghost uses, so ghosting reads alike everywhere

-- Cook animation tuning.
local SPIN_SPEED = math.rad(120) -- how fast the skewer turns while cooking, once up to speed
local SPIN_RAMP_TIME = 1 -- seconds the spin eases up to speed, and back down in the wind-down after a finish
local COOK_MATERIAL_PROGRESS = 0.8 -- how far through the raw -> cooked browning before the cooked material shows
-- The word in emphasis gold, the figure in the Perfect band's own colour, matching the fill
local PERFECT_WORD_COLOR = Color3.fromRGB(255, 212, 0)
local PERFECT_COUNTDOWN_COLOR = CookStates.GetStateFromId("Perfect").BarColor
-- Bounds how far the live prediction may swing off the true remaining, so the number stays aimable
local TIMER_SWING = 1.5
-- Floor under the rate prediction divides by, so a deep stall isn't a divide running away
local MIN_BAR_RATE = 0.05
local PARTICLE_CLEANUP_PADDING = 0.5 -- extra seconds past the longest particle lifetime before dropping emitters
-- Fallback for a griller with no folder of its own under Assets.Particles.Cooking. See _showCookParticles.
local COOK_PARTICLE_DEFAULT = "Default"

-- The looped sizzle a cooking grill carries, faded so a cook starting or ending doesn't crack in or cut dead.
local COOK_SOUND = "GrillCooking"
local COOK_SOUND_FADE_IN = 0.5
local COOK_SOUND_FADE_OUT = 1

-- Rung on the owner's grill once the bar fills, since a player who walked off has no other cue
local ALARM_SOUND = "Alarm"
local ALARM_DURATION = 5 -- seconds each burst rings for
local ALARM_INTERVAL = 2 -- seconds of silence between bursts
local ALARM_FADE_IN = 0 -- an alarm should crack in on the beat rather than ramp
local ALARM_FADE_OUT = 0.15 -- just enough that cutting the burst short doesn't click

-- Rung on the frame the bar enters the perfect window, which the recolour alone is easy to miss
local PERFECT_SOUND = "PerfectlyCookedChime"

-- Stove visuals: the charcoal glow.
local CHARCOAL_OFF_COLOR = Color3.fromRGB(25, 12, 7)
-- Per-part override, so a grill can burn its own colour without a code change.
local CHARCOAL_GLOW_ATTRIBUTE = "GlowColor"
local CHARCOAL_DEFAULT_GLOW = Color3.fromRGB(255, 85, 0)
local CHARCOAL_FADE_TIME = 3 -- seconds the glow fades in at the start of a cook and back out at the end

-- Required lazily to break the cycle: GrillerController requires this class.
local GrillerController

-- Renders one placed griller: spins and browns the server-cloned skewer and lights the coals, all derived from the cook attributes so every client agrees.

-- The billboards' ScreenGui. In PlayerGui adorned back onto the griller, which is what makes the skip clickable.
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

-- How far the spin has turned by `elapsed`, in full-speed seconds. Only ever accelerates.
local function rampedSpinDistance(elapsed: number, ramp: number): number
	local t = math.max(elapsed, 0)
	if t <= ramp then
		local x = t / ramp
		return ramp * (x ^ 3 - 0.5 * x ^ 4)
	end

	return 0.5 * ramp + (t - ramp)
end

-- Keys a part by mesh, not name -- the raw and cooked models share meshes but rename their parts.
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
	local cleaner = Trove.new()

	-- Searched recursively, since the grill body gets re-nested as it's re-authored
	local attachment = slot:FindFirstChild("StickAttachment", true)
	local grillAttachment = slot:FindFirstChild("GrillAttachment", true)
	local grillModel = slot:FindFirstChild("Grill")

	-- Glow read once here, not per frame -- nothing writes it at runtime and these lerp every frame
	local charcoals = {}
	for _, descendant in slot:GetDescendants() do
		if descendant.Name == "Charcoal" and descendant:IsA("BasePart") then
			table.insert(charcoals, {
				Part = descendant,
				GlowColor = descendant:GetAttribute(CHARCOAL_GLOW_ATTRIBUTE) or CHARCOAL_DEFAULT_GLOW,
				-- Where the glow was when the stove went off, so the cool-down doesn't flare to full first
				CoolFrom = nil,
			})
		end
	end

	local self = setmetatable({
		_slot = slot,

		-- Stamped on by the base before it tags the model, and fixed for the griller's whole life.
		_uid = slot:GetAttribute(Structures.UID_ATTRIBUTE),
		_ownerUserId = slot:GetAttribute(Structures.OWNER_ATTRIBUTE),

		-- Resolved once -- a placed structure never changes. Nil for a model the config has since dropped
		_structure = Structures.GetStructureFromId(slot:GetAttribute(Structures.TYPE_ATTRIBUTE)),

		-- An offset, not a world pose: the griller is still springing down when this is built
		_attachment = attachment,
		_seatOffset = attachment and slot:GetPivot():Inverse() * attachment.WorldCFrame,

		-- Where the place prompt hangs. The take isn't here -- it rides on the skewer itself.
		_grillAttachment = grillAttachment,

		_charcoals = charcoals,

		-- The body alone, not the whole griller: it carries the "put the skewer you're holding here" cue.
		_grillModel = grillModel,

		-- What the cook's particles mount to and its sounds play from.
		_gratesPart = slot:FindFirstChild("Grates", true),

		-- The server-cloned skewer, and the per-part raw -> cooked targets the colour lerp drives.
		_skewerModel = slot:FindFirstChild("Skewer"),
		_cookParts = nil,
		_materialApplied = false,

		_cooking = false,
		_cookStartedAt = nil,
		_cookTime = nil,

		-- Lets _sync tell a placement from a take. Seeded from the slot so a loaded grill doesn't ring on join
		_placedStickId = slot:GetAttribute("PlacedStickId"),

		-- Wind-down after a stop, the angle a re-light carries in, and the coals' cool-down
		_spinDown = nil,
		_spinCarry = nil,
		_stoveOff = nil,

		-- The bar, the authored fill size Update only swaps the X of, and the band it was last painted for
		_cookingUI = nil,
		_cookingFillSize = nil,
		_cookingState = nil,

		-- The window on the synced clock, solved on the bar's first frame and dropped when a stamp moves
		_perfectStartsAt = nil,
		_perfectEndsAt = nil,

		_cookEffect = nil,

		-- When the next alarm burst is due, on the local clock. Nil until the bar fills.
		_alarmNextAt = nil,

		_prompt = nil,
		_takeSkewerPrompt = nil,
		_takeSkewerModel = nil, -- the skewer model the take prompt was built on, so a swap rebuilds it

		-- The ghost preview; _ghostTool records what it was built from so an unchanged refresh doesn't rebuild
		_ghostSource = nil,
		_promptShown = false,
		_ghostTool = nil,

		-- [id] = true per Robux price already asked for, so an empty lookup isn't retried on every repaint.
		_requestedPrices = {},

		_cleaner = cleaner,
		_promptCleaner = cleaner:Construct(Trove),
		_cookingUICleaner = cleaner:Construct(Trove),
		_takeSkewerCleaner = cleaner:Construct(Trove),
		_ghostCleaner = cleaner:Construct(Trove),
		_particleCleaner = cleaner:Construct(Trove),
		_soundCleaner = cleaner:Construct(Trove),
		_alarmCleaner = cleaner:Construct(Trove),
	}, Grill)

	-- The server streams a structure whole, so a missing attachment means the template is wrong, not late
	if not attachment then
		warn(`[Griller] {slot.Name} has no StickAttachment, its cook won't render`)
		return self
	end

	-- The server rebuilds the skewer model on a place/take, so follow it in and out.
	cleaner:Connect(slot.ChildAdded, function(child)
		if child.Name == "Skewer" then
			self._skewerModel = child
			if self._cooking then
				self._materialApplied = false
				self:_rebuildCookParts()
			end

			-- Re-seated off our own offset; skipped mid-cook and mid-wind-down, which drive the pose already
			if not self._cooking and not self._spinDown then
				child:PivotTo(self:_seatedCFrame())
			end

			-- The take prompt rides on this model, so a swap wipes it. Also covers the model landing late
			self:RefreshInteraction()
		end
	end)
	cleaner:Connect(slot.ChildRemoved, function(child)
		if child == self._skewerModel then
			self._skewerModel = nil
			self._cookParts = nil
		end
	end)

	-- The cook animation, the coals and the prompts all track these.
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

	-- Snapped dark rather than left to Update's cool-down, which fades from where a real cook got to
	for _, charcoal in self._charcoals do
		charcoal.Part.Color = CHARCOAL_OFF_COLOR
	end

	self:_sync()

	return self
end

-- The pose the griller belongs at, not the one it's in: a live pivot mid-drop sits high.
function Grill:_settledPivot(): CFrame
	return self._slot:GetAttribute("SlotCFrame") or self._slot:GetPivot()
end

-- Where a skewer sits when it's seated on this griller: the same pose the server pivots the real one to.
function Grill:_seatedCFrame(): CFrame
	return self:_settledPivot() * self._seatOffset
end

-- Seconds since this cook started, off the synced server clock. Zero when no cook is stamped.
function Grill:_elapsed(): number
	if not self._cookStartedAt then
		return 0
	end

	return math.max(0, workspace:GetServerTimeNow() - self._cookStartedAt)
end

-- Spin ramp-up time, capped at half the cook. The wind-down reads it too, so the two land together.
function Grill:_spinRamp(): number
	return math.min(SPIN_RAMP_TIME, math.max(self._cookTime or 0, 1e-3) / 2)
end

-- Current spin angle in radians past the seated orientation: eased up over the ramp, then SPIN_SPEED.
function Grill:_spinAngleNow(): number
	local ramp = self:_spinRamp()
	local angle = SPIN_SPEED * rampedSpinDistance(self:_elapsed(), ramp)

	-- A re-light carries the wind-down's offset in and bleeds it away, so the closed form recovers
	local carry = self._spinCarry
	if carry then
		local bleed = math.clamp((os.clock() - carry.StartClock) / ramp, 0, 1)
		angle += carry.Angle * (1 - bleed * bleed * (3 - 2 * bleed))
	end

	return angle
end

-- How far the wind-down has turned, and whether it's done. Hold is sized to land on a whole turn.
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

-- Pairs the skewer's parts to their cooked counterparts in three passes, each cooked part claimed once.
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

		-- Pass 1: same mesh and name. Pass 2: mesh alone, which catches the parts the cooked model renames.
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

		-- Pass 3: equal part counts means the leftovers line up by traversal order. Last resort.
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

		-- An asset problem: the Raw and Cooked models hold different geometry, so these stay raw.
		if unpaired > 0 then
			warn(
				`[Griller] {ingredient.Id}'s cooked model doesn't line up with its raw one, {unpaired} part(s) won't brown`
			)
		end
	end

	self._cookParts = parts
end

-- Reconciles against the slot's attributes: starts or stops the cook on a Cooking edge, refreshes prompts.
function Grill:_sync()
	local cooking = self._slot:GetAttribute("Cooking") == true

	-- Read before the lines below overwrite them, so the wind-down uses the ramp that cook spun up along
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

	-- Dropped on every stamp change -- the six don't land on one frame, so an early solve would be wrong
	self._perfectStartsAt = nil
	self._perfectEndsAt = nil

	if cooking and not self._cooking then
		self._cooking = true

		-- The closed form opens seated, so without the carry a re-light jumps up to a whole turn
		if self._spinDown then
			self._spinCarry = { StartClock = os.clock(), Angle = self:_spinDownAngle() % (2 * math.pi) }
			self._spinDown = nil
		end

		self._stoveOff = nil
		self._materialApplied = false
		self._skewerModel = self._slot:FindFirstChild("Skewer")
		self:_stopAlarm()
		self:_rebuildCookParts()
		self:_showCookingUI()
		self:_showCookParticles()
		self:_startCookSound()
	elseif not cooking and self._cooking then
		self._cooking = false
		self._cookParts = nil
		self._spinCarry = nil
		self:_hideCookingUI()
		self:_hideCookParticles()
		self:_stopCookSound()
		self:_stopAlarm()

		-- Cool from where each coal got to -- a cook stopped early would otherwise flare up before dimming
		for _, charcoal in self._charcoals do
			charcoal.CoolFrom = charcoal.Part.Color
		end
		self._stoveOff = { StartClock = os.clock() }

		-- Held at speed just long enough to land on the seated orientation, so the model swap never shows
		local residual = (exitAngle + SPIN_SPEED * 0.5 * exitRamp) % (2 * math.pi)
		self._spinDown = {
			StartClock = os.clock(),
			StartAngle = exitAngle,
			Hold = ((2 * math.pi - residual) % (2 * math.pi)) / SPIN_SPEED,
			Ramp = exitRamp,
		}
	end

	-- A state, not an edge: a burst from a cook whose edge went unseen would still be due
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

-- Puts the cooking bar up over CookingUIAttachment, marks the bands, and wires the Robux skip.
function Grill:_showCookingUI()
	self:_hideCookingUI()

	local attachment = self._slot:FindFirstChild("CookingUIAttachment", true)
	if not attachment then
		return
	end

	local cookingUI = UI.CookingUI:Clone()

	-- Bands are fractions of the bar, so the marks sit in the same places whatever's cooking
	local border = cookingUI.Bar.Border
	local position = border.Position

	for index, boundary in CookStates.BOUNDARIES do
		local marker = if index == 1 then border else border:Clone()
		marker.Position = UDim2.new(boundary, position.X.Offset, position.Y.Scale, position.Y.Offset)
		marker.Parent = cookingUI.Bar
	end

	-- Hidden until Update decides there's a window to count to, so the placeholder never shows
	cookingUI.Timer.RichText = true
	cookingUI.Timer.Visible = false

	-- Left to RefreshInteraction, so the first frame doesn't show a visitor an owner-only offer
	cookingUI.SkipCooking.Visible = false

	-- Adorned to the attachment's part -- an Attachment adornee breaks billboard buttons on touch
	cookingUI.Adornee = attachment.Parent
	cookingUI.StudsOffsetWorldSpace = attachment.WorldPosition - attachment.Parent.Position
	-- Both scale with adornee size, so what did nothing against a sizeless Attachment shifts a part.
	cookingUI.ExtentsOffset = Vector3.zero
	cookingUI.ExtentsOffsetWorldSpace = Vector3.zero
	cookingUI.Active = true
	cookingUI.Parent = getScreenGui()

	self._cookingUICleaner:Add(cookingUI)

	-- On release like every other button; the griller is anchored, so it can't drift out from a finger
	self._cookingUICleaner:Add(UIController:BindButtonClick(cookingUI.SkipCooking, function()
		GrillerController = GrillerController or require(script.Parent)
		GrillerController:RequestSkipCook(self._uid)
	end, true).Disconnect)

	-- Re-enters RefreshInteraction when the reveal lands; on the bar's cleaner, so ending the cook cancels it
	local untilReveal = SKIP_REVEAL_DELAY - self:_elapsed()
	if self._cookTime >= SKIP_MIN_COOK_TIME and untilReveal > 0 then
		self._cookingUICleaner:Add(task.delay(untilReveal, function()
			self:RefreshInteraction()
		end))
	end

	self._cookingUI = cookingUI
	self._cookingFillSize = cookingUI.Bar.BarContainer.Bar.Size
end

-- Drops the cooking bar. It lives in PlayerGui, so this is the only thing that takes it down.
function Grill:_hideCookingUI()
	self._cookingUICleaner:Clean()
	self._cookingUI = nil

	-- Cleared so the next cook repaints its title on the first frame and solves its own window.
	self._cookingState = nil
	self._perfectStartsAt = nil
	self._perfectEndsAt = nil
end

-- Mounts the cook's particles on the grate, from the grill's own CookEffect folder or Default.
function Grill:_showCookParticles()
	-- Drops anything still fading out from the last cook, and cancels its pending teardown.
	self._particleCleaner:Clean()

	if not self._gratesPart then
		return
	end

	-- Named by the config, not the grill's id, so the folder and the model needn't share a name.
	local effectName = (self._structure and self._structure.CookEffect) or COOK_PARTICLE_DEFAULT

	local folder = Particles.Cooking:FindFirstChild(effectName)
		or Particles.Cooking:FindFirstChild(COOK_PARTICLE_DEFAULT)

	-- Warned, not thrown -- erroring would take the whole cook down over a missing folder
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

-- Switches the particles off and drops them once the air clears, so the smoke thins rather than cuts.
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

-- Starts the sizzle, layering the grill's own CookSound over the shared one on the same fades.
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
		local stop =
			SoundController:PlayLoopedSound(soundName, self._gratesPart, COOK_SOUND_FADE_IN, COOK_SOUND_FADE_OUT)
		if stop then
			self._soundCleaner:Add(stop)
		end
	end
end

-- Eases the sizzle back out and drops it. The cleaner holds every stopper, so one Clean fades all layers.
function Grill:_stopCookSound()
	self._soundCleaner:Clean()
end

-- Rings one burst on the grate. Looped so a short clip fills the burst, cut after ALARM_DURATION.
function Grill:_playAlarm()
	self._alarmCleaner:Clean()

	if not self._gratesPart then
		return
	end

	local stop = SoundController:PlayLoopedSound(ALARM_SOUND, self._gratesPart, ALARM_FADE_IN, ALARM_FADE_OUT)
	if not stop then
		return
	end

	-- Held so a cook ending mid-burst silences it, dropped once it rings out
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

-- Per-frame while cooking: spin, glow, brown, char, material swap and bar fill, all from elapsed time.
function Grill:Update()
	if not self._attachment then
		return
	end

	-- Pivoting every frame is what bridges the server swapping the settled model in underneath
	if not self._cooking then
		-- On its own clock -- an emptied slot drops the wind-down while the coals still have heat
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

			-- The landing is a whole turn on, so the seated pose is the orientation it was just drawn at.
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

	-- Ahead of the stamp check on purpose: a skipped frame would draw the skewer seated and pop
	model:PivotTo(self:_seatedCFrame() * CFrame.Angles(0, self:_spinAngleNow(), 0))

	-- A model not carrying our cook isn't the skewer on the heat, so nothing below renders against it
	if not self._cookStartedAt or model:GetAttribute("CookStartedAt") ~= self._cookStartedAt then
		return
	end

	-- Not floored like the spin's, or a cook stamped without a CookTime would ring the alarm every frame
	local cookTime = self._cookTime
	if not cookTime or cookTime <= 0 then
		return
	end

	-- Warped once, so bar, browning and charring move as one. The coals and spin deliberately don't read it
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

	-- Lands on the raw -> cooked boundary, then holds; charring past the end is GetOvertimeColor's
	local brown = math.clamp(progress / CookStates.RAW_END, 0, 1)

	-- Off raw seconds, not the warped bar: a resumed part-cooked skewer still lights the coals from cold
	local glow = math.clamp(self:_elapsed() / CHARCOAL_FADE_TIME, 0, 1)
	glow = glow * glow * (3 - 2 * glow) -- smoothstep, so the glow eases in rather than ramping flat
	for _, charcoal in self._charcoals do
		charcoal.Part.Color = CHARCOAL_OFF_COLOR:Lerp(charcoal.GlowColor, glow)
	end

	-- Out here because the take prompt reads the band too; acted on only at an edge
	local stateId = CookStates.GetStateFromCook(elapsed, cookTime)
	if stateId ~= self._cookingState then
		local previous = self._cookingState
		self._cookingState = stateId

		-- Raw -> Perfect only: a mid-cook stream-in opens on nil -> Perfect, which is the window already running
		if stateId == "Perfect" and previous == "Raw" and self._ownerUserId == LocalPlayer.UserId then
			SoundController:PlaySound(PERFECT_SOUND, self._gratesPart)
		end

		-- Only Raw asks the take to be held, so the offer has to be re-decided at every edge.
		self:RefreshInteraction()

		if self._cookingUI then
			local state = CookStates.GetStateFromId(stateId)
			local title = self._cookingUI.Title

			-- Snapped, not eased: the band colours are far enough apart that a lerp runs through olive.
			self._cookingUI.Bar.BarContainer.Bar.BackgroundColor3 = state.BarColor
			title.Text = state.Name

			-- Driven off the config's own list, so the states are only ever spelled out in one place.
			for _, cookState in CookStates.GetAllStates() do
				title[`{cookState.Id}Gradient`].Enabled = cookState.Id == stateId
			end
		end
	end

	local cookingUI = self._cookingUI
	if cookingUI then
		-- Only the X scale is ours, so a fill inset in the place file stays inset.
		local fill = cookingUI.Bar.BarContainer.Bar
		local fillSize = self._cookingFillSize
		fill.Size = UDim2.new(progress, fillSize.X.Offset, fillSize.Y.Scale, fillSize.Y.Offset)

		-- Inverted off the same map the bar draws from, so the countdown and the band mark hit together
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

		-- Off the same synced clock _elapsed reads, so every client counts the same figure down.
		local now = workspace:GetServerTimeNow()
		local timer = cookingUI.Timer

		if now < self._perfectEndsAt then
			-- "ends" is slotted in rather than made a second label, so "Perfect" holds its place.
			local opening = now < self._perfectStartsAt
			local remaining = (if opening then self._perfectStartsAt else self._perfectEndsAt) - now

			-- The live pace, not the steady one: an unstable grill's stall visibly climbs and its surge collapses
			local barTarget = (if opening then CookStates.RAW_END else CookStates.PERFECT_END) * cookTime
			local rate = CookStates.GetBarRate(
				self:_elapsed(),
				cookTime,
				self._cookWindowStretch,
				self._cookProgress,
				self._cookInstability,
				self._cookInstabilityPhase
			)
			local live = (barTarget - elapsed) / math.max(rate, MIN_BAR_RATE)

			-- Squashed, not clamped, so the number has no bound to snap against as the prediction swings across it
			local deviation = live - remaining
			remaining = math.max(remaining + deviation * TIMER_SWING / (TIMER_SWING + math.abs(deviation)), 0)

			local countdown = GuiUtil.ConvertSecondsToCountdown(remaining)

			timer.Visible = true
			timer.Text =
				`{GuiUtil.Colorize("Perfect", PERFECT_WORD_COLOR)}{if opening then "" else " ends"} in: {GuiUtil.Colorize(
					countdown,
					PERFECT_COUNTDOWN_COLOR
				)}`
		else
			-- Past the window there's nothing left to aim for; the fill, title and alarm already say so.
			timer.Visible = false
		end
	end

	-- Owner only, once the bar has nowhere left to go -- a visitor can't do anything about it.
	if overtime >= 0 and self._ownerUserId == LocalPlayer.UserId then
		if not self._alarmNextAt or os.clock() >= self._alarmNextAt then
			-- Re-derived from now rather than advanced, so a hitch can't queue two bursts back to back.
			self._alarmNextAt = os.clock() + ALARM_DURATION + ALARM_INTERVAL
			self:_playAlarm()
		end
	end

	if not self._cookParts then
		return
	end

	-- The char ramp lands on the same colour StickModel paints the rebuilt model, so a stop shows no seam
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

-- A Robux price for a label, "-" until the lookup lands. Asked once per id, on its own thread.
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

-- Seats a see-through copy of the held BBQ where the real one would land, rebuilt only when it changes.
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

	-- Through the same builder every other skewer visual uses, so the preview is exactly what gets placed.
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
			-- A floor, not a set, so a part authored see-through isn't made more solid.
			descendant.Transparency = math.max(descendant.Transparency, GHOST_TRANSPARENCY)
		elseif descendant:IsA("ParticleEmitter") then
			-- A preview throwing off a sauce's or mutation's sparks reads as a BBQ that's already down.
			descendant:Destroy()
		end
	end

	-- Anything but "Skewer": that's the name the slot's ChildAdded keys the server's real model on.
	model.Name = "GhostSkewer"
	model:PivotTo(self:_seatedCFrame())
	model.Parent = self._slot

	self._ghostCleaner:Add(model)
end

-- Puts the grill's prompts and cues up on owned grillers: place on the body, take on the skewer.
function Grill:RefreshInteraction()
	if not self._attachment then
		return
	end

	-- Every cue below hangs off this, so someone else's griller is scenery.
	local owned = self._ownerUserId == LocalPlayer.UserId
	local placed = self._slot:GetAttribute("PlacedStickId")
	local cooking = self._slot:GetAttribute("Cooking") == true

	GrillerController = GrillerController or require(script.Parent)

	-- Setting one down is what lights the grill, so the take is the cook's stop as well as its collection
	local canPlace = owned and placed == nil
	-- Stricter than a free grate: the glow and ghost need a held BBQ, and a cooked one can't go back on
	local heldSkewer = EquippedItem.GetSkewer()
	local canPlaceHeld = canPlace and heldSkewer ~= nil and heldSkewer:GetAttribute("Cooked") ~= true
	local takeEligible = owned and placed ~= nil
	-- A hold, not ineligibility -- gating the prompt's existence would rebuild it under a player stood at it
	local takeLocked = if cooking then GrillerController:IsStopLocked() else GrillerController:IsTakeLocked()

	-- Settled first, being the only offer that must be rebuilt; tracked by model, or a swap leaves a corpse
	local takeModel = if takeEligible then self._skewerModel else nil

	if takeModel ~= self._takeSkewerModel then
		self._takeSkewerCleaner:Clean()
		self._takeSkewerPrompt = nil
		self._takeSkewerModel = nil

		-- On a part, not the model -- a BillboardGui can't adorn a Model. Hence the PrimaryPart fallback
		local host = takeModel and (takeModel.PrimaryPart or takeModel:FindFirstChildWhichIsA("BasePart", true))

		if host then
			-- Recorded only once the prompt is actually up, so a model that arrived partless is retried.
			self._takeSkewerModel = takeModel

			local prompt = Instance.new("ProximityPrompt")
			prompt.RequiresLineOfSight = false
			prompt.Style = Enum.ProximityPromptStyle.Custom
			prompt.MaxActivationDistance = TAKE_PROMPT_DISTANCE
			-- Its own button, not the griller's E -- see TAKE_PROMPT_KEY.
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
			-- Parts can trail the model under streaming, and this prompt is the only way off the grill, so retry
			self._takeSkewerCleaner:Connect(takeModel.DescendantAdded, function()
				self:RefreshInteraction()
			end)
		end
	end

	if self._takeSkewerPrompt then
		-- Asserted both ways, not left alone, so releasing a lock restores the prompt on the next refresh.
		self._takeSkewerPrompt.Enabled = not takeLocked
		-- Only a take that would throw the run away asks to be held; nil state reads as Raw, guard on
		self._takeSkewerPrompt.HoldDuration = if cooking
			then CookStates.GetStateFromId(self._cookingState or "Raw").StopHold or 0
			else GRILL_PROMPT_HOLD
	end

	-- Tagged after the prompt is built, since the component resolves it once on start
	if self._skewerModel then
		self._skewerModel:SetAttribute("HighlightColor", Highlights.CLAIM)
		if takeEligible and not takeLocked then
			self._skewerModel:AddTag(PROMPT_HIGHLIGHT_TAG)
		else
			self._skewerModel:RemoveTag(PROMPT_HIGHLIGHT_TAG)
		end
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

			-- The ghost follows the label, not eligibility, or every free grill on the base would wear one
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

	-- Place only -- taking belongs to the skewer, which is what the player watches when they time it
	if self._prompt then
		self._prompt.Enabled = canPlace
		self._prompt.HoldDuration = GRILL_PROMPT_HOLD
	end

	-- Owner only and locked through the tutorial. Not a second stop -- it buys the result outright
	if self._cookingUI then
		local skip = self._cookingUI.SkipCooking
		local canSkip = owned
			and not GrillerController:IsSkipLocked()
			and self._cookTime >= SKIP_MIN_COOK_TIME
			and self:_elapsed() >= SKIP_REVEAL_DELAY

		skip.Visible = canSkip
		-- Only priced when actually offered -- the lookup is a MarketplaceService round trip.
		if canSkip then
			skip.Price.Text = self:_robuxPriceText(SKIP_COOK_PRODUCT)
		end
	end

	-- Authored in the place file, so a slot without the cue goes without
	if self._grillModel then
		self._grillModel:SetAttribute("HighlightColor", Highlights.PLACE)
		if canPlaceHeld then
			self._grillModel:AddTag(Highlights.TAG)
		else
			self._grillModel:RemoveTag(Highlights.TAG)
		end
	end

	-- Decided here, since _refreshGhost is also called from the prompt and shouldn't re-decide eligibility
	self._ghostSource = if canPlaceHeld then heldSkewer else nil
	self:_refreshGhost()
end

function Grill:Destroy()
	self:_hideCookingUI()

	-- These instances outlive this class, so a tag left on keeps breathing with nothing driving it
	if self._grillModel then
		self._grillModel:RemoveTag(Highlights.TAG)
	end
	if self._skewerModel then
		self._skewerModel:RemoveTag(PROMPT_HIGHLIGHT_TAG)
	end

	self._cleaner:Destroy()
	self = nil
end

return Grill
