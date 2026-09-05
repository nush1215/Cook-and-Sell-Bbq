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
local BuildController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- Runs the onboarding sequence: plays each step in order and lends steps the banner, spotlight, beams and glows they point with.

--
local NEAR_DISTANCE = 12

-- A prompt is either a fixed string or a function evaluated each frame for live text.
type Prompt = string | (() -> string)

-- Gold pulsing fill for tutorial goals. Fill only -- a second opaque outline over the game's reads as a bug
local HIGHLIGHT_COLOR = Color3.fromRGB(255, 200, 40)
local HIGHLIGHT_MIN_FILL = 0.35
local HIGHLIGHT_MAX_FILL = 0.8
local HIGHLIGHT_PULSE_SPEED = 3

-- Never shares an adornee with BreathingHighlight, two Highlights on one instance being undefined
local PROMPT_HIGHLIGHT_TAG = "PromptSubjectHighlight"

-- Padding around a spotlit HUD button, in pixels. Shared with the hotbar slot cue.
local HUD_SPOTLIGHT_PADDING = 12

-- Where the server parks each base's tutorial guides, keyed by base name (see Base.new).
local GUIDES_FOLDER_NAME = "TutorialGuides"

-- The label over a guide, drifting wider than other billboards to catch an eye that doesn't know yet
local PLACE_HERE_LABEL_NAME = "TutorialPlaceHere"
local PLACE_HERE_FLOAT_AMPLITUDE = 0.5
local PLACE_HERE_FLOAT_SPEED = 5

-- The banner's text swap: drop the line this far below where it was authored, then spring it back up.
local TEXT_SLIDE_OFFSET = 0.052
local TEXT_SLIDE_DAMPING = 0.5
local TEXT_SLIDE_FREQUENCY = 3.5

-- Authored in the place file, so a miss is a build problem -- warn rather than hang the sequence
local ASSET_TIMEOUT = 10

-- The attribute the assigned variant is published on, once the server has resolved its config
local VARIANT_ATTRIBUTE = "TutorialVariant"

-- Handed back when an effect's asset is missing, so a step can call Destroy without checking.
local EMPTY_HANDLE = {
	Destroy = function() end,
}

-- Misses cached too, or every step wanting one absent asset would sit through its own timeout
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

-- Resolves a beam endpoint to whatever carries a world position. An attachment resolves to itself.
local function resolveBeamAnchor(target: Instance): (BasePart | Attachment)?
	if target:IsA("BasePart") or target:IsA("Attachment") then
		return target
	end

	-- Descendants, not children -- a structure is a model of models, so a shallow search comes back empty
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

	-- Every variant's steps: which one runs isn't known until the assignment replicates, and requiring only defines
	_sequences = {},
	_sequenceCounts = {},
}

-- Runs each sequence of `variant` in order, waiting on SequenceFinish, then plays the finish.
function TutorialController:Start(variant: string)
	local tutorialUI = PlayerGui:WaitForChild("TutorialUI", ASSET_TIMEOUT)
	if not tutorialUI then
		warn("TutorialController: PlayerGui.TutorialUI is missing -- the tutorial cannot run")
		return
	end

	self.TutorialUI = tutorialUI
	self.TutorialUI.Holder.Description.RichText = true
	UIController:OpenFrame(self.TutorialUI.Holder, true)

	-- The whole HUD, bar included -- a teleport mid-beat strands the player. A claim, since HideHud looks pressable
	HudController:KeepHudHidden(self)

	-- Hidden until the base is built, so nothing invites a press before the tutorial has spoken
	InventoryController:HideInventory()

	-- Shut for the whole run -- the store trip walks past its zone and it has nothing they need
	GrillStandShopController:SetLocked(true)

	-- Held start to finish: on a shared lock it returned during the very cook it was hidden through
	GrillerController:SetSkipLocked(true)

	-- Shut until the beat that asks for it -- the guaranteed roll burns on the first pull, wherever it lands
	IngredientRollingController:SetRollLocked(true)

	-- BaseId lands after the client has built, so say something rather than opening blank
	self:SetText("Tutorial", "Getting your stall ready...")
	self:GetBase()

	-- Back as soon as there's a stall: step 1 asks them to equip a griller off it.
	InventoryController:ShowInventory()

	self:LogStep("Start")

	local steps = self._sequences[variant]
	for i = 1, self._sequenceCounts[variant] do
		local sequence = steps[tostring(i)]
		if sequence then
			-- Connected before spawning: a step whose goal is already met fires before a Wait could be reached
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

	-- Released here rather than by the roll beat, so the run holds one lock instead of each beat taking its own
	if self.LeverLock then
		self.LeverLock.Destroy()
		self.LeverLock = nil
	end

	HudController:ReleaseHud(self)
	HudController:ShowHud()

	-- Both held from the top of the run, so they come off here with the HUD
	GrillStandShopController:SetLocked(false)
	GrillerController:SetSkipLocked(false)

	-- Released here, so the griller beat doesn't have to know about a lock it has no reason to hold
	StickStandController:SetPlaceLocked(false)

	-- Held from step 1 on, each build beat narrowing it to the structure it asks for
	BuildController:SetPlaceCategory(nil)

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

-- The local player's base if streamed in, else nil. Re-resolved -- a base streams back as a new instance.
function TutorialController:GetBaseIfPresent(): Model?
	if self.Base and self.Base.Parent then
		return self.Base
	end

	local baseId = LocalPlayer:GetAttribute("BaseId")
	local baseFolder = workspace:FindFirstChild("Base")
	self.Base = (baseId and baseFolder and baseFolder:FindFirstChild(baseId)) or nil

	return self.Base
