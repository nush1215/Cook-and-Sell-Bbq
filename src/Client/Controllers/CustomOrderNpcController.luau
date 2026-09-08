-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local RandomUtil = require(Shared.RandomUtil)
local Highlights = require(Shared.Config.Highlights)
local Structures = require(Shared.Config.Structures)
local Ingredients = require(Shared.Config.Ingredients)
local NpcDialogue = require(Shared.Config.NpcDialogue)
local CustomOrderNpc = require(Shared.Config.CustomOrderNpc)

-- Modules
local Modules = script.Parent.Parent.Modules
local NpcBillboard = require(Modules.NpcBillboard)
local EquippedItem = require(Modules.EquippedItem)
local GuideBeam = require(Modules.GuideBeam)

-- Controllers
local UIController

--
local LocalPlayer = Players.LocalPlayer

-- The colour the offered amount is shown in on the offer frame, and the bonus badge beside it.
local OFFER_AMOUNT_COLOR = "#55ff00"
local OFFER_BONUS_COLOR = "#ffd400"

-- The hand-over prompt. Generous, since the customer waits off to the side rather than at the stand
local DELIVER_PROMPT_DISTANCE = 14
local DELIVER_PROMPT_HOLD = 0.3
local DELIVER_DEBOUNCE = 1

-- The timer's colour once the order is nearly out, matching the flash on the customer itself
local TIMER_NORMAL_COLOR = Color3.fromRGB(255, 255, 255)
local TIMER_HURRY_COLOR = Color3.fromRGB(255, 65, 65)

-- Whether two ingredient lists are the same multiset, which is the exact fill an order pays its premium for.
local function ingredientsMatch(wanted: { string }, held: { string }): boolean
	if #wanted ~= #held then
		return false
	end

	local remaining = {}
	for _, id in wanted do
		remaining[id] = (remaining[id] or 0) + 1
	end

	for _, id in held do
		local left = remaining[id] or 0
		if left == 0 then
			return false
		end
		remaining[id] = left - 1
	end

	return true
end

-- Draws a custom order customer's billboards: the recipe card, the offer frame the owner answers on, and the countdown once the deal is struck. Also owns the cue for the BBQ that fills the order: the customer's glow and a beam over to them.

--
local CustomOrderNpcController = {
	CustomOrderInspectEvent = Network.Event("CustomOrderInspect"),
	CustomOrderResponseEvent = Network.Event("CustomOrderResponse"),
	CustomOrderDeliverEvent = Network.Event("CustomOrderDeliver"),
	CustomOrderSayEvent = Network.Event("CustomOrderSay"),

	-- Fires when the customer the held BBQ is for changes, so the sell stall can drop its own glow
	OnOrderTargetChanged = Signal.new(),

	_active = {}, -- [npc] = { trove, running, ingredientsFrame, offerFrame, speak, ... } -- one live set per NPC
	-- [npc] = true while its billboards are being built. Attach waits on the rig's Head, so a beat sent
	-- in the same frame the customer lands can arrive before the state does
	_attaching = {},
	_orderTarget = nil, -- the customer waiting on exactly what's in hand, glowing with a beam to them
	_beam = nil,
}

-- Tears down the NPC's billboards, springs, prompt and countdown.
function CustomOrderNpcController:_cleanup(npc: Model)
	self._attaching[npc] = nil

	local state = self._active[npc]
	if not state then
		return
	end

	self._active[npc] = nil
	state.running = false

	-- A pooled rig outlives its visit, so a tag left on would breathe on the next customer to use it
	npc:RemoveTag(Highlights.TAG)

	state.trove:Destroy()

	-- Dropped from _active above, so this drops the beam too if the customer leaving was the target
	self:_refreshOrderTarget()
end

