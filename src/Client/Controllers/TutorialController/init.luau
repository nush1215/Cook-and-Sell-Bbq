-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local Highlights = require(Shared.Config.Highlights)
local Keywords = require(Shared.Config.Keywords)
local Structures = require(Shared.Config.Structures)

-- Modules
local Modules = script.Parent.Parent.Modules
local SpotlightUI = require(Modules.SpotlightUI)

-- Assets
local Assets = ReplicatedStorage.Assets
local UI = Assets.UI

-- Controllers
local PlayerDataController
local UIController
local HudController
local SoundController
local ConfettiController
local InventoryController
local GrillStandShopController
local GrillerController
local StickStandController
local IngredientRollingController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

--[[
    Drives the onboarding sequence, together with Sequence/<Variant>/1..N. The server only owns the
    finished flag, the funnel, the hammer payout, and what a client can't be trusted with (the first
    roll's result, and the closing customer).

    The tutorial ships as named variants -- one folder of steps each -- so a reworked onboarding can be
    built alongside the one that works rather than over it. Which one a player runs is decided server
    side (TutorialManager, off an experience config) and read back here from the replica. Everything
    below is shared: only the step list differs between variants.

    A step is a ModuleScript under the active variant's folder named for its position, returning one
    function that takes this controller as `self` and runs imperatively until it fires SequenceFinish.
    Steps own their own teardown: every effect factory here hands back a { Destroy }.

    The key primitive is AwaitGoal -- an ordered list of conditions re-checked every frame, prompting for
    the first unmet one, so walking away from the griller puts the banner back to "come back to it".
]]

--
local NEAR_DISTANCE = 12

-- A prompt is either a fixed string or a function evaluated each frame for live text.
type Prompt = string | (() -> string)

-- Gold pulsing fill marking tutorial goals. Fill only: grills and stands already carry the game's own
-- BreathingHighlight, and a second opaque outline over it reads as a bug.
local HIGHLIGHT_COLOR = Color3.fromRGB(255, 200, 40)
local HIGHLIGHT_MIN_FILL = 0.35
local HIGHLIGHT_MAX_FILL = 0.8
local HIGHLIGHT_PULSE_SPEED = 3

-- Never shares an adornee with BreathingHighlight -- two Highlights on one instance is undefined -- so
-- anything the tutorial sets breathing has this taken off it.
local PROMPT_HIGHLIGHT_TAG = "PromptSubjectHighlight"

-- Padding around a spotlit HUD button, in pixels. Shared with the hotbar slot cue.
local HUD_SPOTLIGHT_PADDING = 12

-- Where the server parks each base's tutorial guides, keyed by base name (see Base.new).
local GUIDES_FOLDER_NAME = "TutorialGuides"

-- The label over a guide saying what the ghost is for. Drifts wider and quicker than the griller's knob
-- billboard, having to catch the eye of someone who doesn't yet know what they're looking for.
local PLACE_HERE_LABEL_NAME = "TutorialPlaceHere"
local PLACE_HERE_FLOAT_AMPLITUDE = 0.5
local PLACE_HERE_FLOAT_SPEED = 5

-- The banner's text swap: drop the line this far below where it was authored, then spring it back up.
local TEXT_SLIDE_OFFSET = 0.052
local TEXT_SLIDE_DAMPING = 0.5
local TEXT_SLIDE_FREQUENCY = 3.5

-- These are authored in the place file, so a miss is a build problem, not slow replication -- warn and
-- carry on rather than hanging the sequence on something that's never coming.
local ASSET_TIMEOUT = 10

-- The attribute TutorialManager publishes this player's assigned variant on, once it has resolved the
-- experience config behind it.
local VARIANT_ATTRIBUTE = "TutorialVariant"

-- Handed back when an effect's asset is missing, so a step can call Destroy without checking.
local EMPTY_HANDLE = {
	Destroy = function() end,
}

-- Resolved tutorial assets, misses included -- otherwise every step wanting the same absent asset would
-- sit through its own timeout, turning one build mistake into a tutorial that crawls.
local assetCache = {}

