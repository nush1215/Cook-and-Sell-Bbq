-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local RandomUtil = require(Shared.RandomUtil)
local Animations = require(Shared.Animations)
local Structures = require(Shared.Config.Structures)
local SellNpc = require(Shared.Config.SellNpc)
local NpcDialogue = require(Shared.Config.NpcDialogue)

-- Modules
local Modules = script.Parent.Parent.Modules
local NpcBillboard = require(Modules.NpcBillboard)

-- Controllers
local UIController

--
local LocalPlayer = Players.LocalPlayer

-- The colour the offered amount is shown in on the offer frame, and the bonus badge beside it.
local OFFER_AMOUNT_COLOR = "#55ff00"
local OFFER_BONUS_COLOR = "#ffd400"

-- Seconds the landed verdict is left up before it fades, so it reads before the bubble takes over.
local INTERESTED_FADE_DELAY = 2

-- Once a customer is interested the chat bubble carries the message, so the decide frame fades itself out.
local INTERESTED_FADE_TWEEN_INFO = TweenInfo.new(1, Enum.EasingStyle.Sine)

-- Draws a sell-stand customer's billboards: the decide flip, its dialogue bubbles, and the offer frame the owner answers on. The rig publishes its own visit, so a client that reaches a customer part-way through draws it rather than waiting on a beat it already missed.

--
local SellNpcController = {
	NpcOfferResponseEvent = Network.Event("NpcOfferResponse"),
	NpcSayEvent = Network.Event("NpcSay"),

	-- (npc, offerFrame) whenever an offer frame goes up, including a counter-offer re-arming the same one.
	OnOfferShown = Signal.new(),
	-- (npc) once the haggle is over, however it ended.
	OnOfferEnded = Signal.new(),

	_active = {}, -- [npc] = { trove, running, decideFrame, offerFrame, speak, ... } -- one live set of billboards per NPC
	-- [npc] = true while its billboards are being built. Attach waits on the rig's Head, so a beat sent
	-- behind the visit can reach this client before the state does
	_attaching = {},
}

-- Tears down the NPC's billboards, springs and flip loop.
function SellNpcController:_cleanup(npc: Model)
	self._attaching[npc] = nil

	local state = self._active[npc]
	if not state then
		return
	end

	self._active[npc] = nil
	state.running = false

	-- A customer torn down mid-haggle still owes the beat: whoever is watching the offer needs it ended
	if state.offerShown then
		self:_hideOffer(state, npc)
	end

	state.trove:Destroy()
end

-- Builds a customer's billboards and dialogue state, then draws whatever visit the rig is already carrying.
function SellNpcController:_attach(npc: Model)
	if self._active[npc] or self._attaching[npc] then
		return
	end

	-- Latched before the waits below, so the beats behind them know there's an attach coming
	self._attaching[npc] = true

	-- The rig is stamped before it is tagged, but its client copy can carry the tag ahead of the stamp
	local encoded = npc:GetAttribute(SellNpc.VISIT_ATTRIBUTE)
	while encoded == nil and npc.Parent do
		task.wait()
		encoded = npc:GetAttribute(SellNpc.VISIT_ATTRIBUTE)
	end

	-- Only empty once the rig has left the world, so there's nothing left to draw on
	if not encoded then
		self._attaching[npc] = nil
		return
	end

	-- The prefix and the variant pick every line this customer speaks, so its lines need them up front
	local visit = HttpService:JSONDecode(encoded)

	local state = NpcBillboard.Attach(npc, "NPCUIAttachment", visit.Variant, visit.Prefix)
	self._attaching[npc] = nil

	if not state then
		return
	end

	-- The rig can be pooled or destroyed while Attach waits on its Head, and the hooks below are
	-- connected too late to have caught it -- so these billboards would sit in PlayerGui for good
	if npc.Parent == nil then
		state.trove:Destroy()
		return
	end

	state.decideFrame = state.billboards.DecideUI.DecideFrame
	state.offerFrame = state.billboards.OfferUI.OfferFrame

	-- Enabled for life, their frames carrying visibility; both start hidden until their beat raises them
	state.decideFrame.Visible = false
	state.offerFrame.Visible = false

	-- A pooled customer is reparented rather than destroyed, so AncestryChanged is what catches it
	state.trove:Connect(npc.AncestryChanged, function()
		if npc.Parent == nil then
			self:_cleanup(npc)
		end
	end)
	state.trove:Connect(npc.Destroying, function()
		self:_cleanup(npc)
	end)

	-- Read once, since a rig only ever serves the one customer it was stamped for
	state.ownerUserId = npc:GetAttribute(Structures.OWNER_ATTRIBUTE)

	self._active[npc] = state

	state.trove:Connect(npc:GetAttributeChangedSignal(SellNpc.VISIT_ATTRIBUTE), function()
		self:_render(npc)
	end)

	-- Seeded as well as connected, so a customer already mid-visit when this client reached it draws now
	self:_render(npc)
end

