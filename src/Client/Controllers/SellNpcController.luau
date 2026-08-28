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

-- The decide billboard sits above the NPC's chat bubbles: its attachment springs up BUBBLE_CLEARANCE
-- studs *per active bubble*, so it rises as bubbles stack up and steps back down as they expire.
local BUBBLE_CLEARANCE = 0
local RAISE_DAMPING = 0.7
local RAISE_FREQUENCY = 3

-- The Title's scale pulse on every text change: snap down to a start scale, then spring back to 1. The
-- flip cadence decelerates (see SellNpc config), so the pulses come fast then settle onto the verdict.
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

--[[
    Plays the "deciding" bubble over a sell-stall customer NPC's head.

    When a customer reaches the stand the server fires NpcDecide with the NPC, its verdict, and the
    server-time the decision lands at. This hangs NPCUIAttachment's billboards over the NPC and flips the Title
    between "Interested"/"Not Interested" -- pacing itself off the time left so the flips go fast at first
    then decelerate onto the landing (like the rolling stand) -- pulsing the Title's scale down-then-back
    on every swap. At the timestamp it lands on the real verdict. The bubble lingers until the NPC is
    destroyed.
]]

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

-- The one ScreenGui every NPC billboard lives under. They sit in PlayerGui (adorned back onto the NPC's
-- attachment) rather than in the world, because that's what makes their buttons clickable.
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

-- Paints the Title with one verdict's text + colors. Direct assignment (not a spring) so a fast flip
-- lands crisply rather than smearing between colors.
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

-- Tears down the NPC's decide bubble (stops its springs, destroys the billboards, ends the flip loop).
function SellNpcController:_cleanup(npc: Model)
	local state = self._active[npc]
	if not state then
		return
	end

	self._active[npc] = nil
	state.running = false
	state.trove:Destroy()
end