-- Resolves an authored tutorial asset, warning the first time one isn't there.
local function getTutorialAsset(name: string): Instance?
	local cached = assetCache[name]
	if cached ~= nil then
		return cached or nil
	end

	local folder = Assets:WaitForChild("Tutorial", ASSET_TIMEOUT)
	local asset = folder and folder:WaitForChild(name, ASSET_TIMEOUT)

	if not asset then
		warn(`TutorialController: ReplicatedStorage.Assets.Tutorial.{name} is missing`)
	end

	-- false rather than nil, so a miss is a cache hit rather than another lookup.
	assetCache[name] = asset or false
	return asset
end

-- Resolves a beam endpoint to whatever carries its world position: an attachment or part as-is, a model
-- by its primary part, anything else by the first part under it. An attachment resolves to *itself*,
-- since marking that exact spot is the point -- resolving through would aim at the model's centre.
local function resolveBeamAnchor(target: Instance): (BasePart | Attachment)?
	if target:IsA("BasePart") or target:IsA("Attachment") then
		return target
	end

	-- Descendants, not children: a structure is a model of models (a griller keeps its Grill inside it),
	-- so a direct-children search comes back empty on the things most worth pointing at.
	if target:IsA("Model") then
		return target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
	end

	return target:FindFirstChildWhichIsA("BasePart", true)
end

-- Where a resolved anchor sits in the world.
local function getAnchorPosition(anchor: BasePart | Attachment): Vector3
	return if anchor:IsA("Attachment") then anchor.WorldPosition else anchor.Position
end

--
local TutorialController = {
	FinishTutorialEvent = Network.Event("FinishTutorial"),
	LogStepEvent = Network.Event("LogTutorialStep"),

	SequenceFinish = Signal.new(),

	-- Every variant's steps, keyed by variant then position, alongside each one's step count. All of them
	-- load: which one this player runs isn't known until their assignment replicates, and requiring a step
	-- only defines its function -- nothing in the step body runs until Start spawns it.
	_sequences = {},
	_sequenceCounts = {},
}

-- Runs each tutorial sequence in order, waiting for the active one to fire SequenceFinish before
-- moving on to the next, then plays the finish.
-- @param variant: The variant to run, as assigned by the server
function TutorialController:Start(variant: string)
	local tutorialUI = PlayerGui:WaitForChild("TutorialUI", ASSET_TIMEOUT)
	if not tutorialUI then
		warn("TutorialController: PlayerGui.TutorialUI is missing -- the tutorial cannot run")
		return
	end

	self.TutorialUI = tutorialUI
	self.TutorialUI.Holder.Description.RichText = true
	UIController:OpenFrame(self.TutorialUI.Holder, true)

	-- The whole HUD, top bar included. The two teleports up there are the only part of it the tutorial
	-- ever wants, and taking one in the middle of a beat that didn't ask for it just strands the player
	-- away from whatever they were being told to do -- so the bar comes down too, and the two steps that
	-- do want it let it back up for as long as they need it. A claim rather than HideHud: HideHud leaves
	-- every button sitting there and merely swallows the click, which looks pressable and does nothing.
	HudController:KeepHudHidden(self)

	-- Hidden until the base is built, so nothing on screen invites a press before the tutorial has said
	-- anything.
	InventoryController:HideInventory()

	-- Shut for the whole run: the store trip walks past this one's zone and it has nothing they need.
	GrillStandShopController:SetLocked(true)

	-- Held start to finish rather than across the cooking beat alone. On one shared lock it came back for
	-- the tail of the very cook it was hidden through, offering to sell the player out of the lesson.
	GrillerController:SetSkipLocked(true)

	-- Shut until the beat that asks for the pull, which is what opens it. The run's guaranteed roll is armed
	-- for its whole length and burns on the first pull, so one taken during the build beats lands the
	-- ingredient the buy beat is about to point at -- and leaves the player off the line they're being
	-- walked down.
	IngredientRollingController:SetRollLocked(true)

	-- BaseId lands after the client has built, so say something rather than opening blank.
	self:SetText("Tutorial", "Getting your stall ready...")
	self:GetBase()

	-- Back as soon as there's a stall: step 1 asks them to equip a griller off it.
	InventoryController:ShowInventory()

	self:LogStep("Start")

	local steps = self._sequences[variant]
	for i = 1, self._sequenceCounts[variant] do
		local sequence = steps[tostring(i)]
		if sequence then
			-- Connect before spawning, not :Wait() after: task.spawn runs the step synchronously to its
			-- first yield, so a step whose goal is already met fires SequenceFinish before a Wait could
			-- be reached -- and the tutorial would sit forever on a beat it had passed.
			local finished = false
			local connection = self.SequenceFinish:Connect(function()
				finished = true
			end)

			task.spawn(sequence, self)

			while not finished do
				task.wait()
			end

			connection:Disconnect()
			SoundController:PlaySound("TutorialProgress")
		end
	end

	self.FinishTutorialEvent:FireServer()
	self:SetText(nil, "Tutorial Complete!")

	-- Released here, not by the step that took it: the roll beat shuts the lever behind the pull it asked
	-- for and nothing before the finish wants it open, so the run holds one lock rather than each beat
	-- taking its own.
	if self.LeverLock then
		self.LeverLock.Destroy()
		self.LeverLock = nil
	end

	HudController:ReleaseHud(self)
	HudController:ShowHud()

	-- Both held from the top of the run, so they come off here with the HUD.
	GrillStandShopController:SetLocked(false)
	GrillerController:SetSkipLocked(false)

	-- Released here, not by the step that took it: the take beat shuts the stand once the BBQ is in hand
	-- and nothing between there and the finish wants it open, so the run holds it rather than the griller
	-- beat taking a lock it has no reason to know about.
	StickStandController:SetPlaceLocked(false)

	ConfettiController:FireSidesConfetti({
		Images = {
			"rbxassetid://12535201371",
		},

		Amount = 80,
		Scale = 1.35,
	})
	SoundController:PlaySound("TutorialComplete")

	task.delay(2.5, function()
		UIController:CloseFrame(self.TutorialUI.Holder)
	end)

	if self.Spotlight then
		self.Spotlight:Destroy()
		self.Spotlight = nil
	end
