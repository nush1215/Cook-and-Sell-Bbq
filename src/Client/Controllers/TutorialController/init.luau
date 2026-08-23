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

-- Controllers
local PlayerDataController
local UIController
local HudController
local SoundController
local ConfettiController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

--[[
    Drives the onboarding sequence. Everything the player is told and everything that decides they've
    done it lives here and in Sequence/1..14 -- the server only owns the finished flag, the funnel, and
    the two things a client can't be trusted with (what the first roll lands on, and that the customer
    at the end turns up and buys).

    A step is a ModuleScript under Sequence named for its position, returning one function that gets
    this controller as `self` and runs imperatively until it fires SequenceFinish. Steps own their own
    teardown: every effect factory here hands back a { Destroy } the step is expected to call.

    The one primitive worth understanding is AwaitGoal. A step isn't "wait for event X" -- it's an
    ordered list of conditions re-checked every frame, showing the prompt for the first one that isn't
    met. Walk away from the griller and the banner goes back to telling you to come back to it; unequip
    the stick and it goes back to telling you to hold it. That's what stops the tutorial reading as a
    checklist that's lost track of where the player actually is.
]]

--
local NEAR_DISTANCE = 12

-- A prompt is either a fixed string or a function evaluated each frame for live text.
type Prompt = string | (() -> string)

-- Gold pulsing fill used to mark tutorial goals. Fill only -- the grills and stands already carry the
-- game's own BreathingHighlight, and a second opaque outline on top of it reads as a bug.
local HIGHLIGHT_COLOR = Color3.fromRGB(255, 200, 40)
local HIGHLIGHT_MIN_FILL = 0.35
local HIGHLIGHT_MAX_FILL = 0.8
local HIGHLIGHT_PULSE_SPEED = 3

-- The prompt's own outline cue. BreathingHighlight must never share an adornee with it -- two Highlights
-- on one instance is undefined, and Roblox renders whichever of them it likes -- so anything the tutorial
-- sets breathing has this taken off it.
local PROMPT_HIGHLIGHT_TAG = "PromptSubjectHighlight"

-- Breathing room left around a spotlit HUD button, in pixels.
local HUD_SPOTLIGHT_PADDING = 12

-- The banner's text swap: drop the line this far below where it was authored, then spring it back up.
local TEXT_SLIDE_OFFSET = 0.052
local TEXT_SLIDE_DAMPING = 0.5
local TEXT_SLIDE_FREQUENCY = 3.5

-- How long to wait on an authored asset before giving up on it. These are built in the place file, so
-- a miss is a build problem rather than slow replication -- warn and carry on without that one effect
-- instead of hanging the whole sequence waiting for something that is never coming.
local ASSET_TIMEOUT = 10

-- A no-op handle, handed back by the effect factories when their asset is missing so a step can still
-- call Destroy on it without checking.
local EMPTY_HANDLE = {
	Destroy = function() end,
}

-- Resolved tutorial assets, including the misses. A miss is cached too: without it every step that
-- wanted the same absent asset would sit through its own timeout, turning one build mistake into a
-- tutorial that crawls rather than one that plainly says what's missing.
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

-- Resolves a beam endpoint down to whatever carries its world position: an attachment or part as-is, a
-- model by its primary part, anything else by the first part under it.
--
-- An attachment resolves to itself rather than through to the part it sits on, because marking a spot on
-- that part is the entire point of aiming at one. The grill's prompt hangs off an attachment at the
-- corner the player has to stand at, while the griller model's own centre is somewhere they can't reach
-- it from -- so a beam that resolved through would land them next to the thing rather than at it.
local function resolveBeamAnchor(target: Instance): (BasePart | Attachment)?
	if target:IsA("BasePart") or target:IsA("Attachment") then
		return target
	end

	if target:IsA("Model") then
		return target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart")
	end

	return target:FindFirstChildWhichIsA("BasePart", true)
end

-- Where a resolved anchor sits in the world. An attachment carries a world position of its own; a part
-- is its own position.
local function getAnchorPosition(anchor: BasePart | Attachment): Vector3
	return if anchor:IsA("Attachment") then anchor.WorldPosition else anchor.Position
end

--
local TutorialController = {
	FinishTutorialEvent = Network.Event("FinishTutorial"),
	LogStepEvent = Network.Event("LogTutorialStep"),

	SequenceFinish = Signal.new(),
	_sequences = {},
}

