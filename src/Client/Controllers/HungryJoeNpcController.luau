-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local RandomUtil = require(Shared.RandomUtil)
local Sticks = require(Shared.Config.Sticks)
local Highlights = require(Shared.Config.Highlights)
local Structures = require(Shared.Config.Structures)
local Employees = require(Shared.Config.Employees)
local NpcDialogue = require(Shared.Config.NpcDialogue)
local HungryJoeNpc = require(Shared.Config.HungryJoeNpc)

-- Modules
local Modules = script.Parent.Parent.Modules
local NpcBillboard = require(Modules.NpcBillboard)
local EquippedItem = require(Modules.EquippedItem)
local GuideBeam = require(Modules.GuideBeam)

-- Controllers
local UIController = require(script.Parent.UIController)

--
local LocalPlayer = Players.LocalPlayer

-- What his offer promises in place of a figure, since the feast is only worked out once his stick comes back
local OFFER_REWARD_TEXT = "GREAT REWARD"

-- The reward's rainbow: graphemes per trip round the colour wheel, how washed out the hues are, and graphemes a second it scrolls by
local GRAPHEMES_PER_COLOR_LOOP = 11
local COLOR_SATURATION = 1
local RAINBOW_SCROLL_SPEED = 8

-- The waiting text: the dots it cycles through while his clock is hidden, and seconds per step
local WAITING_DOTS = { "Waiting.", "Waiting..", "Waiting..." }
local WAITING_DOT_INTERVAL = 0.5

-- His countdown turns red in its last minute, matching the custom order timer
local TIMER_HURRY_THRESHOLD = 60
local TIMER_HURRY_COLOR = Color3.fromRGB(255, 65, 65)

-- The hand-over prompt. Generous, since he waits off to the side rather than at the stand
local DELIVER_PROMPT_DISTANCE = 14
local DELIVER_PROMPT_HOLD = 0.3
local DELIVER_DEBOUNCE = 1

-- `text` with each grapheme its own hue, starting `colorIndex` graphemes round the wheel. Spaces stay plain and don't use up a hue.
local function rainbowifyText(text: string, colorIndex: number): string
	local rainbowText = ""

	for first, last in utf8.graphemes(text) do
		local grapheme = text:sub(first, last)
		if grapheme == " " then
			rainbowText ..= grapheme
			continue
		end

		local color = Color3.fromHSV(colorIndex / GRAPHEMES_PER_COLOR_LOOP % 1, COLOR_SATURATION, 1):ToHex()
		rainbowText ..= `<font color="#{color}">{grapheme}</font>`
		colorIndex += 1
	end

	return rainbowText
end

-- Draws Hungry Joe's billboards: the offer card the owner answers his job on, and the waiting text with his countdown. Also owns the cue for handing his stick back: the prompt, his glow and a beam over to him.

--
local HungryJoeNpcController = {
	HungryJoeOfferResponseEvent = Network.Event("HungryJoeOfferResponse"),
	HungryJoeDeliverEvent = Network.Event("HungryJoeDeliver"),
	HungryJoeSayEvent = Network.Event("HungryJoeSay"),

	_active = {}, -- [npc] = { trove, running, offerFrame, waitingText, speak, ... } -- one live set per Hungry Joe
	-- [npc] = true while its billboards are being built. Attach waits on the rig's Head, so a beat sent
	-- in the same frame he lands can arrive before the state does
	_attaching = {},
	_hungryJoeTarget = nil, -- whichever Hungry Joe the held stick goes back to, glowing with a beam to him
	_beam = nil,
}

-- Tears down his billboards, the offer's rainbow and the hand-over prompt.
function HungryJoeNpcController:_cleanup(npc: Model)
	self._attaching[npc] = nil

	local state = self._active[npc]
	if not state then
		return
	end

	self._active[npc] = nil
	state.running = false

	-- Before the trove takes the billboards, since the pad's glyphs sit on their buttons
	NpcBillboard.UnregisterOffer(npc)

	state.trove:Destroy()

	-- Dropped from _active above, so this drops the beam too if he was the target
	self:_refreshHungryJoeTarget()
end