end

-- The local player's base model, blocking until assigned. Resolved once and kept -- it never changes.
function TutorialController:GetBase(): Model
	local base = self:GetBaseIfPresent()
	if base then
		return base
	end

	local baseFolder = workspace:WaitForChild("Base")

	while LocalPlayer:GetAttribute("BaseId") == nil do
		LocalPlayer:GetAttributeChangedSignal("BaseId"):Wait()
	end

	self.Base = baseFolder:WaitForChild(LocalPlayer:GetAttribute("BaseId"))
	return self.Base
end

-- The local player's base if streamed in, else nil. Non-blocking, so a per-frame check can't stall its
-- thread inside a WaitForChild. Re-resolves when the kept model has left the world: a base streams back
-- in as a brand-new instance, leaving every reference into the old one dead.
function TutorialController:GetBaseIfPresent(): Model?
	if self.Base and self.Base.Parent then
		return self.Base
	end

	local baseId = LocalPlayer:GetAttribute("BaseId")
	local baseFolder = workspace:FindFirstChild("Base")
	self.Base = (baseId and baseFolder and baseFolder:FindFirstChild(baseId)) or nil

	return self.Base
end

-- One of the player's structures of the given kind. Keyed on category, not a structure id, so it still
-- finds their only griller when that's a later model of one.
--
-- BEWARE: blocks until the player has one. Steps 1 and 2 are what make that safe -- a beat calling this
-- ahead of them waits forever and stops the funnel dead. That block IS the goal in those two steps.
function TutorialController:GetStructure(category: string): Model
	local base = self:GetBase()
	local folder = base:WaitForChild(Structures.FOLDER_NAME)

	while true do
		for _, model in folder:GetChildren() do
			if model:HasTag(category) then
				return model
			end
		end

		-- The tag goes on last, after parenting and attributes, so waiting on it rather than on ChildAdded
		-- is what guarantees the model handed back is ready to be pointed at.
		CollectionService:GetInstanceAddedSignal(category):Wait()
	end
end