-- Runs each tutorial sequence in order, waiting for the active one to fire SequenceFinish before
-- moving on to the next, then plays the finish.
function TutorialController:Start()
	local tutorialUI = PlayerGui:WaitForChild("TutorialUI", ASSET_TIMEOUT)
	if not tutorialUI then
		warn("TutorialController: PlayerGui.TutorialUI is missing -- the tutorial cannot run")
		return
	end

	self.TutorialUI = tutorialUI
	self.TutorialUI.Holder.Description.RichText = true
	UIController:OpenFrame(self.TutorialUI.Holder, true)

	-- Everything but the top bar goes: that one keeps the Store and Base teleports, which the tutorial
	-- walks the player through pressing. A claim rather than HideHud on purpose -- HideHud also sets the
	-- flag that makes every HUD button ignore its click, which would leave those two teleports looking
	-- pressable and doing nothing. The claim only hides frames, and holds them hidden through any
	-- unrelated ShowHud elsewhere.
	HudController:KeepHudHidden(self, { "Top" })

	-- Every step reads off the local player's own base, and BaseId lands after the client has built, so
	-- the banner says something while that's still in flight rather than opening blank.
	self:SetText("Tutorial", "Getting your stall ready...")
	self:GetBase()

	self:LogStep("Start")

	local sequenceCount = #script.Sequence:GetChildren()
	for i = 1, sequenceCount do
		local sequence = self._sequences[tostring(i)]
		if sequence then
			-- Listen before the step is spawned, rather than waiting on the signal after. task.spawn runs
			-- the step synchronously up to its first yield, and a step whose goal is already met never
			-- yields at all -- the stick beat passes on the spot, because a bought stick is already in the
			-- player's hands. Such a step fires SequenceFinish before a :Wait() here could have been
			-- reached, the fire lands on nobody, and the tutorial sits forever on a beat it has passed.
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

	-- Handed back here rather than by the step that took it: step 1 shuts the lever on the pull that ends
	-- it and nothing between there and the finish wants it open, so the whole run is one lock rather than
	-- each beat taking and releasing its own.
	if self.LeverLock then
		self.LeverLock.Destroy()
		self.LeverLock = nil
	end

	HudController:ReleaseHud(self)
	HudController:ShowHud()

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

-- Returns the local player's own base model, blocking until it's been assigned. Every step's targets
-- hang off this, and it never changes for the life of the session, so it's resolved once and kept.
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

-- The local player's base if it is currently streamed in, else nil. Non-blocking, so a per-frame check
-- can test against it without stalling inside a WaitForChild for a base that isn't there -- which would
-- hold the check's whole thread and leave it unable to notice anything else finishing the beat.
--
-- Re-resolves whenever the model it kept has left the world: a base the player travelled away from
-- streams out and comes back as a brand-new instance, leaving the old one parentless and every
-- reference taken into it dead.
function TutorialController:GetBaseIfPresent(): Model?
	if self.Base and self.Base.Parent then
		return self.Base
	end

	local baseId = LocalPlayer:GetAttribute("BaseId")
	local baseFolder = workspace:FindFirstChild("Base")
	self.Base = (baseId and baseFolder and baseFolder:FindFirstChild(baseId)) or nil

	return self.Base
end