end

-- One of the player's structures of `category`. BEWARE: blocks until they have one -- steps 1 and 2 are what make that safe.
function TutorialController:GetStructure(category: string): Model
	local base = self:GetBase()
	local folder = base:WaitForChild(Structures.FOLDER_NAME)

	while true do
		for _, model in folder:GetChildren() do
			if model:HasTag(category) then
				return model
			end
		end

		-- The tag goes on last, so waiting on it is what guarantees the model is ready to point at
		CollectionService:GetInstanceAddedSignal(category):Wait()
	end
end

-- The build tool carried for `category`, re-resolved since BuildManager rebuilds the backpack each spawn.
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

-- Logs a funnel step by Key; the server owns the ordering and the names.
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

-- Colours a banner keyword off Config.Keywords, the same table notifications use, so a word reads alike.
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

	-- The authored position is the rest pose, so the banner can be moved in Studio without retuning here
	if not self._descriptionPosition then
		self._descriptionPosition = label.Position
	end

	Spr.stop(label)

	label.Position = self._descriptionPosition + UDim2.fromScale(0, TEXT_SLIDE_OFFSET)
	Spr.target(label, TEXT_SLIDE_DAMPING, TEXT_SLIDE_FREQUENCY, { Position = self._descriptionPosition })

	label.Text = description
end

-- Runs ordered guards then an optional goal, re-checked each frame so undoing a requirement brings its prompt back.
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

	-- By stage index, not the text -- a Description reading live state rewrites itself for nothing
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

-- Whether the character is within `distance` of the target's pivot. Pass an attachment for prompt range.
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

-- Glows a goal gold until the handle is destroyed. Pass a resolver for one that's rebuilt mid-step.
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

-- Marks a goal with the game's own breathing highlight, so acting on it teaches no second visual language.
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

		-- Every frame, since the owning system re-adds its cue on any world change and the two can't share an adornee
		if tagged then
			tagged:RemoveTag(PROMPT_HIGHLIGHT_TAG)
		end
	end)

	return {
		-- Not restored: these goals are gone by the step's end, and the owning system re-tags anything that isn't
		Destroy = function()
			heartbeat:Disconnect()
			untag()
		end,
	}
end

-- Draws a beam to a goal, hidden within hideDistance. Beam and attachment live on Terrain, so streaming can't wipe them.
function TutorialController:CreateBeam(
	target: Instance | (() -> Instance?),
	hideDistance: number
): { Destroy: () -> () }
	local template = getTutorialAsset("TutorialBeam")
	if not template then
		return EMPTY_HANDLE
	end

	-- Wrapped so the rest of the function always resolves through a function
	local resolveTarget: () -> Instance? = if type(target) == "function"
		then target :: () -> Instance?
		else function()
			return target :: Instance
		end

	-- A static target with no anchor is a wiring bug; a resolver may legitimately return nil
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

	-- Cached so the per-frame cost is the resolver call, re-resolved when the instance changes
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

-- Reparents a parked tutorial guide into the world and hands back its Model, or nil if unauthored.
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

	-- Hung on the guide so it travels with it, bobbed by PartFloat with no spin -- a billboard already faces you
	local labelTemplate = UI:FindFirstChild(PLACE_HERE_LABEL_NAME)
	local label
	if labelTemplate then
		-- On the model, not a part: guides carry no PrimaryPart, and on the model the CFrame is already world space
		label = labelTemplate:Clone()
		label.Parent = guide

		-- The authored offset is kept, since label height over a ghost is a thing to nudge in Studio
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
			-- Before the guide is parked, or it rides back in and the next ShowGuide hangs a second label
			if label then
				label:Destroy()
			end

			-- Parked, not destroyed -- the reparent was local, so destroying would cost a second run its guide
			guide.Parent = baseGuides
		end,
	}
end

-- Dims the screen to one HUD button. FocusUI binds its own follow loop, so this is set once.
function TutorialController:SpotlightHudButton(buttonName: string): { Destroy: () -> () }
	local frame = HudController:GetHudButton(buttonName)
	if not frame then
		return EMPTY_HANDLE
	end

	local spotlight = self:GetSpotlight()
	-- Rectangle for a UI target -- the only shape that sizes to width and height rather than squaring off
	spotlight:SetShape("Rectangle")
	spotlight:FocusUI(frame, HUD_SPOTLIGHT_PADDING)
	spotlight:Show()

	return {
		Destroy = function()
			spotlight:Hide()
		end,
	}
end

-- Dims to a tool's hotbar slot, via a resolver since neither the tool nor its slot holds still. Nil hides it.
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

		-- Rectangle for the same reason SpotlightHudButton uses one
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

-- Holds prompts disabled against anything re-enabling them; onRelease lets their owner recompute the real state.
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

	-- Swept per frame, not off CollectionService's deferred signal, which let the lever blink through the run
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
	BuildController = require(script.Parent.BuildController)

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

			-- Lands once the server has resolved the config behind it, a beat after the profile loads
			while LocalPlayer:GetAttribute(VARIANT_ATTRIBUTE) == nil do
				LocalPlayer:GetAttributeChangedSignal(VARIANT_ATTRIBUTE):Wait()
			end

			-- Sitting out beats running an empty sequence, which would walk straight to the finish and write it for good
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
