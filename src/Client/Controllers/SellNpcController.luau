-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local RandomUtil = require(Shared.RandomUtil)
local Animations = require(Shared.Animations)
local SellNpc = require(Shared.Config.SellNpc)
local NpcDialogue = require(Shared.Config.NpcDialogue)

-- Modules
local Modules = script.Parent.Parent.Modules
local BubbleChat = require(Modules.BubbleChat)

-- Controllers
local UIController

-- Assets
local UI = ReplicatedStorage.Assets.UI

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- The colour the offered amount is shown in on the offer frame, and the bonus badge beside it.
local OFFER_AMOUNT_COLOR = "#55ff00"
local OFFER_BONUS_COLOR = "#ffd400"

-- The billboard rises BUBBLE_CLEARANCE studs per active bubble, so it clears the stack and steps back
local BUBBLE_CLEARANCE = 0
local RAISE_DAMPING = 0.7
local RAISE_FREQUENCY = 3

-- The Title's pulse per swap. The flip decelerates, so the pulses come fast then settle on the verdict
local PULSE_START_INITIAL = 0.9 -- the bubble's first appearance
local PULSE_START_SWAP = 0.9 -- every verdict swap after the first
local PULSE_TARGET = 1
local PULSE_DAMPING = 0.5 -- < 1 for a little overshoot, so each swap pops
local PULSE_FREQUENCY = 6

-- Once a customer is interested the chat bubble carries the message, so the decide frame fades itself out.
local INTERESTED_FADE_TWEEN_INFO = TweenInfo.new(1, Enum.EasingStyle.Sine)

-- The two verdicts the Title flips between (and lands on).
local INTERESTED = {
	Text = "Interested",
	TextColor = Color3.fromRGB(0, 255, 0),
	StrokeColor = Color3.fromRGB(0, 42, 0),
}
local NOT_INTERESTED = {
	Text = "Not Interested",
	TextColor = Color3.fromRGB(255, 0, 0),
	StrokeColor = Color3.fromRGB(85, 0, 0),
}

-- Draws a sell-stand customer's billboards: the decide flip, its dialogue bubbles, and the offer frame the owner answers on.

--
local SellNpcController = {
	NpcDecideEvent = Network.Event("NpcDecide"),
	NpcRichArriveEvent = Network.Event("NpcRichArrive"),
	NpcOfferEvent = Network.Event("NpcOffer"),
	NpcOfferEndEvent = Network.Event("NpcOfferEnd"),
	NpcOfferResponseEvent = Network.Event("NpcOfferResponse"),
	NpcSayEvent = Network.Event("NpcSay"),

	-- (npc, offerFrame) whenever an offer frame goes up, including a counter-offer re-arming the same one.
	OnOfferShown = Signal.new(),
	-- (npc) once the haggle is over, however it ended.
	OnOfferEnded = Signal.new(),

	_active = {}, -- [npc] = { trove, running, decideFrame, offerFrame, speak, ... } -- one live set of billboards per NPC
}

-- The billboards' ScreenGui. In PlayerGui adorned back onto the NPC, which is what makes buttons clickable.
local function getScreenGui(): ScreenGui
	local screenGui = PlayerGui:FindFirstChild("NpcBillboards")
	if screenGui == nil then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "NpcBillboards"
		screenGui.ResetOnSpawn = false
		screenGui.Parent = PlayerGui
	end

	return screenGui
end

-- Paints the Title with one verdict. Direct assignment, so a fast flip lands crisply rather than smearing.
local function applyVerdict(title: TextLabel, stroke: UIStroke, verdict)
	title.Text = verdict.Text
	title.TextColor3 = verdict.TextColor
	stroke.Color = verdict.StrokeColor
end

-- Snaps the Title scale down to `startScale`, then springs it back to 1 -- the per-swap pop.
local function pulseScale(scale: UIScale, startScale: number)
	Spr.stop(scale, "Scale")
	scale.Scale = startScale
	Spr.target(scale, PULSE_DAMPING, PULSE_FREQUENCY, { Scale = PULSE_TARGET })
end

-- Tears down the NPC's billboards, springs and flip loop.
function SellNpcController:_cleanup(npc: Model)
	local state = self._active[npc]
	if not state then
		return
	end

	self._active[npc] = nil
	state.running = false
	state.trove:Destroy()
end