-- Builds his billboards, then draws whatever phase the rig is already carrying.
function HungryJoeNpcController:_attach(npc: Model)
	if self._active[npc] or self._attaching[npc] then
		return
	end

	-- Latched before Attach yields on the rig's Head, so the beats behind it know there's one coming
	self._attaching[npc] = true

	-- The waiting text lifts clear of his bubbles by the workers' clearance, the bubbles being the same size. The offer card stays put, so its buttons don't slide out from under a tap
	local state = NpcBillboard.Attach(npc, "HungryJoeNPCUIAttachment", nil, "HungryJoeNPC", {
		WaitingUI = Employees.BUBBLE_CLEARANCE,
	})

	-- The rig is stamped before it lands, but its client copy can carry the tag before the stamp
	local ownerUserId = npc:GetAttribute(Structures.OWNER_ATTRIBUTE)
	while ownerUserId == nil and npc.Parent do
		task.wait()
		ownerUserId = npc:GetAttribute(Structures.OWNER_ATTRIBUTE)
	end

	self._attaching[npc] = nil

	-- Only empty once the rig has left the world, so there's nothing left to draw on
	if not state then
		return
	end

	-- The rig can be destroyed while Attach waits on its Head, and the hooks below are connected too late to catch it
	if npc.Parent == nil then
		state.trove:Destroy()
		return
	end

	-- Their own, so the offer's rainbow, the waiting text's ticker and the hand-over prompt can each go when their phase ends without the bubbles
	state.offerTrove = state.trove:Construct(Trove)
	state.waitingTrove = state.trove:Construct(Trove)
	state.promptTrove = state.trove:Construct(Trove)

	state.offerFrame = state.billboards.OfferUI.OfferFrame
	state.waitingText = state.billboards.WaitingUI.WaitingText

	-- Read once, so the countdown can go back to it after the last minute's red
	state.waitingColor = state.waitingText.TextColor3

	-- Enabled for life, their contents carrying visibility; hidden until their phase raises them
	state.offerFrame.Visible = false
	state.waitingText.Visible = false

	state.trove:Connect(npc.AncestryChanged, function()
		if npc.Parent == nil then
			self:_cleanup(npc)
		end
	end)
	state.trove:Connect(npc.Destroying, function()
		self:_cleanup(npc)
	end)

	-- Read once, since a rig only ever visits the one base it was stamped for
	state.ownerUserId = ownerUserId

	self._active[npc] = state

	state.trove:Connect(npc:GetAttributeChangedSignal(HungryJoeNpc.PHASE_ATTRIBUTE), function()
		self:_render(npc)
	end)

	-- Seeded as well as connected, so a Hungry Joe already mid-visit when this client reached him draws now
	self:_render(npc)
end

-- His live set, waiting out an attach still in flight -- see _attaching.
function HungryJoeNpcController:_awaitState(npc: Model)
	while self._attaching[npc] do
		task.wait()
	end

	return self._active[npc]
end

-- The owner's Hungry Joe waiting on his stick, when what's in hand is that stick cooked and ready to give back, or nil.
function HungryJoeNpcController:_findHungryJoeTarget(): Model?
	local skewer = EquippedItem.GetSkewer()
	if
		not skewer
		or not skewer:GetAttribute("Cooked")
		or skewer:GetAttribute("StickId") ~= HungryJoeNpc.STICK_ID
	then
		return nil
	end

	for npc, state in self._active do
		if state.awaitingStick then
			return npc
		end
	end

	return nil
end

-- Moves the glow and the beam onto whichever Hungry Joe the held stick goes back to, or off him.
function HungryJoeNpcController:_refreshHungryJoeTarget()
	local target = self:_findHungryJoeTarget()
	if target == self._hungryJoeTarget then
		return
	end

	if self._hungryJoeTarget then
		self._hungryJoeTarget:RemoveTag(Highlights.TAG)
	end
	if self._beam then
		self._beam.Destroy()
		self._beam = nil
	end

	self._hungryJoeTarget = target

	if not target then
		return
	end

	target:SetAttribute("HighlightColor", Highlights.CLAIM)
	target:AddTag(Highlights.TAG)

	-- Hidden at the hand-over range, so the beam gives out exactly as the prompt comes in
	local beam = GuideBeam.Create(target, DELIVER_PROMPT_DISTANCE)

	-- The session's first beam waits on its template, so they can have put the stick down since
	if self._hungryJoeTarget ~= target then
		beam.Destroy()
		return
	end

	self._beam = beam
