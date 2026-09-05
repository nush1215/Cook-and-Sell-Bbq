-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local RandomUtil = require(Shared.RandomUtil)
local Animations = require(Shared.Animations)
local NpcDialogue = require(Shared.Config.NpcDialogue)

-- Modules
local Modules = script.Parent.Parent.Modules
local NpcBillboard = require(Modules.NpcBillboard)

-- Controllers
local UIController

-- The colour the offered amount is shown in on the offer frame, and the bonus badge beside it.
local OFFER_AMOUNT_COLOR = "#55ff00"
local OFFER_BONUS_COLOR = "#ffd400"

-- Once a customer is interested the chat bubble carries the message, so the decide frame fades itself out.
local INTERESTED_FADE_TWEEN_INFO = TweenInfo.new(1, Enum.EasingStyle.Sine)

-- Draws a sell-stand customer's billboards: the decide flip, its dialogue bubbles, and the offer frame the owner answers on.

--
local SellNpcController = {
	NpcDecideEvent = Network.Event("NpcDecide"),
	NpcRichArriveEvent = Network.Event("NpcRichArrive"),
	NpcCheckingArriveEvent = Network.Event("NpcCheckingArrive"),
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
	local state = NpcBillboard.Attach(npc, "NPCUIAttachment", dialogueVariant, dialoguePrefix)
	if not state then
		return nil
	end

	local decideUI, offerUI = state.billboards.DecideUI, state.billboards.OfferUI
	state.decideFrame = decideUI.DecideFrame
	state.offerFrame = offerUI.OfferFrame

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

	self._active[npc] = state
	return state
end

-- Runs the decide flip, pacing off the time left so it decelerates onto `decideAt`.
function SellNpcController:_playDecide(npc: Model, interested: boolean, decideAt: number, dialogueVariant: string)
	if not npc then
		return
	end

	-- A checking customer already has its billboards up, having arrived before there was a skewer to attach them for
	local state = self._active[npc] or self:_attachNpcBillboards(npc, dialogueVariant, "NPC")
	if not state then
		return
	end

	-- The variant it couldn't be given on arrival, read live by speak on every beat from here
	state.dialogueVariant = dialogueVariant

	local trove = state.trove
	local decideFrame = state.decideFrame

	state.speak("NPCDeciding")

	task.spawn(function()
		NpcBillboard.PlayDecide(state, decideFrame, interested, decideAt)
		if not state.running then
			return
		end

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

-- Sets a checking customer up on arrival: no skewer yet, so its billboards go up on the plain NPC lines.
function SellNpcController:_showCheckingArrival(npc: Model)
	if not npc or self._active[npc] then
		return
	end

	-- No cook state to name: it's asking whether there's anything at all, so the variant lands on the decide beat
	local state = self:_attachNpcBillboards(npc, nil, "NPC")
	if not state then
		return
	end

	state.speak("NPCCheckingArrived")
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

	self.NpcCheckingArriveEvent:OnClientEvent(function(npc: Model)
		self:_showCheckingArrival(npc)
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
