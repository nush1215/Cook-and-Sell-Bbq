-- Dormant alongside its controller while sauce dispensers are postponed to a future update. Everything
-- below is intact -- un-comment it together with SauceDispenserController's init.

--[==[
-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local Highlights = require(Shared.Config.Highlights)
local SauceDispenserConfig = require(Shared.Config.SauceDispenser)
local Sauces = require(Shared.Config.Sauces)
local BaseUnlocks = require(Shared.Config.BaseUnlocks)
local GuiUtil = require(Shared.GuiUtil)

-- Controllers
local Controllers = script.Parent.Parent
local UIController = require(Controllers.UIController)
local SoundController = require(Controllers.SoundController)

-- Modules
local Modules = script.Parent.Parent.Parent.Modules
local EquippedItem = require(Modules.EquippedItem)

-- Assets
local UI = ReplicatedStorage.Assets.UI

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

local PROMPT_DISTANCE = 10

-- The attachment the place file authors for the place/take prompt to hang off, wherever under the
-- slot it's buried (the plate's mesh, typically). It's an Attachment because that's what a
-- ProximityPrompt needs -- one parented to a Model never fires at all.
local PLACE_PROMPT_ATTACHMENT = "PlaceSkewerAttachment"

-- How far off the bottle can still be clicked. Deliberately well past PROMPT_DISTANCE: the player
-- places the skewer standing at the plate, then clicks the bottle -- which sits higher and further
-- back -- so a click range tight enough for a walk-up prompt would leave them poking at a dead bottle.
local BOTTLE_CLICK_DISTANCE = 64

-- Pour animation tuning. The pour is a self-timed spring sequence (Spr), kicked off the Saucing edge
-- rather than scaled to the server's SAUCE_DURATION -- so these are absolute seconds, tune them freely.
-- Each phase springs the bottle's whole Pivot to a composed pose; the TIMEs below sequence the next
-- spring, the DAMPING/FREQUENCY pairs give each its feel.
local LIFT_HEIGHT = 18 -- studs the bottle rises before it tips
local TILT_ANGLE = math.rad(120) -- how far it rolls about its own axis to point at the skewer
local POUR_REACH = 1 -- studs it travels along the plate on each dab

local RISE_TIME = 0.8 -- seconds the bottle spends rising before it holds
local RISE_HOLD = 0.2 -- pause at the top before it tips over
local TILT_TIME = 0.35 -- seconds it spends tipping over
local POUR_TIME = 0.8 -- seconds of the forward/back applying motion
local POUR_PASSES = 2 -- forward/back dabs it makes across POUR_TIME

-- Spring feel per phase: a calm rise and return, snappier tilt and dabs (a touch of overshoot).
local RISE_DAMPING, RISE_FREQUENCY = 1, 2.5
local TILT_DAMPING, TILT_FREQUENCY = 0.85, 4
local POUR_DAMPING, POUR_FREQUENCY = 0.8, 6
local RETURN_DAMPING, RETURN_FREQUENCY = 1, 3

-- The signs the base plants on a dispenser, and the UI each one wears. The base decides which is up:
-- the unlock sign only while this dispenser is the next one up for purchase, the size sign once it's
-- bought.
local UNLOCK_SIGN_NAME = "UnlockSign"
local SIZE_SIGN_NAME = "SauceDispenserSizeSign"

-- Required lazily to break the cycle: SauceDispenserController requires this class.
local SauceDispenserController

--[[
    Class for a single sauce dispenser slot, on every client, so a pour plays out for visitors too.

    The server clones the bottle and the plated skewer onto the slot and mirrors the record onto the
    slot's attributes (DispenserSize / DispenserSauce / SauceRemaining / PlacedStickId / SkewerSauce /
    Saucing). This class reads those and renders the pour locally: when Saucing flips true the bottle
    rises LIFT_HEIGHT, rolls to TILT_ANGLE, dabs back and forth over the skewer, then springs back to
    rest -- a self-timed Spr sequence (see _playPour), so it plays for visitors too. It's kicked off the
    Saucing rising edge rather than scaled to a shared clock; the server lands the sauce partway through
    (SAUCE_DURATION), so the particles show while the bottle is still dabbing.

    The place/take prompt, the fill prompt beside it and the bottle's click only go up on the local
    player's own base, and only once the slot's Unlocked -- a locked dispenser is faded and carries no
    interaction at all.

    The signs on a locked/owned dispenser are the base's (it plants and pulls the models); what this
    class does is mount their UI -- the unlock price, and the size upgrade -- on the owner's client.
]]