-- The build tool the player is carrying for a kind of structure -- the counterpart to GetStructure, which
-- finds what they've already put down. Non-blocking and re-resolved rather than held, since BuildManager
-- rebuilds the backpack on every spawn. Both containers are scanned: an equipped tool sits in the character.
-- @param category: a Structures Category ("Grillers", "StickStands")
function TutorialController:GetStructureTool(category: string): Tool?
	for _, container in { LocalPlayer:FindFirstChildOfClass("Backpack"), LocalPlayer.Character } do
		if not container then
			continue
		end

		for _, child in container:GetChildren() do
			if child:IsA("Tool") and Structures.IsCategory(child:GetAttribute("StructureId") or "", category) then
				return child
			end
		end
	end

	return nil
end

-- Logs an onboarding funnel step. The server owns the ordering and names; the client only sends the
-- Key as it passes each beat.
-- @param key: A funnel step Key (must match one in TutorialManager's FUNNEL_STEPS)
function TutorialController:LogStep(key: string)
	self.LogStepEvent:FireServer(key)
end

-- Returns the single shared spotlight used across every tutorial sequence.
function TutorialController:GetSpotlight()
	if not self.Spotlight then
		self.Spotlight = SpotlightUI.new()
	end

	return self.Spotlight
end

-- Colours a keyword for the banner. Object keywords take their colour from Config.Keywords, looked up
-- here rather than passed per step, so "BBQ" and "Griller" can't drift across the places they're written
-- -- and the same table is what notifications use, so a word reads alike in a banner and a toast.
-- @param color: Optional override, for a keyword whose colour is already authored elsewhere
function TutorialController:Emphasize(text: string, color: Color3?): string
	return GuiUtil.Colorize(text, color or Keywords.Colors[text] or Keywords.EMPHASIS)
end

-- Updates the tutorial banner text. Title is optional and left unchanged when omitted.
function TutorialController:SetText(title: string?, description: string)
	local holder = self.TutorialUI.Holder
	local label = holder.Description

	if title then
		holder.Title.Text = title
	end

	-- The authored position is the rest pose, so the banner can be moved in Studio without retuning here.
	if not self._descriptionPosition then
		self._descriptionPosition = label.Position
	end

	Spr.stop(label)

	label.Position = self._descriptionPosition + UDim2.fromScale(0, TEXT_SLIDE_OFFSET)
	Spr.target(label, TEXT_SLIDE_DAMPING, TEXT_SLIDE_FREQUENCY, { Position = self._descriptionPosition })

	label.Text = description
end

-- Shows the prompt of the first unsatisfied guard, re-checked every frame, so undoing an earlier
-- requirement brings its prompt back. Once every guard holds, the optional goal prompt shows and this
-- returns when the goal is reached. A Description may be a function, for prompts that read live state.
--
-- Passing a guard plays the step-finish sound, but only going forward and only once per guard -- guards
-- can be undone, so otherwise walking out of range and back would sound like a fresh win every lap.
-- @param guards: ordered { { Description: Prompt, Check: () -> boolean } }
-- @param goal: optional { Description: Prompt, Wait: () -> () } milestone
function TutorialController:AwaitGoal(
	guards: { { Description: Prompt, Check: () -> boolean } }?,
	goal: { Description: Prompt, Wait: () -> () }?
)
	guards = guards or {}

	local goalReached = false
	if goal then
		task.spawn(function()
			goal.Wait()
			goalReached = true
		end)
	end

	local shownDescription

	-- Tracked by stage index rather than by the text shown: a Description reading live state rewrites
	-- itself without anything having been achieved.
	local furthestStage = 0

	while true do
		if goal and goalReached then
			return
		end

		local stage = 0
		local description: Prompt?
		for index, guard in guards do
			if not guard.Check() then
				description = guard.Description
				stage = index
				break
			end
		end

		if not description then
			if not goal then
				return
			end

			description = goal.Description
			stage = #guards + 1
		end

		if stage > furthestStage then
			-- Silent on the first stage -- that's the step opening, and the previous step already chimed.
			if furthestStage > 0 then
				SoundController:PlaySound("TutorialProgress")
			end

			furthestStage = stage
		end

		if type(description) == "function" then
			description = description()
		end

		if description ~= shownDescription then
			self:SetText("Tutorial", description)
			shownDescription = description
		end

		task.wait()
	end
end

-- Whether the local character is within distance of the target, measured from its pivot so a whole model
-- can be passed as-is. Pass an attachment instead where the real question is "close enough to press the
-- prompt": a griller's pivot can be well within range while the player is nowhere near its prompt.
function TutorialController:IsNear(target: PVInstance | Attachment, distance: number?): boolean
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not target or not target.Parent then
		return false
	end

	local position = if target:IsA("Attachment")
		then target.WorldPosition
		else (target :: PVInstance):GetPivot().Position

	return (root.Position - position).Magnitude <= (distance or NEAR_DISTANCE)
end

-- Adorns a gold pulsing fill onto a part or model to mark a goal, until the handle's Destroy is called.
-- Pass a resolver for a goal that isn't there yet or is rebuilt mid-step (the rolled ingredient is both);
-- the highlight then lives on Terrain and re-points its Adornee, since parenting it into the goal would
-- destroy it with each re-clone.
-- @param adornee: The BasePart or Model to glow, or a resolver evaluated each frame
-- @param shouldHide: Optional predicate; while it returns true the glow is hidden
function TutorialController:CreateHighlight(
	adornee: Instance | (() -> Instance?),
	shouldHide: (() -> boolean)?
): { Destroy: () -> () }
	local isResolver = type(adornee) == "function"

	-- Wrap a plain Instance so the heartbeat always resolves through a function.
	local resolveAdornee: () -> Instance? = if isResolver
		then adornee :: () -> Instance?
		else function()
			return adornee :: Instance
		end

	local highlight = Instance.new("Highlight")
	highlight.FillColor = HIGHLIGHT_COLOR
	highlight.FillTransparency = HIGHLIGHT_MIN_FILL
	highlight.OutlineTransparency = 1
	highlight.Enabled = not isResolver
	highlight.Adornee = if isResolver then nil else adornee :: Instance
	highlight.Parent = if isResolver then workspace.Terrain else adornee :: Instance

	local clock = 0
	local heartbeat = RunService.Heartbeat:Connect(function(dt)
		local target = resolveAdornee()
		if not target or (shouldHide and shouldHide()) then
			highlight.Enabled = false
			return
		end

		if highlight.Adornee ~= target then
			highlight.Adornee = target
		end

		highlight.Enabled = true
		clock += dt * HIGHLIGHT_PULSE_SPEED
		local alpha = (math.sin(clock) + 1) / 2
		highlight.FillTransparency = HIGHLIGHT_MIN_FILL + alpha * (HIGHLIGHT_MAX_FILL - HIGHLIGHT_MIN_FILL)
	end)

	return {
		Destroy = function()
			heartbeat:Disconnect()
			highlight:Destroy()
		end,
	}
end

-- Marks a goal with the game's own breathing highlight rather than the tutorial's gold pulse -- used
-- where the goal is something to act on, so the tutorial doesn't teach a second visual language for it.
-- Takes a resolver like CreateBeam, moving the tag as the resolved goal is destroyed and re-cloned.
-- @param target: The goal instance, or a resolver evaluated each frame
function TutorialController:CreateBreathingHighlight(target: Instance | (() -> Instance?)): { Destroy: () -> () }
	-- Wrap a plain Instance so the heartbeat always resolves through a function.
	local resolveTarget: () -> Instance? = if type(target) == "function"
		then target :: () -> Instance?
		else function()
			return target :: Instance
		end

	local tagged: Instance? = nil
	local function untag()
		if tagged then
			tagged:RemoveTag(Highlights.TAG)
			tagged = nil
		end
	end

	local heartbeat = RunService.Heartbeat:Connect(function()
		local goal = resolveTarget()
		if goal ~= tagged then
			untag()

			if goal then
				goal:SetAttribute("HighlightColor", HIGHLIGHT_COLOR)
				goal:AddTag(Highlights.TAG)
				tagged = goal
			end
		end

		-- Every frame, not once on tagging: the owning system re-adds its prompt cue whenever world state
		-- changes, and the two can't share an adornee.
		if tagged then
			tagged:RemoveTag(PROMPT_HIGHLIGHT_TAG)
		end
	end)

	return {
		-- The prompt cue isn't restored: these goals are gone by the time their step ends, and the owning
		-- system re-tags anything that isn't.
		Destroy = function()
			heartbeat:Disconnect()
			untag()
		end,
	}
end

-- Draws a beam from the character to a goal, hiding within hideDistance and re-binding across respawns.
--
-- Both the beam and its goal-side attachment live on Terrain, with the attachment pinned onto the goal
-- each frame. Parented to the goal instead, StreamingEnabled would wipe the beam exactly when the goal
-- got far enough to need pointing at, and it would never come back -- the goal streams in as a new
-- instance. On Terrain it survives, merely hiding while the goal is absent.
-- @param target: The goal instance, or a resolver evaluated each frame to re-acquire a goal that
--   streams out and back in as a new instance, or that only appears part way through the step
-- @param hideDistance: The distance at which the beam disappears
function TutorialController:CreateBeam(
	target: Instance | (() -> Instance?),
	hideDistance: number
): { Destroy: () -> () }
	local template = getTutorialAsset("TutorialBeam")
	if not template then
		return EMPTY_HANDLE
	end

	-- Wrap a plain Instance so the rest of the function always resolves through a function.
	local resolveTarget: () -> Instance? = if type(target) == "function"
		then target :: () -> Instance?
		else function()
			return target :: Instance
		end

	-- A static target with nothing to anchor to is a wiring bug. A resolver may legitimately return nil
	-- while the goal is streamed out, so it isn't checked.
	if type(target) ~= "function" and not resolveBeamAnchor(target :: Instance) then
		warn(`CreateBeam: no BasePart or Attachment found for {(target :: Instance):GetFullName()}`)
	end

	local beam = template:Clone() :: Beam
	local goalAttachment = beam:FindFirstChild("0") :: Attachment
	local playerTemplate = beam:FindFirstChild("1") :: Attachment

	goalAttachment.Parent = workspace.Terrain
	beam.Attachment0 = goalAttachment
	beam.Attachment1 = nil
	beam.Enabled = false
	beam.Parent = workspace.Terrain

	local playerAttachment
	local function bindCharacter(character: Model)
		local root = character:WaitForChild("HumanoidRootPart", 5)
		if not root then
			return
		end

		if playerAttachment then
			playerAttachment:Destroy()
		end

		playerAttachment = playerTemplate:Clone()
		playerAttachment.Parent = root
		beam.Attachment1 = playerAttachment
	end

	if LocalPlayer.Character then
		bindCharacter(LocalPlayer.Character)
	end
	local characterAdded = LocalPlayer.CharacterAdded:Connect(bindCharacter)

	-- Cached so the per-frame cost is the resolver call, not a walk of the goal's descendants. Re-resolved
	-- when the resolver hands back a different instance, or when the cached anchor has gone.
	local goalInstance: Instance? = nil
	local goalAnchor: (BasePart | Attachment)? = nil
	local function currentGoalAnchor(): (BasePart | Attachment)?
		local instance = resolveTarget()
		if instance ~= goalInstance or (goalAnchor and not goalAnchor.Parent) then
			goalInstance = instance
			goalAnchor = if instance then resolveBeamAnchor(instance) else nil
		end

		return goalAnchor
	end

	local heartbeat = RunService.Heartbeat:Connect(function()
		local anchor = currentGoalAnchor()
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not anchor or not root or not playerAttachment or playerAttachment.Parent ~= root then
			beam.Enabled = false
			return
		end

		-- Pin the goal-side attachment onto the (possibly re-resolved) goal.
		local position = getAnchorPosition(anchor)
		goalAttachment.WorldPosition = position
		beam.Enabled = (root.Position - position).Magnitude > hideDistance
	end)

	return {
		Destroy = function()
			characterAdded:Disconnect()
			heartbeat:Disconnect()
			if playerAttachment then
				playerAttachment:Destroy()
			end
			goalAttachment:Destroy()
			beam:Destroy()
		end,
	}
end

-- Puts one of the tutorial's ghost structures back into the world, suggesting where to build, and hands
-- back the Model so a step can aim its beam and glow at it (nil if the guide wasn't authored).
--
-- Guides are authored per base and parked in ReplicatedStorage.TutorialGuides at load (see Base.new), so
-- this is a purely local reparent onto the exact authored spot. Nothing enforces building there -- the
-- step finishes on a structure going down anywhere legal.
-- @param name: the guide's name under its base's folder ("Grill", "StickStand")
function TutorialController:ShowGuide(name: string): { Destroy: () -> (), Model: Model? }
	local baseName = self:GetBase().Name
	local holder = ReplicatedStorage:WaitForChild(GUIDES_FOLDER_NAME, ASSET_TIMEOUT)
	local baseGuides = holder and holder:WaitForChild(baseName, ASSET_TIMEOUT)
	local guide = baseGuides and baseGuides:FindFirstChild(name)

	if not guide then
		warn(`TutorialController: base {baseName} has no {GUIDES_FOLDER_NAME}.{name} guide`)
		return EMPTY_HANDLE
	end

	guide.Parent = workspace

	-- The label saying what the ghost is for, hung on the guide so it travels with it. Bobbed by PartFloat
	-- like every other floating label; no spin, since a billboard already faces the camera.
	local labelTemplate = UI:FindFirstChild(PLACE_HERE_LABEL_NAME)
	local label
	if labelTemplate then
		-- Parented to the model, not a part inside it: guides are hand-built and carry no PrimaryPart, so
		-- any part found would be arbitrary and the attachment would inherit its transform. On the model
		-- the attachment's CFrame is already world space.
		label = labelTemplate:Clone()
		label.Parent = guide

		-- The template's authored offset is kept rather than computed from the model's box, since label
		-- height over a ghost is a thing to nudge in Studio. A template left at 0,0,0 therefore lands
		-- inside the ghost and is occluded -- the asset wants some height on it.
		label:SetAttribute("CanSpin", false)
		label:SetAttribute("HoverAmplitude", PLACE_HERE_FLOAT_AMPLITUDE)
		label:SetAttribute("HoverSpeed", PLACE_HERE_FLOAT_SPEED)
		label:AddTag("PartFloat")
	else
		warn(`TutorialController: ReplicatedStorage.Assets.UI.{PLACE_HERE_LABEL_NAME} is missing`)
	end

	return {
		Model = guide,
		Destroy = function()
			-- Before the guide is parked, or it rides back into ReplicatedStorage and the next ShowGuide
			-- hangs a second label alongside it.
			if label then
				label:Destroy()
			end

			-- Parked, not destroyed: the reparent above was local, so destroying would take the base's
			-- copy out for the whole session and leave a second run with nothing to point at.
			guide.Parent = baseGuides
		end,
	}
end

-- Dims the screen down to a single HUD button, for a beat that asks the player to press one. FocusUI
-- binds its own follow loop, so this is set once and lifted by the returned Destroy handle.
-- @param buttonName: The HUD button's frame name, as HudController knows it
function TutorialController:SpotlightHudButton(buttonName: string): { Destroy: () -> () }
	local frame = HudController:GetHudButton(buttonName)
	if not frame then
		return EMPTY_HANDLE
	end

	local spotlight = self:GetSpotlight()
	-- Rectangle, always, for a UI target: it's the only shape that sizes the cutout to width *and*
	-- height, where the others square off the larger and turn a wide button into a tall hole.
	spotlight:SetShape("Rectangle")
	spotlight:FocusUI(frame, HUD_SPOTLIGHT_PADDING)
	spotlight:Show()

	return {
		Destroy = function()
			spotlight:Hide()
		end,
	}
end

-- Dims the screen to the hotbar slot a tool is in. The slot belongs to the backpack, so the frame is
-- asked for rather than worked out here. Takes a resolver because neither end holds still: a respawn
-- rebuilds the tool as a new instance, and a just-parented tool has no slot for a frame or two.
-- Returning nil hides the light, which is how a step drops it once the tool is in hand.
--
-- Re-aimed only when the frame changes -- FocusUI re-locks ancestors and rebinds its follow loop per call.
-- @param resolveTool: evaluated each frame for the tool whose slot to light, or nil for none
function TutorialController:SpotlightHotbarSlot(resolveTool: () -> Tool?): { Destroy: () -> () }
	local spotlight = self:GetSpotlight()
	local currentFrame

	local heartbeat = RunService.Heartbeat:Connect(function()
		local tool = resolveTool()
		local frame = tool and InventoryController:GetSlotFrame(tool)
		if frame == currentFrame then
			return
		end
		currentFrame = frame

		if not frame then
			spotlight:Hide()
			return
		end

		-- Rectangle for the same reason SpotlightHudButton uses one.
		spotlight:SetShape("Rectangle")
		spotlight:FocusUI(frame, HUD_SPOTLIGHT_PADDING)
		spotlight:Show()
	end)

	return {
		Destroy = function()
			heartbeat:Disconnect()
			spotlight:Hide()
		end,
	}
end

-- Forces a set of prompts off and holds them there against anything re-enabling them. The caller passes
-- an onRelease so the owning controller recomputes their real state, rather than this guessing it.
-- @param prompts: The prompts to hold disabled
-- @param onRelease: Called by Destroy, to let the prompts' owner recompute them
-- @param glows: Optional instances whose breathing highlight is held off alongside -- the glow is what
--   says a prompt is up, so shutting one without the other lights an interactable that does nothing
function TutorialController:DisablePrompts(
	prompts: { ProximityPrompt },
	onRelease: () -> (),
	glows: { Instance }?
): { Destroy: () -> () }
	local connections = {}

	for _, prompt in prompts do
		prompt.Enabled = false

		table.insert(
			connections,
			prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
				if prompt.Enabled then
					prompt.Enabled = false
				end
			end)
		)
	end

	-- A tag has no per-instance changed signal, so the glows are swept per frame. Not off
	-- CollectionService's added signal: it's deferred, so every re-tag got a frame or two on screen and
	-- the lever blinked through the run rather than staying dark.
	local heartbeat
	if glows then
		heartbeat = RunService.Heartbeat:Connect(function()
			for _, instance in glows do
				instance:RemoveTag(Highlights.TAG)
			end
		end)
	end

	return {
		Destroy = function()
			if heartbeat then
				heartbeat:Disconnect()
			end

			for _, connection in connections do
				connection:Disconnect()
			end

			onRelease()
		end,
	}
end

--
function TutorialController:OnInit()
	PlayerDataController = require(script.Parent.PlayerDataController)
	UIController = require(script.Parent.UIController)
	HudController = require(script.Parent.HudController)
	SoundController = require(script.Parent.SoundController)
	ConfettiController = require(script.Parent.ConfettiController)
	InventoryController = require(script.Parent.InventoryController)
	GrillStandShopController = require(script.Parent.GrillStandShopController)
	GrillerController = require(script.Parent.GrillerController)
	StickStandController = require(script.Parent.StickStandController)
	IngredientRollingController = require(script.Parent.IngredientRollingController)

	for _, variantFolder in script.Sequence:GetChildren() do
		local steps, count = {}, 0
		for _, sequence in variantFolder:GetChildren() do
			if not sequence:IsA("ModuleScript") then
				continue
			end

			steps[sequence.Name] = require(sequence)
			count += 1
		end

		self._sequences[variantFolder.Name] = steps
		self._sequenceCounts[variantFolder.Name] = count
	end
end

function TutorialController:OnStart()
	PlayerDataController:GetReplica()
		:andThen(function(replica)
			if replica.Data.TutorialCompleted then
				return
			end

			-- Lands once the server has resolved the config behind it, a beat after the profile loads.
			while LocalPlayer:GetAttribute(VARIANT_ATTRIBUTE) == nil do
				LocalPlayer:GetAttributeChangedSignal(VARIANT_ATTRIBUTE):Wait()
			end

			-- A variant the server assigned that this build has no steps for. Sitting it out beats
			-- running an empty sequence: Start with no steps walks its prologue straight into the finish,
			-- and TutorialCompleted is written for good.
			local variant = LocalPlayer:GetAttribute(VARIANT_ATTRIBUTE)
			if not self._sequences[variant] then
				warn(`TutorialController: no Sequence folder for variant "{variant}"`)
				return
			end

			self:Start(variant)
		end)
		:catch(warn)
end

return TutorialController