end

-- Watches the local character's tools so the cue tracks what they equip.
function HungryJoeNpcController:_watchCharacter(character: Model)
	self._characterCleaner:Clean()

	self._characterCleaner:Connect(character.ChildAdded, function(child)
		if child:IsA("Tool") then
			self:_refreshHungryJoeTarget()
		end
	end)
	self._characterCleaner:Connect(character.ChildRemoved, function(child)
		if child:IsA("Tool") then
			self:_refreshHungryJoeTarget()
		end
	end)

	self:_refreshHungryJoeTarget()
end

-- Raises his offer card, its reward scrolling through a rainbow for as long as it's up. Only its owner can answer it.
function HungryJoeNpcController:_showHungryJoeOffer(state, npc: Model, owned: boolean)
	local capacity = Sticks.GetStickFromId(HungryJoeNpc.STICK_ID).Capacity
	local line = RandomUtil.GetRandomFromArray(NpcDialogue.GetLines("HungryJoeNPCOffer"))

	-- Split round the reward once, so only that part is repainted each frame
	local before, after = string.match((line:gsub("{count}", tostring(capacity))), "^(.-){amount}(.*)$")

	local title = state.offerFrame.Title
	title.RichText = true

	-- A random start, so two cards side by side don't wear the same colours
	local startIndex = Random.new():NextNumber() * GRAPHEMES_PER_COLOR_LOOP
	local shownAt = os.clock()

	state.offerTrove:Connect(RunService.RenderStepped, function()
		local colorIndex = startIndex - (os.clock() - shownAt) * RAINBOW_SCROLL_SPEED
		title.Text = before .. rainbowifyText(OFFER_REWARD_TEXT, colorIndex) .. after
	end)

	local buttons = state.offerFrame.Buttons

	-- Someone else's Hungry Joe is display only, so a visitor gets the ask without the answer
	buttons.Visible = owned
	state.offerFrame.Visible = true

	-- Bound only for the owner: ownership can't turn over on a live visit, so there's nothing to keep wired
	if not owned then
		return
	end

	local accept, decline = buttons.Accept, buttons.Decline

	local function answer(accepted: boolean)
		if state.answered then
			return
		end
		state.answered = true
		accept.Active, decline.Active = false, false

		-- Off the pad the moment it's answered, whichever way the answer came in
		NpcBillboard.UnregisterOffer(npc)

		self.HungryJoeOfferResponseEvent:FireServer(npc, accepted)
	end

	-- On press, not release -- the buttons ride an animated head and can drift out from under a finger
	state.offerTrove:Add(UIController:BindButtonClick(accept, function()
		answer(true)
	end, true, nil, nil, true).Disconnect)
	state.offerTrove:Add(UIController:BindButtonClick(decline, function()
		answer(false)
	end, true, nil, nil, true).Disconnect)

	state.answered = false
	accept.Active, decline.Active = true, true

	NpcBillboard.RegisterOffer(npc, accept, decline, answer)
end

-- Takes his offer card down and stops its rainbow.
function HungryJoeNpcController:_hideHungryJoeOffer(state, npc: Model)
	state.answered = true
	state.offerFrame.Visible = false
	NpcBillboard.UnregisterOffer(npc)
	state.offerTrove:Clean()
end