-- Builds a customer's billboards and dialogue state. Split from _playDecide, which a rich customer skips.
function SellNpcController:_attachNpcBillboards(npc: Model, dialogueVariant: string?, dialoguePrefix: string)
	local head = npc:FindFirstChild("Head") or npc:FindFirstChild("HumanoidRootPart")
	if not head then
		return nil
	end

	-- Cloned only to read the two billboards and the authored head offset, then dropped
	local holder = UI.NPCUIAttachment:Clone()
	local decideUI, offerUI = holder.DecideUI, holder.OfferUI
	local decideFrame = decideUI.DecideFrame
	local offerFrame = offerUI.OfferFrame
	local title = decideFrame.Title
	local stroke = title.UIStroke
	local scale = title.UIScale

	local restOffset = holder.Position

	-- Enabled for life, their frames carrying visibility; both start hidden until their beat raises them
	decideFrame.Visible = false
	offerFrame.Visible = false

	-- Adorned to the head, not an attachment -- an Attachment adornee cost the offer buttons every touch tap
	local screenGui = getScreenGui()
	for _, billboard in { decideUI, offerUI } do
		billboard.Adornee = head
		billboard.StudsOffsetWorldSpace = restOffset
		-- Zeroed: both scale with adornee size, so what did nothing on an Attachment would shift it on a head
		billboard.ExtentsOffset = Vector3.zero
		billboard.ExtentsOffsetWorldSpace = Vector3.zero
		billboard.Active = true
		billboard.Parent = screenGui
	end

	holder:Destroy()

	local trove = Trove.new()
	-- Both, since the billboards live in PlayerGui and nothing on the NPC takes them down with it
	trove:Add(decideUI)
	trove:Add(offerUI)
	-- Stop the springs before they're destroyed (Trove cleans in reverse add order)
	trove:Add(function()
		Spr.stop(scale)
		Spr.stop(decideUI)
		Spr.stop(offerUI)
	end)
	-- A pooled customer is reparented rather than destroyed, so AncestryChanged is what catches it
	trove:Connect(npc.AncestryChanged, function()
		if npc.Parent == nil then
			self:_cleanup(npc)
		end
	end)
	trove:Connect(npc.Destroying, function()
		self:_cleanup(npc)
	end)

	local state = {
		trove = trove,
		running = true,
		bubbleCount = 0,
		dialogueVariant = dialogueVariant,
		dialoguePrefix = dialoguePrefix,
		decideFrame = decideFrame,
		offerFrame = offerFrame,
		title = title,
		stroke = stroke,
		scale = scale,
	}
	self._active[npc] = state

	-- Springs the billboard clear of the current bubble stack, settling back as they expire
	local function updateRaise()
		local lift = restOffset + Vector3.new(0, BUBBLE_CLEARANCE * state.bubbleCount, 0)
		Spr.target(decideUI, RAISE_DAMPING, RAISE_FREQUENCY, { StudsOffsetWorldSpace = lift })
		Spr.target(offerUI, RAISE_DAMPING, RAISE_FREQUENCY, { StudsOffsetWorldSpace = lift })
	end

	-- Every beat funnels through here, so passing the cook state makes the whole exchange react to the skewer
	local function speak(category: string)
		local duration = BubbleChat.SayRandom(head, category, state.dialogueVariant)
		if not duration then
			return
		end

		state.bubbleCount += 1
		updateRaise()

		task.delay(duration, function()
			if state.running then
				state.bubbleCount -= 1
				updateRaise()
			end
		end)
	end

	-- Exposed so the server can drive later beats through the same bubble-raise bookkeeping
	state.speak = speak

	return state
end

-- Runs the decide flip, pacing off the time left so it decelerates onto `decideAt`.
function SellNpcController:_playDecide(npc: Model, interested: boolean, decideAt: number, dialogueVariant: string)
	if not npc or self._active[npc] then
		return
	end

	local state = self:_attachNpcBillboards(npc, dialogueVariant, "NPC")
	if not state then
		return
	end

	local trove = state.trove
	local decideFrame = state.decideFrame
	local title, stroke, scale = state.title, state.stroke, state.scale

	decideFrame.Visible = true
	scale.Scale = PULSE_START_INITIAL -- start small so the first flip springs it up

	state.speak("NPCDeciding")

	task.spawn(function()
		local duration = decideAt - workspace:GetServerTimeNow()
		local firstFlip = true
		local showInterested = false

		while state.running do
			local timeLeft = decideAt - workspace:GetServerTimeNow()
			if timeLeft <= 0 then
				break
			end

			showInterested = not showInterested
			applyVerdict(title, stroke, if showInterested then INTERESTED else NOT_INTERESTED)
			pulseScale(scale, if firstFlip then PULSE_START_INITIAL else PULSE_START_SWAP)
			firstFlip = false

			-- The gap grows from INITIAL to MAX off the time left, and never overshoots the landing
			local elapsedFraction = if duration > 0 then math.clamp(1 - timeLeft / duration, 0, 1) else 1
			local waitTime = SellNpc.DECIDE_INITIAL_WAIT
				+ (SellNpc.DECIDE_MAX_WAIT - SellNpc.DECIDE_INITIAL_WAIT) * elapsedFraction
			task.wait(math.min(waitTime, timeLeft))
		end

		if not state.running then
			return
		end

		-- Land on the real verdict with a final pulse and the verdict line
		applyVerdict(title, stroke, if interested then INTERESTED else NOT_INTERESTED)
		pulseScale(scale, PULSE_START_SWAP)
		state.speak(if interested then "NPCInterested" else "NPCNotInterested")

		-- The bubble carries the message from here, and the offer frame owns the billboard
		if interested then
			task.delay(2, function()
				if not state.running then
					return
				end

				local tween = TweenService:Create(decideFrame, INTERESTED_FADE_TWEEN_INFO, { GroupTransparency = 1 })
				trove:Connect(tween.Completed, function()
					decideFrame.Visible = false
				end)
				tween:Play()
			end)
		end
	end)
