-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local RandomUtil = require(Shared.RandomUtil)
local Ingredients = require(Shared.Config.Ingredients)
local NpcDialogue = require(Shared.Config.NpcDialogue)
local CustomOrderNpc = require(Shared.Config.CustomOrderNpc)

-- Modules
local Modules = script.Parent.Parent.Modules
local NpcBillboard = require(Modules.NpcBillboard)

-- Controllers
local UIController

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

-- Draws a custom order customer's billboards: the recipe card, the offer frame the owner answers on, and the countdown once the deal is struck.

--
local CustomOrderNpcController = {
	CustomOrderArriveEvent = Network.Event("CustomOrderArrive"),
	CustomOrderInspectEvent = Network.Event("CustomOrderInspect"),
	CustomOrderShowEvent = Network.Event("CustomOrderShow"),
	CustomOrderResponseEvent = Network.Event("CustomOrderResponse"),
	CustomOrderAcceptedEvent = Network.Event("CustomOrderAccepted"),
	CustomOrderDeliverEvent = Network.Event("CustomOrderDeliver"),
	CustomOrderEndEvent = Network.Event("CustomOrderEnd"),
	CustomOrderSayEvent = Network.Event("CustomOrderSay"),

	_active = {}, -- [npc] = { trove, running, ingredientsFrame, offerFrame, speak, ... } -- one live set per NPC
}

-- Tears down the NPC's billboards, springs, prompt and countdown.
function CustomOrderNpcController:_cleanup(npc: Model)
	local state = self._active[npc]
	if not state then
		return
	end

	self._active[npc] = nil
	state.running = false
	state.trove:Destroy()
end

-- Builds the customer's billboards. The decide flip runs off NPCUIAttachment, so both are mounted.
function CustomOrderNpcController:_attach(npc: Model, inspecting: boolean)
	if not npc or self._active[npc] then
		return
	end

	-- No variant: it arrives holding nothing, so its lines have no cook state to react to until the hand-over
	local state = NpcBillboard.Attach(npc, "CustomOrderNPCUIAttachment", nil, "CustomNPC")
	if not state then
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

	self._active[npc] = state

	-- The flip is the sell stand's billboard, so this one mounts it alongside rather than redrawing it
	if inspecting then
		local decideState = NpcBillboard.Attach(npc, "NPCUIAttachment", nil, "CustomNPC")
		if decideState then
			state.trove:Add(decideState.trove)
			state.decideState = decideState
			-- Only the flip is wanted off this template, so its offer frame never comes up
			decideState.billboards.OfferUI.OfferFrame.Visible = false
			decideState.billboards.DecideUI.DecideFrame.Visible = false
		end
	end

	state.speak(if inspecting then "CustomNPCInspecting" else "CustomNPCArrived")
end

-- Runs the flip the inspecting variation opens on, always landing on Not Interested.
function CustomOrderNpcController:_playInspect(npc: Model, decideAt: number)
	local state = self._active[npc]
	local decideState = state and state.decideState
	if not decideState then
		return
	end

	local decideFrame = decideState.billboards.DecideUI.DecideFrame

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
end

-- Opens the recipe card and the offer frame. Owner only, and `payout` is what the sale would actually bank.
function CustomOrderNpcController:_showOffer(npc: Model, ingredientIds: { string }, payout: number, bonus: number)
	local state = self._active[npc]
	if not state or not state.running then
		return
	end

	self:_buildRecipe(state, ingredientIds)

	local holder = state.holder
	holder.Title.Text = "Custom Order"
	holder.Visible = true

	-- Sprung from nothing, so the card lands rather than appearing
	local scale = holder.UIScale
	Spr.stop(scale, "Scale")
	scale.Scale = 0
	Spr.target(scale, CustomOrderNpc.UI_POP_DAMPING, CustomOrderNpc.UI_POP_FREQUENCY, { Scale = 1 })

	local amount = `<font color="{OFFER_AMOUNT_COLOR}">${GuiUtil.ConvertNumberWithSuffix(payout)}</font>`

	-- Only shown when there's something to show -- "[+0%]" says less than no badge at all
	if bonus > 0 then
		amount ..= ` <font color="{OFFER_BONUS_COLOR}">[+{bonus}%]</font>`
	end

	local title = state.offerFrame.Title
	title.RichText = true

	-- A function replacement, since the bonus badge carries a '%' that gsub would read as an escape
	local line = RandomUtil.GetRandomFromArray(NpcDialogue.GetLines("CustomNPCOffer"))
	title.Text = (line:gsub("{amount}", function()
		return amount
	end))

	local buttons = state.offerFrame.Buttons
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
	state.offerFrame.Visible = true
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

-- Starts the countdown and the hand-over prompt once the deal is struck.
function CustomOrderNpcController:_startTimer(npc: Model, deadline: number)
	local state = self._active[npc]
	if not state or not state.running then
		return
	end

	state.offerFrame.Visible = false

	local timer = state.holder.Timer
	timer.Visible = true

	local alert = state.holder.Alert
	alert.Visible = false

	self:_showDeliverPrompt(state, npc)

	-- Per frame rather than per second, so the last few seconds don't visibly stall on a hitch
	state.timerTrove:Connect(RunService.Heartbeat, function()
		local remaining = math.max(deadline - workspace:GetServerTimeNow(), 0)
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
end

function CustomOrderNpcController:OnInit()
	UIController = require(script.Parent.UIController)
end

function CustomOrderNpcController:OnStart()
	self.CustomOrderArriveEvent:OnClientEvent(function(npc: Model, inspecting: boolean)
		self:_attach(npc, inspecting)
	end)

	self.CustomOrderInspectEvent:OnClientEvent(function(npc: Model, decideAt: number)
		self:_playInspect(npc, decideAt)
	end)

	self.CustomOrderShowEvent:OnClientEvent(function(npc: Model, ingredientIds, payout: number, bonus: number)
		self:_showOffer(npc, ingredientIds, payout, bonus)
	end)

	self.CustomOrderAcceptedEvent:OnClientEvent(function(npc: Model, deadline: number)
		self:_startTimer(npc, deadline)
	end)

	self.CustomOrderEndEvent:OnClientEvent(function(npc: Model)
		self:_endOrder(npc)
	end)

	-- The server drives the later dialogue beats, since it owns their timing
	self.CustomOrderSayEvent:OnClientEvent(function(npc: Model, category: string, variant: string?)
		local state = self._active[npc]
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