-- The customer's live set, waiting out an attach still in flight -- see _attaching.
function SellNpcController:_awaitState(npc: Model)
	while self._attaching[npc] do
		task.wait()
	end

	return self._active[npc]
end

-- Runs the decide flip, pacing off the time left so it decelerates onto the published landing.
function SellNpcController:_playDecide(state, visit)
	local decideFrame = state.decideFrame

	-- A client that reached this customer after the verdict landed gets the result without the flip. An
	-- interested one has faded its frame out by then, so a refusal is all that's left standing
	if workspace:GetServerTimeNow() >= visit.DecideAt then
		if not visit.Interested then
			NpcBillboard.ShowVerdict(decideFrame, false)
		end
		return
	end

	local trove = state.trove
	state.speak("NPCDeciding")

	task.spawn(function()
		NpcBillboard.PlayDecide(state, decideFrame, visit.Interested, visit.DecideAt)
		if not state.running then
			return
		end

		state.speak(if visit.Interested then "NPCInterested" else "NPCNotInterested")

		-- The bubble carries the message from here, and the offer frame owns the billboard
		if visit.Interested then
			task.delay(INTERESTED_FADE_DELAY, function()
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

-- Opens or updates the offer frame. `Payout` is the boosted figure the sale actually banks; only its owner can answer it.
function SellNpcController:_showOffer(state, npc: Model, visit)
	-- Someone else's customer haggles in the background: the sale is theirs to answer, not this client's
	if state.ownerUserId ~= LocalPlayer.UserId then
		return
	end

	local offerFrame = state.offerFrame

	-- From the cook state's own set, so a lowball on a burnt skewer says why; the last line is skipped
	local amount = `<font color="{OFFER_AMOUNT_COLOR}">${GuiUtil.ConvertNumberWithSuffix(visit.Payout)}</font>`

	-- Only shown when there's something to show -- "[+0%]" says less than no badge at all
	if visit.Bonus > 0 then
		amount ..= ` <font color="{OFFER_BONUS_COLOR}">[+{visit.Bonus}%]</font>`
	end

	local category = `{state.dialoguePrefix}Offer`
	local line = RandomUtil.GetRandomFromArray(NpcDialogue.GetLines(category, state.dialogueVariant), state.lastOfferLine)
	state.lastOfferLine = line

	-- A function replacement, since the bonus badge carries a '%' that gsub would read as an escape
	local title = offerFrame.Title
	title.RichText = true
	title.Text = (line:gsub("{amount}", function()
		return amount
	end):gsub("{count}", tostring(visit.Count)))

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
	state.offerShown = true
	accept.Active, decline.Active = true, true
	offerFrame.Visible = true

	self.OnOfferShown:Fire(npc, offerFrame)
end

-- Takes the offer frame down once the haggle is over, however it ended.
function SellNpcController:_hideOffer(state, npc: Model)
	state.answered = true
	state.offerShown = false
	state.offerFrame.Visible = false

	self.OnOfferEnded:Fire(npc)
end

-- Draws the customer against the visit it publishes, so every client sees the same exchange it does.
function SellNpcController:_render(npc: Model)
	local state = self._active[npc]

	local encoded = npc:GetAttribute(SellNpc.VISIT_ATTRIBUTE)

	-- On the blob, not the phase: a counter republishes the same phase at a new price, and that has to land
	if encoded == state.encoded then
		return
	end
	state.encoded = encoded

	-- Empty once the rig is pooled, which takes the offer down with the customer it belonged to
	local visit = if encoded then HttpService:JSONDecode(encoded) else nil
	local phase = visit and visit.Phase

	local previousPhase = state.phase
	state.phase = phase

	-- Read live: the variant only lands with the skewer the customer is shown, part-way into the visit
	if visit then
		state.dialogueVariant = visit.Variant
	end

	if phase == SellNpc.PHASES.Deciding then
		-- On the edge, not the state: a re-render mustn't start a second flip over the one already running
		if previousPhase ~= SellNpc.PHASES.Deciding then
			self:_playDecide(state, visit)
		end
	elseif phase == SellNpc.PHASES.Offering then
		self:_showOffer(state, npc, visit)
	elseif state.offerShown then
		self:_hideOffer(state, npc)
	end
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

	-- A customer on any base wires itself up here, whether it landed before this client or streams in later
	CollectionService:GetInstanceAddedSignal(SellNpc.TAG):Connect(function(npc: Model)
		self:_attach(npc)
	end)

	-- _attach waits on the rig's visit stamp, so the sweep is kept off this thread
	for _, npc in CollectionService:GetTagged(SellNpc.TAG) do
		task.spawn(function()
			self:_attach(npc)
		end)
	end

	-- The server drives the dialogue beats, since it owns their timing
	self.NpcSayEvent:OnClientEvent(function(npc: Model, category: string)
		-- The arrival lines ride this too, and they go out a frame after the rig lands -- so one can beat the attach
		local state = self:_awaitState(npc)
		if state and state.running then
			state.speak(category)
		end
	end)
end

return SellNpcController