-- Builds the customer's billboards, then draws whatever order the rig is already carrying.
function CustomOrderNpcController:_attach(npc: Model)
	if self._active[npc] or self._attaching[npc] then
		return
	end

	-- Latched before Attach yields on the rig's Head, so the beats behind it know there's one coming
	self._attaching[npc] = true

	-- No variant: it arrives holding nothing, so its lines have no cook state to react to until the hand-over
	local state = NpcBillboard.Attach(npc, "CustomOrderNPCUIAttachment", nil, "CustomNPC")
	self._attaching[npc] = nil

	if not state then
		warn(`[CustomOrderNpcController] {npc:GetFullName()} never got a head, so no billboards were built`)
		return
	end

	-- The rig can be pooled or destroyed while Attach waits on its Head, and the hooks below are
	-- connected too late to have caught it -- so these billboards would sit in PlayerGui for good
	if npc.Parent == nil then
		state.trove:Destroy()
		return
	end

	-- Its own, so the countdown can be dropped when the order ends without taking the bubbles with it
	state.timerTrove = state.trove:Construct(Trove)

	local holder = state.billboards.IngredientsUI.Holder
	state.holder = holder
	state.offerFrame = state.billboards.OfferUI.OfferFrame

	-- Enabled for life, their frames carrying visibility; both start hidden until their beat raises them
	holder.Visible = false
	state.offerFrame.Visible = false
	holder.Timer.Visible = false
	holder.Alert.Visible = false

	-- A pooled customer is reparented rather than destroyed, so AncestryChanged is what catches it
	state.trove:Connect(npc.AncestryChanged, function()
		if npc.Parent == nil then
			self:_cleanup(npc)
		end
	end)
	state.trove:Connect(npc.Destroying, function()
		self:_cleanup(npc)
	end)

	-- Read once, since a rig is stamped before it lands and only ever serves the one customer
	state.ownerUserId = npc:GetAttribute(Structures.OWNER_ATTRIBUTE)

	self._active[npc] = state

	state.trove:Connect(npc:GetAttributeChangedSignal(CustomOrderNpc.ORDER_ATTRIBUTE), function()
		self:_render(npc)
	end)

	-- Seeded as well as connected, so a customer already mid-order when this client reached it draws now
	self:_render(npc)
end

-- The customer waiting on exactly what's in hand, or nil. Raw never counts: a hand-over is graded on its cook too.
function CustomOrderNpcController:_findOrderTarget(): Model?
	local skewer = EquippedItem.GetSkewer()
	if not skewer or not skewer:GetAttribute("Cooked") then
		return nil
	end

	local held = HttpService:JSONDecode(skewer:GetAttribute("Ingredients"))

	-- One order runs at a time, so the first match is the answer rather than the nearest of several
	for npc, state in self._active do
		if state.orderIngredients and ingredientsMatch(state.orderIngredients, held) then
			return npc
		end
	end

	return nil
end

-- Moves the glow and the beam onto whichever customer the held BBQ is for, and says so if that moved.
function CustomOrderNpcController:_refreshOrderTarget()
	local target = self:_findOrderTarget()
	if target == self._orderTarget then
		return
	end

	if self._orderTarget then
		self._orderTarget:RemoveTag(Highlights.TAG)
	end
	if self._beam then
		self._beam.Destroy()
		self._beam = nil
	end

	self._orderTarget = target

	if target then
		target:SetAttribute("HighlightColor", Highlights.CLAIM)
		target:AddTag(Highlights.TAG)

		-- Hidden at the hand-over range, so the beam gives out exactly as the prompt comes in
		local beam = GuideBeam.Create(target, DELIVER_PROMPT_DISTANCE)

		-- The session's first beam waits on its template, so they can have put the BBQ down since
		if self._orderTarget ~= target then
			beam.Destroy()
			return
		end

		self._beam = beam
	end

	self.OnOrderTargetChanged:Fire()
end

-- The customer to take the held BBQ to, or nil. Read by the sell stall, which stands down while there is one.
function CustomOrderNpcController:GetOrderTargetNpc(): Model?
	return self._orderTarget
end

-- Watches the local character's tools so the cue tracks what they equip.
function CustomOrderNpcController:_watchCharacter(character: Model)
	self._characterCleaner:Clean()

	self._characterCleaner:Connect(character.ChildAdded, function(child)
		if child:IsA("Tool") then
			self:_refreshOrderTarget()
		end
	end)
	self._characterCleaner:Connect(character.ChildRemoved, function(child)
		if child:IsA("Tool") then
			self:_refreshOrderTarget()
		end
	end)

	self:_refreshOrderTarget()
end

-- Runs the flip the inspecting variation opens on, always landing on Not Interested.
function CustomOrderNpcController:_playInspect(npc: Model, decideAt: number)
	local state = self:_awaitState(npc)
	if not state or not state.running then
		return
	end

	-- The flip is the sell stand's billboard, so this mounts it alongside rather than redrawing it. Its
	-- head is already resolved by now, so Attach returns on the spot and the flip still starts on time
	local decideState = NpcBillboard.Attach(npc, "NPCUIAttachment", nil, "CustomNPC")
	if not decideState then
		return
	end

	state.trove:Add(decideState.trove)

	-- Only the flip is wanted off this template, so its offer frame never comes up
	decideState.billboards.OfferUI.OfferFrame.Visible = false

	local decideFrame = decideState.billboards.DecideUI.DecideFrame

	-- PlayDecide raises it from inside a spawn, so the authored default would flash for a frame
	decideFrame.Visible = false

	task.spawn(function()
		NpcBillboard.PlayDecide(decideState, decideFrame, false, decideAt)
		if not state.running then
			return
		end

		state.speak("CustomNPCNotInterested")
		decideFrame.Visible = false
	end)