-- Returns one of the player's structures of the given kind, blocking until there is one. Grillers and
-- stands are things the player builds rather than slots authored into a base (see Config.Structures),
-- so a step can't reach for a fixed path -- it asks for a griller and gets whichever one they have.
--
-- Keyed on the category rather than a structure id, so a step still finds the player's only griller
-- when that griller is some later model of one.
--
-- BEWARE: this blocks until the player has one, and nothing gives them a starting build any more --
-- so a step calling it before the player has built the thing it wants waits forever, and the funnel
-- stops dead there. Whatever re-enables the tutorial (data.TutorialCompleted starts true today, so it
-- doesn't run) has to make building a griller and a stand steps of its own, ahead of steps 8-14.
function TutorialController:GetStructure(category: string): Model
	local base = self:GetBase()
	local folder = base:WaitForChild(Structures.FOLDER_NAME)

	while true do
		for _, model in folder:GetChildren() do
			if model:HasTag(category) then
				return model
			end
		end

		-- The tag goes on last, after the model is parented and its attributes are set, so a structure
		-- arriving is not the same moment as it becoming findable. Waiting on the tag rather than the
		-- child is what makes sure the one handed back is ready to be pointed at.
		CollectionService:GetInstanceAddedSignal(category):Wait()
	end
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

-- Colours a keyword for the banner, so a line can name the thing to go and find without spelling out
-- which of its words matters. Every step's text goes through this rather than styling its own.
--
-- A keyword that names an object takes that object's colour from Config.Keywords, looked up here rather
-- than passed in by each step: "BBQ" is written in six places and "Griller" in four, and a colour they
-- each carried their own copy of would drift the first time one of them was retuned. The same table is
-- what notifications colour themselves from, so a word reads the same in the banner and in a toast.
-- @param color: Optional override, for a keyword whose colour is already authored somewhere. An
--   ingredient or a stick is named in the same colour its own labels carry everywhere else, so the
--   banner and the thing it is pointing at read as one item rather than two that share a name.
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

	-- Where the label was authored is where it rests, so the banner can be moved in Studio without the
	-- slide needing to be retuned here.
	if not self._descriptionPosition then
		self._descriptionPosition = label.Position
	end

	Spr.stop(label)

	label.Position = self._descriptionPosition + UDim2.fromScale(0, TEXT_SLIDE_OFFSET)
	Spr.target(label, TEXT_SLIDE_DAMPING, TEXT_SLIDE_FREQUENCY, { Position = self._descriptionPosition })

	label.Text = description
end

-- Drives an ordered list of guard conditions, always showing the prompt of the first one that is
-- currently unsatisfied. Guards are re-checked every frame, so if the player undoes an earlier
-- requirement (walks away, unequips, leaves the shop, ...) the matching prompt is shown again. Once
-- every guard holds, the optional goal prompt is shown and AwaitGoal returns when the goal is reached.
-- A Description may be a function so the prompt can change with live state.
--
-- Getting past a guard plays the same sound finishing a step does, because it is the same thing from the
-- player's side -- "Go to your Stall" giving way to "Place your BBQ" is them having done what was asked.
-- Only ever on the way forward, and only the first time each one is passed: guards are re-checked every
-- frame and the player is free to undo them, so without that a walk out of range and back would sound
-- like a fresh win every lap.
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

	-- How far into the beat the player has got: the index of the guard they're held on, or one past the
	-- last guard once they're on the goal. Tracked by stage rather than by the text shown, because a
	-- Description that reads off live state rewrites itself without anything having been achieved.
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
			-- Silent on the first stage: arriving at it is the step opening, and the step before it has
			-- already played its own finish.
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

-- Returns whether the local character is currently within distance of the target. Measured from the
-- target's pivot, so a whole griller or stand model can be passed as-is rather than each step having to
-- pick a representative part out of it.
--
-- An attachment may be passed instead, and is measured from where it sits in the world. That's for beats
-- whose "are they there yet" is really "are they close enough to press the prompt" -- the prompt hangs
-- off an attachment somewhere on the model, and a model wide enough for that to differ (the griller) has
-- a pivot the player can be well within while standing nowhere near the part they interact with.
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

-- Adorns a gold pulsing highlight onto a part or model to mark a goal. Only the fill is shown, and it
-- breathes between HIGHLIGHT_MIN_FILL and HIGHLIGHT_MAX_FILL until the handle's Destroy is called.
--
-- A resolver may be passed in place of a fixed adornee, for a goal that isn't there yet or is rebuilt
-- while the step runs -- the rolled ingredient is both. The highlight then lives on Terrain and re-points
-- its Adornee rather than being parented into the goal: parented there it would be destroyed along with
-- it, and the rolling cycle destroys and re-clones a model per step before the real one settles. It
-- simply hides itself while the resolver has nothing to point at.
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

-- Sets the game's own breathing highlight on a goal, rather than the tutorial's gold pulse. Used where
-- the goal is a thing the player is about to act on rather than somewhere they have to walk to, so the
-- tutorial marks it the way the rest of the game already marks everything actionable instead of teaching
-- a second visual language for the same idea.
--
-- Takes a resolver like CreateBeam, and moves the tag as the resolved goal changes: the rolled ingredient
-- is destroyed and re-cloned once per cycle step before the real one settles.
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

		-- Taken off every frame rather than once on tagging: the owning system recomputes its prompt cue
		-- off world state and puts this back whenever that changes, and the two can't share an adornee.
		if tagged then
			tagged:RemoveTag(PROMPT_HIGHLIGHT_TAG)
		end
	end)

	return {
		-- The prompt's cue isn't handed back, because there is nothing to hand it back to: the goals this
		-- marks are gone by the time their step ends -- a bought ingredient leaves the stand with the
		-- purchase that ended the step -- and the owning system re-tags anything that isn't.
		Destroy = function()
			heartbeat:Disconnect()
			untag()
		end,
	}