end

-- Sets a rich customer up on arrival: it runs no decide beat, so this only builds its billboards and entrance line.
function SellNpcController:_showRichArrival(npc: Model)
	if not npc or self._active[npc] then
		return
	end

	-- No cook state: its haul mixes them, so its lines come from the plain RichNPC categories
	local state = self:_attachNpcBillboards(npc, nil, "RichNPC")
	if not state then
		return
	end

	state.speak("RichNPCArrived")
end

-- Opens or updates the offer frame. Owner only, and `payout` is the boosted figure the sale actually banks.
function SellNpcController:_showOffer(npc: Model, payout: number, count: number, bonus: number)
	local state = self._active[npc]
	if not state or not state.running then
		return
	end

	local offerFrame = state.offerFrame

	-- From the cook state's own set, so a lowball on a burnt skewer says why; the last line is skipped
	local amount = `<font color="{OFFER_AMOUNT_COLOR}">${GuiUtil.ConvertNumberWithSuffix(payout)}</font>`

	-- Only shown when there's something to show -- "[+0%]" says less than no badge at all
	if bonus > 0 then
		amount ..= ` <font color="{OFFER_BONUS_COLOR}">[+{bonus}%]</font>`
	end

	local category = `{state.dialoguePrefix}Offer`
	local line = RandomUtil.GetRandomFromArray(NpcDialogue.GetLines(category, state.dialogueVariant), state.lastOfferLine)
	state.lastOfferLine = line

	-- A function replacement, since the bonus badge carries a '%' that gsub would read as an escape
	local title = offerFrame.Title
	title.RichText = true
	title.Text = (line:gsub("{amount}", function()
		return amount
	end):gsub("{count}", tostring(count)))

	local buttons = offerFrame.Buttons
	local accept, decline = buttons.Accept, buttons.Decline

	-- Bind once; a counter-offer just re-arms the same buttons
	if not state.offerBound then
		state.offerBound = true

		local function answer(accepted: boolean)
			if state.answered then
				return
			end
			state.answered = true
			accept.Active, decline.Active = false, false

			self.NpcOfferResponseEvent:FireServer(npc, accepted)
		end

		-- On press, not release -- the buttons ride an animated head and can drift out from under a finger
		state.trove:Add(UIController:BindButtonClick(accept, function()
			answer(true)
		end, true, nil, nil, true).Disconnect)
		state.trove:Add(UIController:BindButtonClick(decline, function()
			answer(false)
		end, true, nil, nil, true).Disconnect)
	end

	state.answered = false
	accept.Active, decline.Active = true, true
	offerFrame.Visible = true

	self.OnOfferShown:Fire(npc, offerFrame)
end

-- Takes the offer frame down once the haggle is over, however it ended.
function SellNpcController:_hideOffer(npc: Model)
	local state = self._active[npc]
	if not state then
		return
	end

	state.answered = true
	state.offerFrame.Visible = false

	self.OnOfferEnded:Fire(npc)
end

-- Preloads every customer animation so the first eat or inspect doesn't hitch. Yields, so it's spawned.
function SellNpcController:_preloadAnimations()
	local animations = {}
	for _, ids in Animations.Npc do
		for _, animationId in ids do
			local animation = Instance.new("Animation")
			animation.AnimationId = animationId
			table.insert(animations, animation)
		end
	end

	ContentProvider:PreloadAsync(animations)

	for _, animation in animations do
		animation:Destroy()
	end
end

function SellNpcController:OnInit()
	UIController = require(script.Parent.UIController)
end

function SellNpcController:OnStart()
	-- Warm the customer animations up front so the first eat or inspect doesn't hitch
	task.spawn(function()
		self:_preloadAnimations()
	end)

	self.NpcDecideEvent:OnClientEvent(function(npc: Model, interested: boolean, decideAt: number, dialogueVariant: string)
		self:_playDecide(npc, interested, decideAt, dialogueVariant)
	end)

	self.NpcRichArriveEvent:OnClientEvent(function(npc: Model)
		self:_showRichArrival(npc)
	end)

	self.NpcOfferEvent:OnClientEvent(function(npc: Model, payout: number, count: number, bonus: number)
		self:_showOffer(npc, payout, count, bonus)
	end)

	self.NpcOfferEndEvent:OnClientEvent(function(npc: Model)
		self:_hideOffer(npc)
	end)

	-- The server drives the later dialogue beats, since it owns their timing
	self.NpcSayEvent:OnClientEvent(function(npc: Model, category: string)
		local state = self._active[npc]
		if state and state.running and state.speak then
			state.speak(category)
		end
	end)
end

return SellNpcController