end

-- Lays the recipe out along the Holder: an icon and name per ingredient, a plus between each pair.
function CustomOrderNpcController:_buildRecipe(state, ingredientIds: { string })
	local container = state.holder.Container
	local ingredientTemplate, plusTemplate = container.Ingredient, container.Plus

	-- The authored templates read top to bottom; a recipe reads across, so the layout is turned here
	container.UIListLayout.FillDirection = Enum.FillDirection.Horizontal
	container.UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	container.UIListLayout.VerticalAlignment = Enum.VerticalAlignment.Center

	ingredientTemplate.Visible = false
	plusTemplate.Visible = false

	for index, id in ingredientIds do
		local ingredient = Ingredients.GetIngredientFromId(id)

		if not ingredient then
			continue
		end

		-- Between each pair rather than after each entry, so the row doesn't end on a plus
		if index > 1 then
			local plus = plusTemplate:Clone()
			plus.LayoutOrder = index * 2 - 1
			plus.Visible = true
			plus.Parent = container
			state.trove:Add(plus)
		end

		local entry = ingredientTemplate:Clone()
		entry.LayoutOrder = index * 2
		entry.Image = ingredient.Icon
		entry.Visible = true

		-- Name only: the label keeps its authored colours rather than being tinted by tier
		local label = entry:FindFirstChildWhichIsA("TextLabel", true)
		if label then
			label.Text = ingredient.Name
		end

		entry.Parent = container
		state.trove:Add(entry)
	end

	state.recipeBuilt = true
end

-- Raises the recipe card, springing it up from nothing so it lands rather than appearing.
function CustomOrderNpcController:_openRecipeCard(state)
	local holder = state.holder
	holder.Title.Text = "Custom Order"
	holder.Visible = true

	local scale = holder.UIScale
	Spr.stop(scale, "Scale")
	scale.Scale = 0
	Spr.target(scale, CustomOrderNpc.UI_POP_DAMPING, CustomOrderNpc.UI_POP_FREQUENCY, { Scale = 1 })
end

-- The customer's live set, waiting out an attach still in flight -- see _attaching.
function CustomOrderNpcController:_awaitState(npc: Model)
	while self._attaching[npc] do
		task.wait()
	end

	return self._active[npc]
end

-- Raises the offer frame. `Payout` is what the sale would actually bank; only its owner can answer it.
function CustomOrderNpcController:_showOffer(state, npc: Model, order, owned: boolean)
	local amount = `<font color="{OFFER_AMOUNT_COLOR}">${GuiUtil.ConvertNumberWithSuffix(order.Payout)}</font>`

	-- Only shown when there's something to show -- "[+0%]" says less than no badge at all
	if order.Bonus > 0 then
		amount ..= ` <font color="{OFFER_BONUS_COLOR}">[+{order.Bonus}%]</font>`
	end

	local title = state.offerFrame.Title
	title.RichText = true

	-- A function replacement, since the bonus badge carries a '%' that gsub would read as an escape
	local line = RandomUtil.GetRandomFromArray(NpcDialogue.GetLines("CustomNPCOffer"))
	title.Text = (line:gsub("{amount}", function()
		return amount
	end))

	local buttons = state.offerFrame.Buttons

	-- Someone else's customer is display only, so a visitor gets the ask without the answer
	buttons.Visible = owned
	state.offerFrame.Visible = true

	-- Bound only for the owner: ownership can't turn over on a live customer, so there's nothing to keep wired
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

		self.CustomOrderResponseEvent:FireServer(npc, accepted)
	end

	-- On press, not release -- the buttons ride an animated head and can drift out from under a finger
	state.trove:Add(UIController:BindButtonClick(accept, function()
		answer(true)
	end, true, nil, nil, true).Disconnect)
	state.trove:Add(UIController:BindButtonClick(decline, function()
		answer(false)
	end, true, nil, nil, true).Disconnect)

	state.answered = false
	accept.Active, decline.Active = true, true
end

-- Puts the hand-over prompt on the customer, so walking up with a skewer is what gives it over.
function CustomOrderNpcController:_showDeliverPrompt(state, npc: Model)
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

	-- The timer's trove, so the prompt goes down with the order rather than lingering through the eat
	state.timerTrove:Add(prompt)
	state.timerTrove:Connect(prompt.Triggered, function()
		-- Alongside the server's own guard, so a held button doesn't spend a request per frame
		if state.delivering then
			return
		end
		state.delivering = true

		self.CustomOrderDeliverEvent:FireServer(npc)

		-- Released rather than latched: an empty-handed press is answered and then over with, so
		-- latching would leave them unable to try again with the BBQ they went off to fetch
		task.delay(DELIVER_DEBOUNCE, function()
			state.delivering = false
		end)
	end)