-- Puts the hand-over prompt on him, so walking up with his stick is what gives it back.
function HungryJoeNpcController:_showDeliverPrompt(state, npc: Model)
	-- On a part, not the model -- a ProximityPrompt parented to a Model never fires at all
	local host = npc:FindFirstChild("HumanoidRootPart")
	if not host then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.RequiresLineOfSight = false
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.MaxActivationDistance = DELIVER_PROMPT_DISTANCE
	prompt.HoldDuration = DELIVER_PROMPT_HOLD
	prompt.ActionText = "Give BBQ"
	prompt.Parent = host

	state.promptTrove:Add(prompt)
	state.promptTrove:Connect(prompt.Triggered, function()
		-- Alongside the server's own guard, so a held button doesn't spend a request per frame
		if state.delivering then
			return
		end
		state.delivering = true

		self.HungryJoeDeliverEvent:FireServer(npc)

		-- Released rather than latched: a refused hand-over is answered and then over with, so they can try again
		task.delay(DELIVER_DEBOUNCE, function()
			state.delivering = false
		end)
	end)
end

-- Raises his waiting text for everyone: cycling dots while his clock is hidden, else the countdown, red in its last minute.
function HungryJoeNpcController:_showHungryJoeWaiting(state, npc: Model)
	local waitingText = state.waitingText
	waitingText.Visible = true

	-- Per frame rather than per second, so the last few seconds don't visibly stall on a hitch
	state.waitingTrove:Connect(RunService.Heartbeat, function()
		local deadline = npc:GetAttribute(HungryJoeNpc.CLOCK_ATTRIBUTE)

		local text, hurrying
		if deadline then
			local remaining = math.max(deadline - workspace:GetServerTimeNow(), 0)
			text = GuiUtil.ConvertSecondsToDHMS(remaining)
			hurrying = remaining <= TIMER_HURRY_THRESHOLD
		else
			text = WAITING_DOTS[math.floor(os.clock() / WAITING_DOT_INTERVAL) % #WAITING_DOTS + 1]
			hurrying = false
		end

		-- Only written on a change, since this runs far more often than the text moves
		if text ~= waitingText.Text then
			waitingText.Text = text
			waitingText.TextColor3 = if hurrying then TIMER_HURRY_COLOR else state.waitingColor
		end
	end)
end

-- Draws him against the phase he publishes, so every client sees the same visit his owner does.
function HungryJoeNpcController:_render(npc: Model)
	local state = self._active[npc]

	local phase = npc:GetAttribute(HungryJoeNpc.PHASE_ATTRIBUTE)
	if phase == state.phase then
		return
	end
	state.phase = phase

	local owned = state.ownerUserId == LocalPlayer.UserId

	if phase == HungryJoeNpc.PHASES.Offering then
		self:_showHungryJoeOffer(state, npc, owned)
		return
	end

	self:_hideHungryJoeOffer(state, npc)

	if phase == HungryJoeNpc.PHASES.Waiting then
		self:_showHungryJoeWaiting(state, npc)

		-- Owner only: the glow, the beam and the hand-over are all things nobody else can act on
		if owned then
			state.awaitingStick = true
			self:_showDeliverPrompt(state, npc)
			self:_refreshHungryJoeTarget()
		end
		return
	end

	-- Fed, turned away or out of patience, so the text and the prompt come down and the bubbles carry the last beats
	state.waitingText.Visible = false
	state.waitingTrove:Clean()
	state.awaitingStick = false
	state.promptTrove:Clean()
	self:_refreshHungryJoeTarget()
end

function HungryJoeNpcController:OnStart()
	self._characterCleaner = Trove.new()

	-- Equipping or unequipping his stick changes whether there's a Hungry Joe to cue
	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character: Model)
		self:_watchCharacter(character)
	end)

	-- A Hungry Joe on any base wires himself up here, whether he landed before this client or streams in later
	CollectionService:GetInstanceAddedSignal(HungryJoeNpc.TAG):Connect(function(npc: Model)
		self:_attach(npc)
	end)

	-- _attach waits on the rig's head, so the sweep is kept off this thread
	for _, npc in CollectionService:GetTagged(HungryJoeNpc.TAG) do
		task.spawn(function()
			self:_attach(npc)
		end)
	end

	-- The server drives the dialogue beats, since it owns their timing
	self.HungryJoeSayEvent:OnClientEvent(function(npc: Model, category: string)
		-- The arrival line goes out a frame after the rig lands, so it can beat the attach
		local state = self:_awaitState(npc)
		if state and state.running then
			state.speak(category)
		end
	end)
end

return HungryJoeNpcController