-- Clones the billboard set onto a customer's head and wires up its teardown and dialogue plumbing, returning
-- the state every later beat reads off (or nil if the rig has no head to hang it from). Split out from
-- _playDecide because a rich customer skips the decide flip entirely but still needs all of this -- the offer
-- frame most of all, which _showOffer has nothing to open without.
--
-- `dialogueVariant` is what the skewer being sold is worth reacting to -- how well it cooked, or the mutation
-- on it if it carries one (see StickModel.GetDialogueVariant) -- kept on the state so every line spoken for the
-- rest of the visit is drawn from that variant. Nil for a rich customer, whose haul mixes skewers and so falls
-- back to the plain categories. `dialoguePrefix` picks whose lines those are.
function SellNpcController:_attachNpcBillboards(npc: Model, dialogueVariant: string?, dialoguePrefix: string)
	local head = npc:FindFirstChild("Head") or npc:FindFirstChild("HumanoidRootPart")
	if not head then
		return nil
	end

	-- The template is an Attachment holding both billboards. It's cloned only to get at them and at the
	-- authored offset above the head -- nothing adorns or parents to it (see below), so it's dropped once
	-- both are read.
	local holder = UI.NPCUIAttachment:Clone()
	local decideUI, offerUI = holder.DecideUI, holder.OfferUI
	local decideFrame = decideUI.DecideFrame
	local offerFrame = offerUI.OfferFrame
	local title = decideFrame.Title
	local stroke = title.UIStroke
	local scale = title.UIScale

	local restOffset = holder.Position

	-- Both billboards stay Enabled for the NPC's whole life; their frames carry the visibility. Both start
	-- hidden: the decide frame is the caller's to raise (a rich customer never does), and the offer frame
	-- only opens once the customer actually makes an offer.
	decideFrame.Visible = false
	offerFrame.Visible = false

	-- The billboards live in PlayerGui and adorn back into the world, because world-parented buttons don't
	-- take clicks and the offer frame needs them. Adorned to the head itself, not to an attachment on it:
	-- an Attachment adornee was costing the offer buttons every tap on touch (the press landed, the release
	-- didn't), and it's what set these apart from the plot and dispenser signs, which adorn a BasePart and
	-- work. The offset the attachment used to provide is carried in world space so it stays overhead
	-- however the customer is facing.
	local screenGui = getScreenGui()
	for _, billboard in { decideUI, offerUI } do
		billboard.Adornee = head
		billboard.StudsOffsetWorldSpace = restOffset
		-- Both scale with the adornee's size, so whatever the template authored them to did nothing against
		-- a sizeless Attachment and would start shifting the bubble now that it's the head. Zeroed to keep
		-- the bubble exactly where it used to sit.
		billboard.ExtentsOffset = Vector3.zero
		billboard.ExtentsOffsetWorldSpace = Vector3.zero
		billboard.Active = true
		billboard.Parent = screenGui
	end

	holder:Destroy()

	local trove = Trove.new()
	-- Both, since the billboards live in PlayerGui and nothing on the NPC takes them down with it.
	trove:Add(decideUI)
	trove:Add(offerUI)
	-- Stop the springs before they're destroyed (Trove cleans in reverse add order).
	trove:Add(function()
		Spr.stop(scale)
		Spr.stop(decideUI)
		Spr.stop(offerUI)
	end)
	-- Tear the billboards down when the NPC leaves the world. A despawning customer is parked back in the
	-- pool (reparented out of workspace) rather than destroyed, so its replica here is removed without
	-- Destroying firing -- AncestryChanged catches that (parent goes nil), and a real Destroy too.
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

	-- Springs the billboard to clear the current stack of chat bubbles: BUBBLE_CLEARANCE studs per active
	-- bubble, so it rises as bubbles appear and settles back to rest as they expire.
	local function updateRaise()
		local lift = restOffset + Vector3.new(0, BUBBLE_CLEARANCE * state.bubbleCount, 0)
		Spr.target(decideUI, RAISE_DAMPING, RAISE_FREQUENCY, { StudsOffsetWorldSpace = lift })
		Spr.target(offerUI, RAISE_DAMPING, RAISE_FREQUENCY, { StudsOffsetWorldSpace = lift })
	end

	-- Says a dialogue line and counts its bubble in while it's up, so the billboard lifts to clear the
	-- stack and lowers again once the bubble expires. Every beat of the visit funnels through here, so
	-- passing the cook state is all it takes for the whole exchange to react to the skewer -- including
	-- the later ones the server drives, which only send a bare category.
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

	-- Exposed so the server can drive the later dialogue beats through the same bubble-raise bookkeeping.
	state.speak = speak

	return state
end

-- Shows and runs a customer's decide bubble: flip the verdict, pacing off the time left so it decelerates
-- onto `decideAt`, pulsing the Title scale each swap. Everything arrives off the NpcDecide remote.
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

			-- Decelerate: the gap grows from INITIAL to MAX as the window elapses, derived from the time
			-- left, and never overshoots the landing.
			local elapsedFraction = if duration > 0 then math.clamp(1 - timeLeft / duration, 0, 1) else 1
			local waitTime = SellNpc.DECIDE_INITIAL_WAIT
				+ (SellNpc.DECIDE_MAX_WAIT - SellNpc.DECIDE_INITIAL_WAIT) * elapsedFraction
			task.wait(math.min(waitTime, timeLeft))
		end

		if not state.running then
			return
		end

		-- Land on the real verdict with a final pulse and the verdict line.
		applyVerdict(title, stroke, if interested then INTERESTED else NOT_INTERESTED)
		pulseScale(scale, PULSE_START_SWAP)
		state.speak(if interested then "NPCInterested" else "NPCNotInterested")

		-- Interested: the chat bubble carries the message, so fade the decide frame away and then take it
		-- down for good -- the offer frame owns the billboard from here.
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

-- Sets a rich customer up as it reaches the stand. It runs no decide beat -- it's already made up its mind --
-- so this exists purely to build the billboards its offer will open on, and to give it an entrance line.
function SellNpcController:_showRichArrival(npc: Model)
	if not npc or self._active[npc] then
		return
	end

	-- No cook state: its haul mixes them, so its lines come from the plain RichNPC categories.
	local state = self:_attachNpcBillboards(npc, nil, "RichNPC")
	if not state then
		return
	end

	state.speak("RichNPCArrived")
end

-- Opens (or updates, when the customer counter-offers) the offer frame on the customer's billboard. Only the
-- base owner is sent this, so the buttons only ever exist for them.
-- `payout` is what the sale actually banks -- the customer's offer with the player's boosts already on
-- it, worked out by the server (see SellNpcManager) so what's quoted here is what lands.
function SellNpcController:_showOffer(npc: Model, payout: number, count: number, bonus: number)
	local state = self._active[npc]
	if not state or not state.running then
		return
	end

	local offerFrame = state.offerFrame

	-- A random line with the coloured amount dropped into it, drawn from the cook state's own set so a
	-- lowball on a burnt skewer says why. Ignoring the last line keeps a counter-offer from repeating the
	-- one the player just turned down.
	local amount = `<font color="{OFFER_AMOUNT_COLOR}">${GuiUtil.ConvertNumberWithSuffix(payout)}</font>`

	-- How far over the skewers' own worth that leaves the player, boosts included. A lowball can land on
	-- the nose, and "[+0%]" says less than no badge at all, so it only shows when there's something to
	-- show -- which is also what keeps an unboosted player's frame reading exactly as it always has.
	if bonus > 0 then
		amount ..= ` <font color="{OFFER_BONUS_COLOR}">[+{bonus}%]</font>`
	end

	local category = `{state.dialoguePrefix}Offer`
	local line = RandomUtil.GetRandomFromArray(NpcDialogue.GetLines(category, state.dialogueVariant), state.lastOfferLine)
	state.lastOfferLine = line

	-- {count} is how many skewers the offer covers. Every customer is sent one, so the swap is a harmless
	-- no-op on the ordinary lines, which have nothing worth saying about the number one.
	-- A function replacement, not a plain string: the bonus badge carries a '%', which gsub would
	-- otherwise read as an escape and swallow.
	local title = offerFrame.Title
	title.RichText = true
	title.Text = (line:gsub("{amount}", function()
		return amount
	end):gsub("{count}", tostring(count)))

	local buttons = offerFrame.Buttons
	local accept, decline = buttons.Accept, buttons.Decline

	-- Bind once; a counter-offer just re-arms the same buttons.
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

		-- Answered on the press rather than the release: the buttons ride a billboard over an animated
		-- head, so they can drift out from under a finger before it lifts and take the tap with them.
		-- `answered` above already makes a stray second press a no-op.
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

-- Takes the offer frame down once the haggle is over (dealt, declined for good, or timed out).
function SellNpcController:_hideOffer(npc: Model)
	local state = self._active[npc]
	if not state then
		return
	end

	state.answered = true
	state.offerFrame.Visible = false

	self.OnOfferEnded:Fire(npc)
end

-- Warms every customer animation so a nearby NPC's first eat/inspect doesn't hitch while this client fetches
-- the keyframes. Builds an Animation per clip and hands them to ContentProvider. Yields, so it's spawned.
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
	-- Warm the customer animations up front so the first eat/inspect near this client doesn't hitch.
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

	-- The server drives the later dialogue beats, since it owns their timing.
	self.NpcSayEvent:OnClientEvent(function(npc: Model, category: string)
		local state = self._active[npc]
		if state and state.running and state.speak then
			state.speak(category)
		end
	end)
end

return SellNpcController