end

-- Draws a beam from the local character to a goal, pointing the way to it. The beam hides itself once
-- the player is within hideDistance and shows again when they wander back out. Handles respawns by
-- re-binding to the new character.
--
-- The beam and its goal-side attachment are anchored to Terrain -- always streamed in, and stable
-- across respawns -- rather than to the goal part, and that attachment is pinned onto the goal each
-- frame. Under StreamingEnabled a part (and every client instance parented beneath it) is wiped when
-- it streams out, so a beam parented to the goal would vanish precisely when the goal is far enough to
-- need pointing at, never to return (the goal streams back in as a brand-new instance). Anchoring to
-- Terrain keeps the beam alive; it merely hides while the goal is absent and re-acquires it on return.
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

	-- A static target with nothing to anchor to is a wiring bug; warn once. A resolver may legitimately
	-- return nil while the goal is streamed out, so it is not checked here.
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

	-- Cache the anchor resolved for a goal, so the per-frame work is the resolver call rather than a walk
	-- down the goal's descendants. Re-resolved whenever the resolver hands back a different instance --
	-- a goal that streamed out and came back as a new one, or a step that points somewhere else until its
	-- real goal appears -- and whenever the anchor cached for it has gone.
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

-- Dims the screen down to a single HUD button, for a beat that asks the player to press one. FocusUI
-- binds its own follow loop, so this is set once and lifted by the returned Destroy handle.
-- @param buttonName: The HUD button's frame name, as HudController knows it
function TutorialController:SpotlightHudButton(buttonName: string): { Destroy: () -> () }
	local frame = HudController:GetHudButton(buttonName)
	if not frame then
		return EMPTY_HANDLE
	end

	local spotlight = self:GetSpotlight()
	-- Rectangle, always, for a UI target. It's the only shape that sizes the cutout to the element's
	-- width *and* height -- every other one takes the larger of the two and squares it, which turns a
	-- wide button into a hole several times taller than the thing it's meant to be pointing at.
	spotlight:SetShape("Rectangle")
	spotlight:FocusUI(frame, HUD_SPOTLIGHT_PADDING)
	spotlight:Show()

	return {
		Destroy = function()
			spotlight:Hide()
		end,
	}
end

-- Forces a set of prompts off and holds them there against anything that re-enables them, so a beat
-- the player isn't meant to be able to take yet can't be taken. The owning controller recomputes its
-- prompts off world state whenever that state changes, and nothing changes while the player is being
-- held back -- so the caller passes an onRelease that hands control back rather than this guessing
-- what each prompt's state should be by the time it lets go.
-- @param prompts: The prompts to hold disabled
-- @param onRelease: Called by Destroy, to let the prompts' owner recompute them
-- @param glows: Optional instances whose breathing highlight is held off for as long as the prompts are.
--   The systems that own these tie the two together deliberately -- the glow is what says the prompt is
--   up -- so a beat that shuts one without the other leaves an interactable lit for something the player
--   can't actually do.
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

	-- A tag has no per-instance changed signal to hold against the way Enabled does, so the held glows are
	-- swept instead. Per frame rather than off CollectionService's added signal, which is what this used
	-- to listen to: that signal is deferred, so every re-tag got a frame or two on screen before the
	-- handler could take it back off -- and the owning systems re-tag off world state, which for the
	-- roller's lever means every time the player puts something down. The result was a lever that blinked
	-- through the run rather than one that was dark. Sweeping is a handful of instances a frame while a
	-- lock is held, and it can't be beaten to the draw.
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

	for _, sequence in script.Sequence:GetChildren() do
		if not sequence:IsA("ModuleScript") then
			continue
		end

		self._sequences[sequence.Name] = require(sequence)
	end
end

function TutorialController:OnStart()
	PlayerDataController:GetReplica()
		:andThen(function(replica)
			if not replica.Data.TutorialCompleted then
				self:Start()
			end
		end)
		:catch(warn)
end

return TutorialController