end

-- Starts the countdown, and for the owner the hand-over prompt, once the deal is struck.
function CustomOrderNpcController:_startTimer(state, npc: Model, order, owned: boolean)
	-- Owner only: the glow, the beam and the hand-over are all things nobody else can act on
	if owned then
		state.orderIngredients = order.Ingredients
		self:_showDeliverPrompt(state, npc)
	end

	state.offerFrame.Visible = false

	local timer = state.holder.Timer
	timer.Visible = true

	local alert = state.holder.Alert
	alert.Visible = false

	-- Per frame rather than per second, so the last few seconds don't visibly stall on a hitch
	state.timerTrove:Connect(RunService.Heartbeat, function()
		local remaining = math.max(order.Deadline - workspace:GetServerTimeNow(), 0)
		local text = GuiUtil.ConvertSecondsToDHMS(remaining)

		-- Only written on a change, since the label is redrawn far more often than the text moves
		if text ~= state.timerText then
			state.timerText = text
			timer.Text = text

			local hurrying = remaining <= CustomOrderNpc.HURRY_THRESHOLD
			timer.TextColor3 = if hurrying then TIMER_HURRY_COLOR else TIMER_NORMAL_COLOR

			-- The hurry toast carries the ping, so this is just the card's half of it
			alert.Visible = hurrying
		end
	end)

	-- Last, since the first beam of a session waits on its template and the card mustn't wait with it
	self:_refreshOrderTarget()
end

-- Takes the order card down once the visit is over, leaving the bubbles to carry the last beats.
function CustomOrderNpcController:_endOrder(npc: Model)
	local state = self._active[npc]
	if not state then
		return
	end

	state.answered = true
	state.offerFrame.Visible = false
	state.holder.Visible = false
	state.holder.Alert.Visible = false

	-- Drops the countdown and the hand-over prompt; the billboards themselves outlive this
	state.timerTrove:Clean()

	-- There's nothing left to hand over, so the glow and the beam come off with the prompt
	state.orderIngredients = nil
	self:_refreshOrderTarget()
end

-- Draws the customer against the order it publishes, so every client sees the card and not just its owner.
function CustomOrderNpcController:_render(npc: Model)
	local state = self._active[npc]

	local encoded = npc:GetAttribute(CustomOrderNpc.ORDER_ATTRIBUTE)
	local order = if encoded then HttpService:JSONDecode(encoded) else nil
	local phase = order and order.Phase

	-- On the edge, not the state: the card clones its rows, so a redraw would stack a second recipe
	if phase == state.phase then
		return
	end
	state.phase = phase

	if not phase then
		self:_endOrder(npc)
		return
	end

	if not state.recipeBuilt then
		self:_buildRecipe(state, order.Ingredients)
		self:_openRecipeCard(state)
	end

	local owned = state.ownerUserId == LocalPlayer.UserId

	if phase == CustomOrderNpc.PHASES.Pending then
		self:_showOffer(state, npc, order, owned)
	else
		self:_startTimer(state, npc, order, owned)
	end
end

function CustomOrderNpcController:OnInit()
	UIController = require(script.Parent.UIController)
end

function CustomOrderNpcController:OnStart()
	self._characterCleaner = Trove.new()

	-- Equipping or unequipping a BBQ changes which waiting customer, if any, it's for
	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character: Model)
		self:_watchCharacter(character)
	end)

	-- A customer on any base wires itself up here, whether it landed before this client or streams in later
	CollectionService:GetInstanceAddedSignal(CustomOrderNpc.TAG):Connect(function(npc: Model)
		self:_attach(npc)
	end)

	-- _attach waits on the rig's head, so the sweep is kept off this thread
	for _, npc in CollectionService:GetTagged(CustomOrderNpc.TAG) do
		task.spawn(function()
			self:_attach(npc)
		end)
	end

	self.CustomOrderInspectEvent:OnClientEvent(function(npc: Model, decideAt: number)
		self:_playInspect(npc, decideAt)
	end)

	-- The server drives the dialogue beats, since it owns their timing
	self.CustomOrderSayEvent:OnClientEvent(function(npc: Model, category: string, variant: string?)
		-- The greeting rides this too, and it goes out a frame after the rig lands -- so it can beat the attach
		local state = self:_awaitState(npc)
		if not state or not state.running then
			return
		end

		-- Only knowable at the hand-over, so the variant arrives with the line rather than on arrival
		if variant then
			state.dialogueVariant = variant
		end

		state.speak(category)
	end)
end

return CustomOrderNpcController