-- The one ScreenGui the dispenser signs live under. They sit in PlayerGui adorned back onto the sign's
-- board rather than in the world, because that's what makes their buttons clickable.
local function getScreenGui(): ScreenGui
	local screenGui = PlayerGui:FindFirstChild("SauceDispenserSigns")
	if screenGui == nil then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "SauceDispenserSigns"
		screenGui.ResetOnSpawn = false
		screenGui.Parent = PlayerGui
	end

	return screenGui
end

--
local SauceDispenser = {}
SauceDispenser.__index = SauceDispenser

function SauceDispenser.new(slot: Instance, baseId: string)
	--
	local cleaner = Trove.new()

	local plate = slot:FindFirstChild("Plate")

	-- Authored a level or two down inside the plate (Plate.Mesh.AddSauceAttachment), so it's searched
	-- for rather than reached through -- the plate's own build is the place file's business.
	local refillAnchor = plate and plate:FindFirstChild("AddSauceAttachment", true)

	local self = setmetatable({
		--
		_slot = slot,
		_baseId = baseId,

		-- The plate the skewer sits on, which the place/claim cue adorns.
		_plate = slot:FindFirstChild("Plate"),

		-- Where the "fill this from the bottle you're holding" prompt sits, off to the side of the
		-- plate's own place/take one.
		_refillAnchor = refillAnchor,

		-- The server-cloned bottle and the rest pose the pour departs from and returns to. Captured on
		-- the model as it arrives, since the dispenser is a static Ghost the server never moves.
		_bottle = nil,
		_bottleRest = nil,

		-- The bottle's inner fill part and its authored full-level reference: the size it wears when
		-- full, and its rest centre in the bottle's own frame (so the level rides the pour). _appliedSauce
		-- is the flavor whose look is currently painted on, so the appearance is only re-cloned on a change,
		-- and _sauceTransparency the transparency that look wants -- kept aside because an empty bottle is
		-- hidden outright, and the paint only runs on a flavor change so it couldn't restore it.
		_sauce = nil,
		_sauceFullSize = nil,
		_sauceRestRel = nil,
		_appliedSauce = nil,
		_sauceTransparency = nil,

		-- Whether a pour is running, tracked so _sync only kicks the animation on the rising edge.
		_saucing = false,

		-- The skewer currently on the plate, tracked so _sync can tell a fresh placement from a take.
		-- Seeded from the slot so a plate that's already loaded doesn't ring as we join.
		_placedStickId = slot:GetAttribute("PlacedStickId"),

		-- The place/take prompt is created once, the moment its attachment is found, and lives for as
		-- long as this class does -- RefreshInteraction only ever flips its Enabled/ActionText from then
		-- on, never destroys or recreates it.
		_placePrompt = nil,

		--
		_refillPrompt = nil,
		_detector = nil,

		-- The sign UIs currently mounted on this dispenser's boards, by sign name.
		_signUIs = {}, -- [signName] = { UI, Cleaner }

		--
		_cleaner = cleaner,
		_refillCleaner = cleaner:Construct(Trove),
		_bottleCleaner = cleaner:Construct(Trove),

		-- Owns the template children cloned onto the fill part, so a flavor swap or a rebind drops them.
		_sauceCleaner = cleaner:Construct(Trove),

		-- Holds the running pour's scheduled steps, so a fresh pour or teardown cancels them cleanly.
		_pourCleaner = cleaner:Construct(Trove),
	}, SauceDispenser)

	-- The plate is what the place/take prompt hangs off and what the place cue adorns, and it lives in
	-- the place file rather than this repo -- so a missing one is a real failure case rather than
	-- something the code guarantees.
	if not plate then
		warn(`[SauceDispenser] {baseId} slot {slot.Name} has no Plate, it won't prompt`)
	elseif not refillAnchor then
		warn(`[SauceDispenser] {baseId} slot {slot.Name} has no AddSauceAttachment, it can't be filled`)
	end

	-- The attachment is authored somewhere under the slot (typically the plate's mesh), so a recursive
	-- find off the slot itself doesn't care exactly how deep the place file buries it.
	self:_createPlacePrompt(slot:FindFirstChild(PLACE_PROMPT_ATTACHMENT, true))

	-- The attachment isn't guaranteed to exist yet the instant this class is built (streaming, or the
	-- place file just not having one), so keep watching rather than giving up after one look -- the
	-- moment it shows up, the prompt goes up too.
	if not self._placePrompt then
		cleaner:Connect(slot.DescendantAdded, function(descendant)
			if not self._placePrompt and descendant.Name == PLACE_PROMPT_ATTACHMENT then
				self:_createPlacePrompt(descendant)
			end
		end)

		-- A genuinely missing attachment (as opposed to one that's merely late) would otherwise fail
		-- silently forever -- warn once streaming/loading has had a fair chance to catch up.
		task.delay(10, function()
			if not self._placePrompt then
				warn(`[SauceDispenser] {baseId} slot {slot.Name} has no {PLACE_PROMPT_ATTACHMENT}, it won't prompt to place`)
			end
		end)
	end

	self:_bindBottle(slot:FindFirstChild("Bottle"))

	-- The server rebuilds the bottle on a size upgrade (and the skewer on a place/take/finish), so
	-- follow it in and out.
	cleaner:Connect(slot.ChildAdded, function(child)
		if child.Name == "Bottle" then
			self:_bindBottle(child)
		end
	end)
	cleaner:Connect(slot.ChildRemoved, function(child)
		if child == self._bottle then
			self:_bindBottle(nil)
		end
	end)

	-- The pour, the prompt, the highlights and the signs all track these.
	local attributes = {
		"DispenserSize",
		"DispenserSauce",
		"SauceRemaining",
		"PlacedStickId",
		"SkewerSauce",
		"Saucing",
		"SauceStartedAt",
		"Unlocked",
	}
	for _, attribute in attributes do
		cleaner:Connect(slot:GetAttributeChangedSignal(attribute), function()
			self:_sync()
		end)
	end

	-- Buying the dispenser plants the size sign on a slot whose own attributes never changed (the unlock
	-- level lives on the owner's data, not the slot), so follow the folder rather than relying on this
	-- slot's state to catch it. Descendants and not just children, because a planted sign replicates
	-- model-first -- the board its UI adorns arrives after the model does, and that arrival is what
	-- makes the sign mountable.
	local signs = slot:FindFirstChild("Signs")
	if signs then
		cleaner:Connect(signs.DescendantAdded, function()
			self:_refreshSigns()
		end)
		cleaner:Connect(signs.ChildRemoved, function()
			self:_refreshSigns()
		end)
	end

	self:_sync()

	return self
end

-- Builds the place/take prompt on `anchor` the moment it's found, wherever this is called from (the
-- initial resolve or the late-arriving watcher). Created once and left parented for this class's whole
-- life -- RefreshInteraction only ever toggles Enabled/ActionText on it from here on.
function SauceDispenser:_createPlacePrompt(anchor: Instance?)
	if not anchor or self._placePrompt then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = 0.3
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.Enabled = false -- RefreshInteraction (run right after this, in _sync) sets the real state
	prompt.Parent = anchor

	self._placePrompt = prompt
	self._cleaner:Add(prompt)
	self._cleaner:Connect(prompt.Triggered, function()
		SauceDispenserController = SauceDispenserController or require(script.Parent)
		SauceDispenserController:RequestToggle(self._slot.Name)
	end)
end

-- Takes a newly-arrived bottle model as the one to animate, capturing the pose the server seated it
-- at as the rest the pour departs from and lands back on. The bottle carries the click and the glow,
-- so a slot that had neither until now (a fresh unlock, or the server's render landing after this
-- class was built) picks both up here.
function SauceDispenser:_bindBottle(bottle: Instance?)
	-- A pour in flight was animating the outgoing bottle -- drop its scheduled steps and springs, the
	-- new bottle arrives seated at rest and picks up the next Saucing edge on its own.
	self._pourCleaner:Clean()
	if self._bottle then
		Spr.stop(self._bottle)
	end

	self._bottle = bottle
	self._bottleRest = bottle and bottle:GetPivot()

	-- The detector belongs to the outgoing bottle -- it goes with it, so drop our handle on it and let
	-- RefreshInteraction put a fresh one on the new bottle.
	self._bottleCleaner:Clean()
	self._detector = nil

	self:_bindSauceFill(bottle and bottle:FindFirstChild("Sauce", true))

	-- The server clones the bottle and parents it in one go, and a model's descendants can land a
	-- moment after the model itself does -- so a fill part that isn't there yet is waited on rather
	-- than given up on. Without this the bottle keeps whatever level it was authored at for as long as
	-- it lives, which is every bottle, since the server always renders after this class is built.
	if bottle and not self._sauce then
		self._bottleCleaner:Connect(bottle.DescendantAdded, function(descendant)
			if descendant.Name == "Sauce" and descendant:IsA("BasePart") then
				self:_bindSauceFill(descendant)
			end
		end)
	end

	self:RefreshInteraction()
end

-- Takes the bottle's inner fill part as the one the level scales, and renders it: its authored size is
-- the full level the ratio scales off, its rest centre in the bottle's own frame keeps it seated
-- through a pour (the whole model gets PivotTo'd), and its authored transparency is the fallback look
-- for a flavor with no template. Nil for a bottle whose model has no fill part -- it renders no fill.
function SauceDispenser:_bindSauceFill(sauce: BasePart?)
	self._sauceCleaner:Clean()
	self._appliedSauce = nil

	self._sauce = sauce
	self._sauceFullSize = sauce and sauce.Size
	self._sauceRestRel = sauce and self._bottleRest:Inverse() * sauce.CFrame
	self._sauceTransparency = sauce and sauce.Transparency

	self:_refreshSauceFill()
end

-- Reads the slot's attributes and reconciles: kicks the pour on the Saucing rising edge, and keeps the
-- prompt, the bottle's click and the highlights current. The falling edge is left alone -- the pour is
-- self-timed and owns its own return, and Saucing clears (server FinishSaucing) partway through it.
function SauceDispenser:_sync()
	local saucing = self._slot:GetAttribute("Saucing") == true
	local placedStickId = self._slot:GetAttribute("PlacedStickId")

	if saucing and not self._saucing then
		self:_playPour()
	end

	-- A skewer landing on an empty plate is the player setting one down; the take that clears it isn't.
	local skewer = self._slot:FindFirstChild("Skewer")
	if placedStickId and not self._placedStickId and skewer then
		SoundController:PlaySound("Place", skewer:GetPivot())
	end

	self._saucing = saucing
	self._placedStickId = placedStickId

	self:_refreshSauceFill()
	self:RefreshInteraction()
end

-- Reconciles the bottle's inner fill part to the slot's state: paints it with the loaded flavor's
-- template look (Color/Material plus clones of the template's children, only re-cloned when the flavor
-- changes) and scales it down in Y to Remaining/Capacity, its bottom staying planted on the bottle
-- floor. All local writes to the anchored, server-owned part -- like the pour -- so they never fight
-- the server; keying the level off the bottle's current pivot lets it ride a pour in flight.
function SauceDispenser:_refreshSauceFill()
	local sauce = self._sauce
	if not sauce then
		return
	end

	local sauceId = self._slot:GetAttribute("DispenserSauce")

	-- No sauce loaded (a freshly-unlocked dispenser or a ghost preview): drop the flavor's look, and
	-- fall through to the level below so the fill collapses rather than being left standing at its
	-- authored full height with nothing in it.
	if not sauceId then
		self._sauceCleaner:Clean()
		self._appliedSauce = nil
	end

	-- Paint the flavor's look on once per change: its part's Color/Material, clones of whatever children
	-- the template carries (surface bits, bubbles), and the transparency it wants -- held rather than
	-- applied, since the level below owns what actually goes on the part. A flavor missing its template
	-- keeps whatever's already on the part.
	local config = sauceId and Sauces.GetSauceFromId(sauceId)
	if config and config.Template and sauceId ~= self._appliedSauce then
		local template = config.Template
		sauce.Color = template.Color
		sauce.Material = template.Material
		self._sauceTransparency = template.Transparency

		self._sauceCleaner:Clean()
		for _, child in template:GetChildren() do
			self._sauceCleaner:Add(child:Clone()).Parent = sauce
		end

		self._appliedSauce = sauceId
	end

	-- Scale the level to how full the bottle is, keeping its bottom planted: shrinking Y alone pulls
	-- the centre toward the middle, so drop the centre by half the shrink along the part's own up axis.
	-- Worked in the bottle's frame off its live pivot so the level stays seated even mid-pour. Nothing
	-- loaded reads as empty, so the same collapse covers it.
	local size = self._slot:GetAttribute("DispenserSize") or SauceDispenserConfig.DEFAULT_SIZE
	local capacity = SauceDispenserConfig.GetSizeFromId(size).Capacity
	local remaining = if sauceId then self._slot:GetAttribute("SauceRemaining") or 0 else 0
	local ratio = math.clamp(remaining / capacity, 0, 1)

	local full = self._sauceFullSize
	local newY = full.Y * ratio
	local drop = (full.Y - newY) / 2

	sauce.Size = Vector3.new(full.X, newY, full.Z)
	sauce.CFrame = self._bottle:GetPivot() * (self._sauceRestRel * CFrame.new(0, -drop, 0))

	-- Roblox floors a part's Size at 0.05 per axis, so an empty bottle would still wear a sliver of
	-- the flavor -- hide it outright instead. Written every pass rather than with the paint above,
	-- which only runs on a flavor change and so couldn't bring it back on a refill of the same one.
	sauce.Transparency = if ratio > 0 then self._sauceTransparency else 1
end

-- Kicks the self-timed pour: springs the bottle up, tips it over the skewer, dabs it back and forth,
-- then springs it back to rest. Each step targets the bottle's whole Pivot; the phase TIMEs sequence
-- them and _pourCleaner cancels any still pending if the pour restarts or the class tears down. All
-- local writes to the anchored, server-owned model, so they never fight the server.
function SauceDispenser:_playPour()
	local bottle = self._bottle
	local rest = self._bottleRest
	if not (bottle and rest) then
		return
	end

	-- A previous pour could still be settling -- drop its pending steps so this one owns the bottle.
	self._pourCleaner:Clean()

	-- The lift is world-up (so a bottle authored at an angle still rises straight); the dab and the tilt
	-- ride the bottle's own axes -- front/back along its look, the roll about its side.
	local raised = CFrame.new(0, LIFT_HEIGHT, 0) * rest
	local tilted = raised * CFrame.Angles(-TILT_ANGLE, 0, 0)
	local function dabbed(offset: number): CFrame
		return raised * CFrame.new(0, 0, -POUR_REACH * offset) * CFrame.Angles(-TILT_ANGLE, 0, 0)
	end

	-- Rise now; every later step is scheduled off its phase offset and held for cancellation.
	Spr.target(bottle, RISE_DAMPING, RISE_FREQUENCY, { Pivot = raised })

	local tiltAt = RISE_TIME + RISE_HOLD
	self._pourCleaner:Add(task.delay(tiltAt, function()
		Spr.target(bottle, TILT_DAMPING, TILT_FREQUENCY, { Pivot = tilted })
	end))

	-- Forward/back dabs, alternating a full sweep either side of centre across POUR_TIME.
	local pourAt = tiltAt + TILT_TIME
	local dabs = POUR_PASSES * 2
	local step = POUR_TIME / dabs
	for i = 0, dabs - 1 do
		local offset = if i % 2 == 0 then 1 else -1
		self._pourCleaner:Add(task.delay(pourAt + i * step, function()
			Spr.target(bottle, POUR_DAMPING, POUR_FREQUENCY, { Pivot = dabbed(offset) })
		end))
	end

	self._pourCleaner:Add(task.delay(pourAt + POUR_TIME, function()
		Spr.target(bottle, RETURN_DAMPING, RETURN_FREQUENCY, { Pivot = rest })
	end))
end

-- Mounts one of the slot's sign UIs on its board, or takes it down, following the sign model the base
-- plants and pulls. The UI lives in PlayerGui adorned back onto the board, because world-parented
-- buttons don't take clicks. `onPurchase` is bound to the buy button once, as the UI goes up. Returns
-- the mounted UI, or nil when that sign isn't up.
function SauceDispenser:_syncSignUI(signName: string, template: Instance, onPurchase: () -> ()): Instance?
	local signs = self._slot:FindFirstChild("Signs")
	local sign = signs and signs:FindFirstChild(signName)
	local mounted = self._signUIs[signName]

	if not sign then
		if mounted then
			self._cleaner:Remove(mounted.Cleaner)
			self._signUIs[signName] = nil
		end

		return nil
	end

	if mounted then
		return mounted.UI
	end

	-- The sign model replicates ahead of its own parts, so on a join the board it adorns can still be
	-- on the way. The folder's DescendantAdded brings us back here once it lands.
	local board = sign:FindFirstChild("Board")
	if not board then
		return nil
	end

	local signCleaner = self._cleaner:Construct(Trove)

	local ui = template:Clone()
	ui.Adornee = board
	ui.Active = true
	ui.Parent = getScreenGui()
	signCleaner:Add(ui)

	local binding = UIController:BindButtonClick(ui.Holder.Buttons.CurrencyPurchase, onPurchase, true)
	signCleaner:Add(binding.Disconnect)

	-- TODO: robux purchase not implemented yet -- needs a Products config entry (ProductId) per sign,
	-- then this would route through ShopController:PromptProductPurchaseFromId.
	local robuxBinding = UIController:BindButtonClick(ui.Holder.Buttons.RobuxPurchase, function() end, true)
	signCleaner:Add(robuxBinding.Disconnect)

	self._signUIs[signName] = { UI = ui, Cleaner = signCleaner }

	return ui
end

-- Paints this dispenser's signs from the state the base and the server put on the slot: the unlock
-- price while it's the next dispenser up for purchase, the size step and price once it's owned.
-- Owner-only, since the buttons buy on the local player's own base.
function SauceDispenser:_refreshSigns()
	local slotNumber = tonumber(self._slot.Name)
	local owned = self._baseId == LocalPlayer:GetAttribute("BaseId")

	-- Off our base, drop whatever's mounted -- the sign models stay for everyone, they just go blank.
	if not owned then
		for signName, mounted in self._signUIs do
			self._cleaner:Remove(mounted.Cleaner)
			self._signUIs[signName] = nil
		end

		return
	end

	local unlockUI = self:_syncSignUI(UNLOCK_SIGN_NAME, UI.SauceDispenserUnlockUI, function()
		SauceDispenserController = SauceDispenserController or require(script.Parent)
		SauceDispenserController:RequestUnlockDispenser()
	end)

	if unlockUI then
		local unlock = BaseUnlocks.GetUnlockFromId("SauceDispenser")
		unlockUI.Holder.TextLabel.Text = "Unlock Sauce Dispenser"
		unlockUI.Holder.Buttons.CurrencyPurchase.Title.Text =
			`${GuiUtil.ConvertNumberWithSuffix(unlock.Costs[slotNumber])}`
	end

	local sizeUI = self:_syncSignUI(SIZE_SIGN_NAME, UI.SauceSizeUpgradeUI, function()
		SauceDispenserController = SauceDispenserController or require(script.Parent)
		SauceDispenserController:RequestUpgradeSize(self._slot.Name)
	end)

	if sizeUI then
		local currentSize = self._slot:GetAttribute("DispenserSize") or SauceDispenserConfig.DEFAULT_SIZE
		local nextSize = SauceDispenserConfig.GetNextSize(currentSize)
		local holder = sizeUI.Holder

		holder.TextLabel.Text = "Sauce Size"
		holder.Buttons.Visible = nextSize ~= nil

		if nextSize then
			holder.Level.Text = `{currentSize} > {nextSize.Id}`
			holder.Buttons.CurrencyPurchase.Title.Text = `${GuiUtil.ConvertNumberWithSuffix(nextSize.Cost)}`
		else
			holder.Level.Text = `Max ({currentSize})`
		end
	end
end

-- Puts the dispenser's prompts and the bottle's click up on the local player's own base and takes them
-- down otherwise, so visitors just see the result. The place/take prompt hides while a pour runs (the
-- skewer's locked on); the bottle only takes clicks while there's something to pour on, and the fill
-- prompt only shows for a sauce bottle this dispenser can actually take.
function SauceDispenser:RefreshInteraction()
	self:_refreshSigns()

	-- A locked dispenser is scenery: it's faded, and every cue below hangs off this, so nothing on it
	-- can be prompted or highlighted until it's bought.
	local owned = self._baseId == LocalPlayer:GetAttribute("BaseId") and self._slot:GetAttribute("Unlocked") == true
	local placed = self._slot:GetAttribute("PlacedStickId")
	local skewerSauce = self._slot:GetAttribute("SkewerSauce")
	local saucing = self._slot:GetAttribute("Saucing")

	local loadedSauce = self._slot:GetAttribute("DispenserSauce")
	local remaining = self._slot:GetAttribute("SauceRemaining") or 0

	-- What the bottle has to give: a sauce loaded and something left in it.
	local loaded = loadedSauce ~= nil and remaining > 0

	-- Place/take prompt: enabled whenever the local player owns the base. It exists from the moment its
	-- attachment was found (see _createPlacePrompt) and never goes away after that, so a base the local
	-- player doesn't own just keeps it disabled rather than tearing it down.
	if self._placePrompt then
		self._placePrompt.Enabled = owned and not saucing

		-- Naming the sauced one keeps collecting it from reading like backing out, which is otherwise
		-- the same prompt on the same plate.
		if not placed then
			self._placePrompt.ActionText = "Place BBQ"
		elseif skewerSauce then
			self._placePrompt.ActionText = "Take Sauced BBQ"
		else
			self._placePrompt.ActionText = "Take BBQ"
		end
	end

	-- A sauce bottle in hand goes into a dispenser that's empty, or into one already holding that same
	-- flavor with room left. A full dispenser, or one holding something else, would spend the bottle
	-- for nothing, so it doesn't light up and its prompt stays down -- the server refuses either way.
	-- One drained to nothing counts as empty even though it still names its last flavor, or it would
	-- only ever take that one again.
	local held = EquippedItem.GetSauceId()
	local size = self._slot:GetAttribute("DispenserSize") or SauceDispenserConfig.DEFAULT_SIZE
	local capacity = SauceDispenserConfig.GetSizeFromId(size).Capacity
	local canRefill = owned
		and held ~= nil
		and not saucing
		and (not loaded or (loadedSauce == held and remaining < capacity))

	if owned and self._refillAnchor and not self._refillPrompt then
		local prompt = Instance.new("ProximityPrompt")
		prompt.RequiresLineOfSight = false
		prompt.HoldDuration = 0.3
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.MaxActivationDistance = PROMPT_DISTANCE
		prompt.ActionText = "Add Sauce"
		prompt.Parent = self._refillAnchor

		self._refillPrompt = prompt
		self._refillCleaner:Add(prompt)
		self._refillCleaner:Connect(prompt.Triggered, function()
			SauceDispenserController = SauceDispenserController or require(script.Parent)
			SauceDispenserController:RequestRefill(self._slot.Name)
		end)
	elseif not owned and self._refillPrompt then
		self._refillCleaner:Clean()
		self._refillPrompt = nil
	end

	if self._refillPrompt then
		self._refillPrompt.Enabled = canRefill
	end

	-- Bottle: only clickable while there's an unsauced skewer under it, the bottle has sauce left, and
	-- nothing's already pouring.
	local eligible = owned and placed ~= nil and not skewerSauce and not saucing and loaded

	if eligible and self._bottle and not self._detector then
		-- Parented to the bottle model itself, not to one part inside it: a ClickDetector under a Model
		-- takes clicks on every part of it, so the whole bottle is the click target rather than whichever
		-- part happened to be found first. (This is why the bottle clicks instead of prompting -- a
		-- ProximityPrompt under a Model never fires at all.)
		local detector = Instance.new("ClickDetector")
		detector.MaxActivationDistance = BOTTLE_CLICK_DISTANCE
		detector.CursorIcon = ""
		detector.Parent = self._bottle

		self._detector = detector
		self._bottleCleaner:Add(detector)
		self._bottleCleaner:Connect(detector.MouseClick, function()
			SauceDispenserController = SauceDispenserController or require(script.Parent)
			SauceDispenserController:RequestSauce(self._slot.Name)
		end)
	elseif not eligible and self._detector then
		self._bottleCleaner:Clean()
		self._detector = nil
	end

	-- The bottle breathes on the same conditions it can be acted on, so the glow is never out of step
	-- with them: its own click to pour, and the fill prompt beside it. Both can be up at once -- a
	-- skewer already on the plate and a bottle in hand -- so the colour follows the fill, since that's
	-- what the player picked something up to do.
	if self._bottle then
		self._bottle:SetAttribute("HighlightColor", if canRefill then Highlights.PLACE else Highlights.OPERATE)
		if eligible or canRefill then
			self._bottle:AddTag(Highlights.TAG)
		else
			self._bottle:RemoveTag(Highlights.TAG)
		end
	end

	-- The plate lives in the place file like the rest of the slot's parts, so a slot without one just
	-- goes without the cue.
	if not self._plate then
		return
	end

	-- The plate carries two cues at different moments: "put the cooked skewer you're holding here"
	-- while it's free, and "take the sauced one" once the pour's done. They can't overlap -- one wants
	-- the plate empty and the other wants it full -- so one tag with a colour swap covers both.
	local skewer = EquippedItem.GetSkewer()
	local canPlace = owned
		and not placed
		and skewer ~= nil
		and skewer:GetAttribute("Cooked") == true
		and skewer:GetAttribute("Sauce") == nil
	local canClaim = owned and skewerSauce ~= nil and not saucing

	if canPlace then
		self._plate:SetAttribute("HighlightColor", Highlights.PLACE)
	elseif canClaim then
		self._plate:SetAttribute("HighlightColor", Highlights.CLAIM)
	end

	if canPlace or canClaim then
		self._plate:AddTag(Highlights.TAG)
	else
		self._plate:RemoveTag(Highlights.TAG)
	end
end

function SauceDispenser:Destroy()
	-- The plate and the bottle are the base's and the server's, not ours, so they can outlive this
	-- class -- leave and they'd keep breathing with nothing driving them.
	if self._plate then
		self._plate:RemoveTag(Highlights.TAG)
	end
	if self._bottle then
		self._bottle:RemoveTag(Highlights.TAG)
		Spr.stop(self._bottle)
	end

	self._cleaner:Destroy()
	self = nil
end

return SauceDispenser
]==]

return {}
