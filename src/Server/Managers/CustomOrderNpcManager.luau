-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Server
local Server = script.Parent.Parent
local ServerRandom = require(Server.Modules.ServerRandom)
local NpcRig = require(Server.Modules.NpcRig)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Colors = require(Shared.Colors)
local GuiUtil = require(Shared.GuiUtil)
local StickModel = require(Shared.StickModel)
local RandomUtil = require(Shared.RandomUtil)
local Sticks = require(Shared.Config.Sticks)
local SellNpc = require(Shared.Config.SellNpc)
local CookStates = require(Shared.Config.CookStates)
local Structures = require(Shared.Config.Structures)
local Ingredients = require(Shared.Config.Ingredients)
local CustomOrderNpc = require(Shared.Config.CustomOrderNpc)
local RichNpc = require(Shared.Config.RichNpc)

-- Managers
local CustomerTipManager = require(script.Parent.CustomerTipManager)

-- How often the wait is checked. Not per frame: this runs for minutes, and a tenth of a second is
-- imperceptible on both the hand-over reaction and the run-out warning
local DELIVERY_POLL_INTERVAL = 0.1

-- The unlock whose level MIN_ROLLING_STANDS is counted in. It defaults to 1, so a buy first lands on 2
local ROLLING_STANDS_UNLOCK = "RollingStands"

-- The state a quote is priced against, so anything else is a deduction the toast has to explain
local PERFECT_COOK_STATE = "Perfect"

--
local PlayerDataManager
local SkewerStandManager
local CollisionManager
local CurrencyManager
local NotificationManager
local EffectManager
local StickManager
local StatsManager
local SoundManager
local SellNpcManager
local GrillerManager
local StickStandManager
local BaseManager

-- Sends the customer who asks for a named recipe against a clock. Its rig, walk and fade are the sell stand's; what is its own is the order, the timer and the hand-over.
local CustomOrderNpcManager = {
	CustomOrderInspectEvent = Network.Event("CustomOrderInspect"),
	CustomOrderResponseEvent = Network.Event("CustomOrderResponse"),
	CustomOrderDeliverEvent = Network.Event("CustomOrderDeliver"),
	CustomOrderSayEvent = Network.Event("CustomOrderSay"),

	-- (player, order, payout, variation, firstVisit, funnelId) once an order is put to the player
	OnCustomOrderOffered = Signal.new(),
	-- (player, order, funnelId) once they take it on
	OnCustomOrderAccepted = Signal.new(),
	-- (player, entry, funnelId, delivered?, isRich) once an order resolves, however it went. The same record StatsManager banks, plus the skewer handed over.
	OnCustomOrderResolved = Signal.new(),

	_npcs = {}, -- [player] = { record, ... } spawned instances, for cleanup
	_delivering = {}, -- [player] = true across the read -> write window, so a spammed prompt can't pay twice
	_queued = {}, -- [player] = true while a forced Inspect visit waits for their stand to be stocked
	-- [player] = true from their base being assigned until the join beat has sent their saved orders back
	_restoring = {},
	-- [player] = true once their guaranteed first order is sent; the saved key alone yields
	_grantedFirstOrder = {},
	_tierWeights = {}, -- CustomOrderNpc.TIER_WEIGHTS flattened for the weighted roll, built once on start
	_richTierWeights = {}, -- CustomOrderNpc.RICH_TIER_WEIGHTS, likewise
	_richMinTierIndex = math.huge, -- the commonest tier a rich order may ask for, the lowest in RICH_TIER_WEIGHTS
	_rng = ServerRandom.MakeRNG("CustomOrderNpc"),
}

-- True while the player is still in-game and has a base to send customers to.
local function validatePlayer(player: Player): boolean
	return player:IsDescendantOf(Players) and player:GetAttribute("BaseId") ~= nil
end

-- The roomiest stick an order is sized and priced against. Falls back to the cheapest rather than nil: owning no spare stick is the normal state the moment they've built them all, and it must not stop a customer asking.
local function getBestOwnedStick(data)
	local best = nil

	for _, stick in Sticks.GetAllSticks() do
		if (data.Sticks[stick.Id] or 0) > 0 and (not best or stick.Capacity > best.Capacity) then
			best = stick
		end
	end

	-- Array order is the tier, so the first entry is the cheapest one they could go and buy
	return best or Sticks.GetAllSticks()[1]
end

-- [ingredientId] = how many of it, so a repeated ingredient is matched by count rather than by presence.
local function countIngredients(ids: { string }): { [string]: number }
	local counts = {}

	for _, id in ids do
		counts[id] = (counts[id] or 0) + 1
	end

	return counts
end

-- Every ingredient the player already has for an order: loose stock plus whatever is on a skewer they
-- are part-way through building. Stock alone drops back to zero the moment one goes on a stick, which
-- would put it straight back on the wanted list and steer the stand at it for the rest of the order.
local function countIngredientsToHand(data): { [string]: number }
	local counts = table.clone(data.Ingredients)

	local function addFrom(record)
		for _, id in record.Ingredients or {} do
			counts[id] = (counts[id] or 0) + 1
		end
	end

	-- Everywhere a build in progress can be sitting. The sell stall is left out on purpose:
	-- those are finished and destined for a customer, so they aren't spoken for by this order
	for _, record in data.StickStands do
		addFrom(record)
	end
	for _, record in data.FilledSticks do
		addFrom(record)
	end
	for _, record in data.Grillers do
		addFrom(record)
	end

	-- The plate holds a skewer whole, so its ingredients are nested a level down. Dormant while
	-- Sauces.Data ships empty, but the plate still parks one and a missed one steers the stand forever
	for _, record in data.SauceDispensers do
		if record.Skewer then
			addFrom(record.Skewer)
		end
	end

	-- The hut chest and what staff carry are still theirs, so stashing an order's ingredient can't re-arm the steer
	for _, store in data.HutStorage do
		for id, amount in store.Ingredients do
			counts[id] = (counts[id] or 0) + amount
		end
	end
	for _, employee in data.Employees do
		if employee.Load then
			addFrom(employee.Load)
		end
		if employee.Carrying then
			addFrom(employee.Carrying)
		end
	end

	return counts
end

-- How much of `order` a delivered skewer covers: ingredients asked for, and ingredients nobody asked for.
local function measureDelivery(order, delivered): (number, number)
	local remaining = table.clone(order.Counts)
	local matched, extras = 0, 0

	for _, id in delivered.Ingredients do
		if (remaining[id] or 0) > 0 then
			remaining[id] -= 1
			matched += 1
		else
			extras += 1
		end
	end

	return matched, extras
end

-- How much of the order a hand-over got right, 0-1: the share of the recipe that landed, less its extras.
local function getOrderAccuracy(order, delivered): number
	local matched, extras = measureDelivery(order, delivered)

	-- Padding a stick out with whatever was to hand must not pay, so extras come off the share
	return math.max(matched / #order.Ingredients - extras * CustomOrderNpc.EXTRA_INGREDIENT_PENALTY, 0)
end

-- Stands a customer up out of whatever seat it's in. Its claim on the seat is the record's to drop.
local function unseatCustomer(humanoid: Humanoid)
	local seatPart = humanoid.SeatPart
	if seatPart then
		local weld = seatPart:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
	end

	humanoid.Sit = false
end

-- What a perfect exact fill of `ids` is worth on `stick`, which the quote and its badge are both figured from.
local function getReferenceValue(stick, ids: { string }): number
	return StickModel.GetSellValue({
		StickId = stick.Id,
		Ingredients = ids,
		Cooked = true,
		CookState = "Perfect",
	})
end

-- Builds an order: what to ask for, what a perfect exact fill earns, and how long they get. A `rich` one asks only for RICH_TIER_WEIGHTS tiers, and is nil when none are in reach.
function CustomOrderNpcManager:_buildOrder(data, rich: boolean?)
	local stick = getBestOwnedStick(data)
	local slots =
		math.min(self._rng:NextInteger(CustomOrderNpc.SLOT_COUNT_MIN, CustomOrderNpc.SLOT_COUNT_MAX), stick.Capacity)

	local minTierIndex = if rich then self._richMinTierIndex else 1

	-- What they can reach: owned outright, or cheap enough that rolling for it is a trip rather than a wall
	local affordable = data.Currency * CustomOrderNpc.AFFORD_FACTOR
	local byTier = {}
	for _, ingredient in Ingredients.GetAllIngredients() do
		local owned = (data.Ingredients[ingredient.Id] or 0) > 0
		if ingredient.Tier.Index < minTierIndex or (not owned and ingredient.Price > affordable) then
			continue
		end

		local tierId = ingredient.Tier.Id
		byTier[tierId] = byTier[tierId] or {}
		-- Stock weighs heavier, so most orders start part-filled rather than as a shopping list
		table.insert(byTier[tierId], { ingredient, if owned then CustomOrderNpc.OWNED_WEIGHT_BONUS else 1 })
	end

	-- Nothing reachable at all, which a broke player really can hit: ask for the cheapest tier anyway,
	-- since the roll steer is what gets them there and a silent no-visit reads as the feature being broken
	if next(byTier) == nil then
		-- A rich one has no cheap tier to fall back on, so the visit goes to an ordinary customer instead
		if rich then
			return nil
		end

		local cheapest = Ingredients.Tiers[1]
		byTier[cheapest.Id] = {}

		for _, ingredient in Ingredients.GetAllIngredients() do
			if ingredient.Tier.Id == cheapest.Id then
				table.insert(byTier[cheapest.Id], { ingredient, 1 })
			end
		end
	end

	local ids = {}
	local tierIndexTotal = 0

	local tierWeights = if rich then self._richTierWeights else self._tierWeights

	for _ = 1, slots do
		local wanted = RandomUtil.GetResultFromWeight(tierWeights, self._rng)
		local wantedIndex = Ingredients.GetTierFromId(wanted).Index

		-- Walked down from the rolled tier, so a band with nothing reachable in it falls back rather than failing.
		-- Then up, since a rich one's floor can sit above everything it can reach below the roll
		local candidates = nil
		for index = wantedIndex, minTierIndex, -1 do
			candidates = byTier[Ingredients.Tiers[index].Id]
			if candidates then
				break
			end
		end
		if not candidates then
			for index = wantedIndex + 1, #Ingredients.Tiers do
				candidates = byTier[Ingredients.Tiers[index].Id]
				if candidates then
					break
				end
			end
		end
		if not candidates then
			return nil
		end

		local ingredient = RandomUtil.GetResultFromWeight(candidates, self._rng)
		table.insert(ids, ingredient.Id)
		tierIndexTotal += ingredient.Tier.Index
	end

	-- The premium climbs with what was asked for, so a rarer recipe is worth the harder trip
	local richBonus = if rich then CustomOrderNpc.RICH_MULTIPLIER_BONUS else 0
	local multiplier = math.min(
		CustomOrderNpc.BASE_MULTIPLIER + richBonus + CustomOrderNpc.TIER_STEP * (tierIndexTotal / slots - 1),
		CustomOrderNpc.MULTIPLIER_CAP + richBonus
	)

	-- GetTotalCookTime is ingredient seconds; the bar runs that over RAW_END, so the clock has to as well
	local cookSeconds = Ingredients.GetTotalCookTime(ids) / CookStates.RAW_END

	-- The plain worth of a perfect exact fill, which both the quote and the badge beside it come off
	local value = getReferenceValue(stick, ids)

	return {
		Ingredients = ids,
		Counts = countIngredients(ids),
		StickId = stick.Id,
		Value = value,
		Quote = math.round(value * multiplier),
		Seconds = math.round(cookSeconds + CustomOrderNpc.LEEWAY_BASE + CustomOrderNpc.LEEWAY_PER_INGREDIENT * slots),
		TierIndex = tierIndexTotal / slots,
		Rich = rich or nil,
	}
end

-- Rebuilds a live order from what was saved. Counts are derived rather than stored, since keeping a
-- second copy of the same fact in the profile only creates something to fall out of step.
local function restoreOrder(saved)
	return {
		Ingredients = saved.Ingredients,
		Counts = countIngredients(saved.Ingredients),
		StickId = saved.StickId,
		Value = saved.Value,
		Quote = saved.Quote,
		Seconds = saved.Seconds,
		TierIndex = saved.TierIndex,
		Rich = saved.Rich,
	}
end

-- What the player's waiting orders still need between them, so the rolling stand knows what to steer toward.
function CustomOrderNpcManager:GetMissingOrderIngredients(player: Player, data): { string }
	-- Summed, so two orders wanting the same ingredient keep steering until there's one for each
	local wanted = {}
	for _, record in self._npcs[player] or {} do
		if record.awaitingDelivery then
			for id, count in record.order.Counts do
				wanted[id] = (wanted[id] or 0) + count
			end
		end
	end

	if next(wanted) == nil then
		return {}
	end

	local toHand = countIngredientsToHand(data)

	local missing = {}
	for id, needed in wanted do
		if (toHand[id] or 0) < needed then
			table.insert(missing, id)
		end
	end

	return missing
end

-- Records the owner's answer; finding the NPC among their own customers is the authority check.
function CustomOrderNpcManager:AnswerOffer(player: Player, npc: Model, accepted: boolean)
	for _, record in self._npcs[player] or {} do
		if record.npc == npc and record.offerPending then
			record.offerPending = false
			record.offerResponse = accepted == true
			return
		end
	end
end

-- The shape an owed order takes in the profile. Its clock is banked as seconds rather than a deadline,
-- so it is frozen where it stood rather than running down while they're away -- GrillerManager's trade.
local function buildSavedOrder(record, phase: string)
	local order = record.order

	return {
		Phase = phase,
		Ingredients = order.Ingredients,
		StickId = order.StickId,
		Value = order.Value,
		Quote = order.Quote,
		Seconds = order.Seconds,
		SecondsLeft = if phase == CustomOrderNpc.PHASES.Accepted
			then math.max(record.deadline - workspace:GetServerTimeNow(), 0)
			else nil,
		TierIndex = order.TierIndex,
		Rich = order.Rich,
		Look = record.look,
		FirstVisit = record.firstVisit,
		FunnelId = record.funnelId,
	}
end

-- Banks one order under its funnel id the moment it's owed, so it rides the auto-save rather than trusting the way out.
function CustomOrderNpcManager:SaveActiveOrder(player: Player, record, phase: string)
	PlayerDataManager:SetPlayerDataKey(
		player,
		{ "ActiveCustomOrders", record.funnelId },
		buildSavedOrder(record, phase)
	)
end

-- Whether the profile has an order saved to come back. Reads the pre-map key too, since the offline pass can run before the fold.
function CustomOrderNpcManager:HasSavedCustomOrders(data): boolean
	return next(data.ActiveCustomOrders) ~= nil or data.ActiveCustomOrder ~= nil
end

-- Folds the one order a profile saved before orders could overlap into ActiveCustomOrders, under the funnel id it carries.
function CustomOrderNpcManager:MigrateLegacyActiveOrderOnLoad(data)
	local legacy = data.ActiveCustomOrder
	if not legacy then
		return
	end

	data.ActiveCustomOrders[legacy.FunnelId] = legacy
	data.ActiveCustomOrder = nil
end

-- Mirrors the live order onto the rig, so every client draws the card rather than just its owner. A nil phase takes it down.
function CustomOrderNpcManager:_publishOrder(record, phase: string?, payout: number?, bonus: number?)
	local order = record.order

	record.npc:SetAttribute(
		CustomOrderNpc.ORDER_ATTRIBUTE,
		if phase
			then HttpService:JSONEncode({
				Phase = phase,
				Ingredients = order.Ingredients,
				Payout = payout,
				Bonus = bonus,
				Deadline = record.deadline,
			})
			else nil
	)
end

-- Restamps every owed order's banked clock on the outgoing profile. Runs inside the final save, so it writes `data` directly rather than yielding.
function CustomOrderNpcManager:SaveActiveOrdersOnLastSave(player: Player, data)
	for _, record in self._npcs[player] or {} do
		-- Only a visit still owed something comes back. One that's eating or walking off is finished,
		-- and one whose offer was already answered either way has had its outcome recorded
		local phase = if record.awaitingDelivery or record.standSkewerUid
			then CustomOrderNpc.PHASES.Accepted
			elseif record.offerPending then CustomOrderNpc.PHASES.Pending
			else nil
		if not phase then
			continue
		end

		data.ActiveCustomOrders[record.funnelId] = buildSavedOrder(record, phase)
	end
end

-- Removes one spawned customer: clears its tool, fades the rig out and pools it.
function CustomOrderNpcManager:_despawnNpc(player: Player, record)
	NpcRig.StopAnimation(record)

	if record.skewerModel then
		record.skewerModel:Destroy()
	end
	if record.tool then
		record.tool:Destroy()
	end

	-- Tolerates a slot already given up when it stepped aside, so both paths can call this
	if record.slot then
		NpcRig.ReleaseSlot(player, record.slot)
		record.slot = nil
	end

	-- A pooled rig still welded to a seat would drag the table's claim into the next customer
	unseatCustomer(record.npc:FindFirstChildOfClass("Humanoid"))
	record.seat, record.seatTable = nil, nil

	NpcRig.Fade(record.npc, false, SellNpc.FADE_OUT_DURATION)

	-- The player may have left during the fade, in which case _cleanupPlayer already destroyed the rig.
	if record.npc.Parent == nil then
		return
	end

	-- A rich rig is its own model -- pooling it would repaint it as the template for the next customer
	if record.isRich then
		record.npc:Destroy()
	else
		NpcRig.Release(record.npc)
	end

	local tracked = self._npcs[player]
	if tracked then
		local index = table.find(tracked, record)
		if index then
			table.remove(tracked, index)
		end
	end
end

-- Banks one resolved order, whichever way it went, and hands the same facts to anything watching.
function CustomOrderNpcManager:_recordOutcome(player: Player, record, outcome: string, delivered, paid: number)
	local order = record.order
	local matched, extras = 0, 0
	if delivered then
		matched, extras = measureDelivery(order, delivered)
	end

	local entry = {
		At = workspace:GetServerTimeNow(),
		Outcome = outcome,
		Slots = #order.Ingredients,
		TierIndex = order.TierIndex,
		Matched = matched,
		Extras = extras,
		CookState = delivered and StickModel.GetCookStateId(delivered),
		Mutation = delivered and delivered.Mutation,
		StickId = delivered and delivered.StickId,
		Seconds = order.Seconds,
		-- Zero on anything that never got a clock, which is what tells an expiry from a quick hand-over
		SecondsLeft = math.max(math.round((record.deadline or 0) - workspace:GetServerTimeNow()), 0),
		Quote = order.Quote,
		Paid = paid,
	}

	-- Only this order's entry, cleared here since every outcome lands here and a missed clear brings a ghost customer back forever
	PlayerDataManager:SetPlayerDataKey(player, { "ActiveCustomOrders", record.funnelId }, nil)

	StatsManager:RecordCustomOrderResolved(player, entry)
	self.OnCustomOrderResolved:Fire(player, entry, record.funnelId, delivered, record.isRich == true)
end

-- What a hand-over is worth: the quote graded by how much of the recipe landed and how it cooked.
function CustomOrderNpcManager:_gradeDelivery(order, delivered): number
	local accuracy = getOrderAccuracy(order, delivered)

	-- Relative to Perfect, so a cook state is worth the same here as it is anywhere else in the economy
	local cookFactor = CookStates.GetMultiplier(StickModel.GetCookStateId(delivered))
		/ CookStates.GetMultiplier("Perfect")

	-- Floored at what the skewer is plainly worth, so a wrong one is never a loss, only never a premium
	return math.round(math.max(order.Quote * accuracy * cookFactor, StickModel.GetSellValue(delivered)))
end

-- Answers a hand-over made with nothing in hand, or with something that isn't a BBQ at all.
function CustomOrderNpcManager:_scoldEmptyHanded(player: Player, npc: Model, record)
	local now = workspace:GetServerTimeNow()

	-- Re-derived rather than advanced, so a server hitch can't queue two back to back. The first press
	-- is never swallowed, since a record starts without a stamp
	if record.lastScoldAt and now - record.lastScoldAt < CustomOrderNpc.EMPTY_HANDED_INTERVAL then
		return
	end
	record.lastScoldAt = now

	self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCEmptyHanded")

	-- No toast: unlike the hurry beat, this answers a prompt they're stood in front of, so the bubble
	-- is already in their eyeline. Limited, or a Reject toast landing at the same moment doubles up
	-- On the rig's root rather than its server pivot, which played it at the stall for a customer sat at a table
	SoundManager:PlaySound({ Type = "Player", Player = player }, "Reject", npc.HumanoidRootPart, nil, { Limit = true })
end

-- Takes the held skewer for the order, however well it matches. Never refuses one -- the price is the answer.
function CustomOrderNpcManager:DeliverOrder(player: Player, npc: Model)
	if self._delivering[player] then
		return
	end

	local record = nil
	for _, tracked in self._npcs[player] or {} do
		if tracked.npc == npc and tracked.awaitingDelivery then
			record = tracked
			break
		end
	end
	if not record then
		return
	end

	-- The read yields, so the whole window is guarded or a spammed prompt could bank the same skewer twice
	self._delivering[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or not record.awaitingDelivery then
		self._delivering[player] = nil
		return
	end

	-- The prompt is up for the whole order rather than only while they hold one, so pressing it empty
	-- handed is an ordinary thing to do and has to be answered rather than dropped
	local delivered = StickManager:GetEquippedFilledStick(player, data)
	if not delivered then
		self:_scoldEmptyHanded(player, npc, record)
		self._delivering[player] = nil
		return
	end

	-- The skewer changes hands, so it leaves the inventory and the held visual with it
	PlayerDataManager:SetPlayerDataKey(player, { "FilledSticks", delivered.Uid }, nil)

	-- Set last, so the waiting loop only wakes on a delivery that is already banked
	record.delivered = delivered
	record.awaitingDelivery = false
	self._delivering[player] = nil
end

-- Locks the best BBQ in `skewers` for each waiting custom order customer to walk over and collect: cooked, with every ingredient it asked for, fewest extras first, never one already held. True if it took any.
function CustomOrderNpcManager:ClaimStandSkewerForOrder(player: Player, skewers): boolean
	-- The tutorial's customers are waiting on the skewers it places, so an order restored or forced into it leaves them be
	if SellNpcManager:AreCustomersGuaranteed(player) then
		return false
	end

	local awaiting = {}
	for _, record in self._npcs[player] or {} do
		if record.awaitingDelivery then
			table.insert(awaiting, record)
		end
	end

	-- Soonest out first, so a BBQ that fills two orders goes to the customer closest to walking
	table.sort(awaiting, function(a, b)
		return a.deadline < b.deadline
	end)

	-- Grows as this claims, so one BBQ is never sent for twice
	local held = self:GetHeldStandSkewerUids(player)
	local claimed = false

	for _, record in awaiting do
		local order = record.order
		local best, bestExtras, bestPaid = nil, math.huge, 0

		for _, skewer in skewers do
			-- Raw isn't theirs to take, a BBQ with no uid couldn't be held against the other customers, and a held one is spoken for
			if not skewer.Cooked or not skewer.Uid or held[skewer.Uid] then
				continue
			end

			local matched, extras = measureDelivery(order, skewer)
			if matched < #order.Ingredients or extras > bestExtras then
				continue
			end

			local paid = self:_gradeDelivery(order, skewer)
			if extras < bestExtras or paid > bestPaid then
				best, bestExtras, bestPaid = skewer, extras, paid
			end
		end

		if best then
			held[best.Uid] = true
			claimed = true

			-- Dropping out of the wait is what sends it over, and what stops a hand-over paying for the same order mid-walk
			record.standSkewerUid = best.Uid
			record.awaitingDelivery = false
		end
	end

	return claimed
end

-- The uids of every BBQ on the stand held for the player's custom order customers, which no other customer may take.
function CustomOrderNpcManager:GetHeldStandSkewerUids(player: Player): { [string]: true }
	local held = {}

	for _, record in self._npcs[player] or {} do
		if record.standSkewerUid then
			held[record.standSkewerUid] = true
		end
	end

	return held
end

-- The payout toast. Graded, so the number is explained by whatever cost them the most -- flat, it read
-- the same for a perfect fill and for a bag of the wrong thing. `bonusTable` names a table that paid extra.
function CustomOrderNpcManager:_notifyDelivered(player: Player, order, delivered, banked: number, bonusTable)
	local matched, extras = measureDelivery(order, delivered)
	local missing = #order.Ingredients - matched
	local cookState = CookStates.GetStateFromId(StickModel.GetCookStateId(delivered))

	-- One line names one thing, so it names whichever went wrong first: the recipe is the bigger lever,
	-- and a wrong recipe makes the cook state beside the point
	local text, effect
	if matched == 0 then
		text, effect = "That wasn't their order, so they only paid what it's worth: {value}", "Error"
	elseif missing > 0 and extras > 0 then
		text, effect = "Wrong ingredients on that one, so they paid less: {value}", "Error"
	elseif missing > 0 then
		text, effect = "Missing ingredients, so they paid less: {value}", "Error"
	elseif extras > 0 then
		-- Not put on the player: a worker filling the stick out is the usual way extras end up on one
		text, effect = "Extra ingredients on that one, so they paid less: {value}", "Error"
	elseif cookState.Id ~= PERFECT_COOK_STATE then
		-- Not an error: they made the right thing, and the cook is what the ordinary sale ladder prices
		text = "Their order, but " .. GuiUtil.Colorize(cookState.Name, cookState.Color) .. " - they paid {value}"
	else
		text, effect = "Perfect order! {value}", "Success"
	end

	if bonusTable then
		text ..= ` ({GuiUtil.Colorize(bonusTable.Name, bonusTable.TextColor)} bonus)`
	end

	-- {value} is NotificationManager's placeholder for Count, so it must survive uninterpolated
	NotificationManager:NotifyNormal(player, {
		Text = text,
		Duration = 4,
		Effect = effect,
		Count = {
			Value = banked,
			Format = "Price",
			Color = Colors.Currency,
		},
	})
end

-- Says the two beats a hand-over earns: what they made, and then how it cooked.
function CustomOrderNpcManager:_sayDeliveryReaction(npc: Model, order, delivered)
	local matched, extras = measureDelivery(order, delivered)

	-- An exact fill gets one clean reaction; anything else is remarked on before the cook is
	if matched < #order.Ingredients or extras > 0 then
		local category = if matched == 0
			then "CustomNPCDeliveredWrong"
			elseif matched == #order.Ingredients then "CustomNPCDeliveredExtras"
			else "CustomNPCDeliveredPartial"
		self.CustomOrderSayEvent:FireAllClients(npc, category)
		task.wait(1)
	end

	-- The variant is only knowable now: it arrived holding nothing, so the client has none stored
	self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCDelivered", StickModel.GetDialogueVariant(delivered))
end

-- Waits out the deadline, flagging the customer as it runs down. Returns the delivered skewer, or nil on an expiry, a BBQ held for it on the stand, or its table being picked up (still awaiting).
function CustomOrderNpcManager:_awaitDelivery(player: Player, npc: Model, record)
	local nextHurry = record.deadline - CustomOrderNpc.HURRY_THRESHOLD

	while record.awaitingDelivery and npc.Parent ~= nil do
		local now = workspace:GetServerTimeNow()
		if now >= record.deadline then
			break
		end

		-- Its table was picked up from under it, so it goes on waiting, just somewhere else
		if record.seat and not record.seat:IsDescendantOf(workspace) then
			record.seat, record.seatTable = nil, nil
			return nil
		end

		if now >= nextHurry then
			-- Re-derived rather than advanced, so a server hitch can't queue two nudges back to back
			nextHurry = now + CustomOrderNpc.HURRY_INTERVAL

			self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCHurry")
			NotificationManager:NotifyNormal(player, {
				Text = "Your custom order is about to walk out!",
				Duration = 3,
				Sound = "CustomerPinged",
				Effect = "Error",
			})

			-- The toast says an order is running out; this says which customer, for a base with a queue on it
			EffectManager:RunEffect({ Type = "Player", Player = player }, "HighlightPulse", {
				npc,
				CustomOrderNpc.HURRY_PULSE_COLOR,
				CustomOrderNpc.HURRY_PULSE_DURATION,
				CustomOrderNpc.HURRY_PULSE_START_TRANSPARENCY,
				CustomOrderNpc.HURRY_PULSE_COUNT,
			})
		end

		task.wait(DELIVERY_POLL_INTERVAL)
	end

	record.awaitingDelivery = false
	return record.delivered
end

-- The toast that calls the player over, or back to `returningCount` restored orders. Timed differently per variation, so it's its own method.
function CustomOrderNpcManager:_notifyArrived(
	player: Player,
	firstVisit: boolean?,
	returningCount: number?,
	rich: boolean?
)
	-- Their first says why it's worth taking, since the recipe card shows what it wants but not that it pays more
	NotificationManager:NotifyNormal(player, {
		Text = if returningCount and returningCount > 1
			then "Your customers waited for you! Finish their orders"
			elseif returningCount then "Your customer waited for you! Finish their order"
			elseif firstVisit then "Someone's here with a custom order! It pays extra!"
			elseif rich then `A {RichNpc.LABEL} customer is here with a custom order!`
			else "Someone's here with a custom order!",
		-- The ones that carry a second sentence get the longer read
		Duration = if firstVisit or returningCount then 4 else 3,
		Sound = if rich and not returningCount then "RichSpawn" else "CustomerArrived",
	})
end

-- Puts the order to the player and waits for an answer. True if they took it on.
function CustomOrderNpcManager:_offerOrder(player: Player, npc: Model, record)
	NpcRig.PlayAnimation(record, "Inspect", self._rng)
	self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCRequest")

	local order = record.order

	-- The boosted figure, since that's what lands in their balance, badged against the plain worth
	local payout = CurrencyManager:GetBoostedAmount(player, order.Quote)
	local bonus = math.round((payout / order.Value - 1) * 100)

	record.offerPending = true
	record.offerResponse = nil

	-- Banked as the card goes up, so an unanswered offer is still theirs to answer on the next join
	self:SaveActiveOrder(player, record, CustomOrderNpc.PHASES.Pending)

	StatsManager:RecordCustomOrderOffered(player)
	self.OnCustomOrderOffered:Fire(player, order, payout, record.variation, record.firstVisit, record.funnelId)
	self:_publishOrder(record, CustomOrderNpc.PHASES.Pending, payout, bonus)

	-- The rest of the introduction, tied to the offer so it lands with the card and clock it describes
	if record.firstVisit then
		NotificationManager:NotifyNormal(player, {
			Text = "Make exactly what they ask for before their timer runs out",
			Duration = 5,
			-- Not CustomerArrived, or the second toast sounds like a second customer
			Sound = "Notify",
		})
	end

	-- Never waits forever -- an ignored order would hold its cooldown for the rest of the session
	local deadline = os.clock() + CustomOrderNpc.OFFER_TIMEOUT
	while record.offerResponse == nil and os.clock() < deadline and npc.Parent ~= nil do
		task.wait()
	end
	record.offerPending = false

	return npc.Parent ~= nil and record.offerResponse == true
end

-- Where it waits once the deal is struck: the side fewer of the player's customers wait on, stepped out past any already there. Marks that side as its own.
function CustomOrderNpcManager:_claimWaitPosition(
	player: Player,
	record,
	spawnPart: BasePart,
	standPart: BasePart
): Vector3
	-- Off the stand's centre, not the lane it queued in -- measured from the lane, the two could cancel
	local standCentre = standPart.Position

	-- Flattened, so a spawn part at another height can't tilt the step or shorten the one across
	local backDir = ((spawnPart.Position - standCentre) * Vector3.new(1, 0, 1)).Unit
	local sideDir = Vector3.new(-backDir.Z, 0, backDir.X)

	local waiting = { [-1] = 0, [1] = 0 }
	for _, other in self._npcs[player] or {} do
		if other.waitSide then
			waiting[other.waitSide] += 1
		end
	end

	-- The emptier side, so orders running at once don't wait inside each other; a tie is rolled, so a lone one turns up either side
	record.waitSide = if waiting[-1] < waiting[1]
		then -1
		elseif waiting[1] < waiting[-1] then 1
		elseif self._rng:NextNumber() < 0.5 then -1
		else 1

	-- Off to one side rather than straight back, so it waits out of the way but stays in sight
	local side = (
		self._rng:NextNumber(CustomOrderNpc.WAIT_SIDE_DISTANCE_MIN, CustomOrderNpc.WAIT_SIDE_DISTANCE_MAX)
		+ CustomOrderNpc.WAIT_STEP_OUT * waiting[record.waitSide]
	) * record.waitSide

	return standCentre + backDir * CustomOrderNpc.WAIT_BACK_DISTANCE + sideDir * side
end

-- Walks the customer off the base and pools it, on whichever line the visit ended.
function CustomOrderNpcManager:_leave(player: Player, npc: Model, record, humanoid: Humanoid, spawnPart: BasePart)
	task.wait(SellNpc.LEAVE_DELAY)
	if npc.Parent == nil then
		return
	end

	NpcRig.StopAnimation(record)
	unseatCustomer(humanoid)
	record.seat, record.seatTable = nil, nil
	NpcRig.WalkTo(humanoid, spawnPart.Position)
	self:_despawnNpc(player, record)
end

-- Every seat on the player's placed tables, taken or not.
function CustomOrderNpcManager:CountPlacedSeats(data): number
	local count = 0

	for _, placed in data.Structures do
		-- SeatCount is 0 on anything without a Seats folder, so only tables add to it
		local structure = Structures.GetStructureFromId(placed.Type)
		if structure then
			count += structure.SeatCount
		end
	end

	return count
end

-- How many of the player's seats no customer has claimed, which is what brings the next one in sooner.
function CustomOrderNpcManager:CountFreeSeats(player: Player, data): number
	local taken = 0

	for _, record in self._npcs[player] or {} do
		if record.seat then
			taken += 1
		end
	end

	return math.max(self:CountPlacedSeats(data) - taken, 0)
end

-- The unclaimed seats on the player's placed tables, each with the table config it belongs to.
function CustomOrderNpcManager:_getFreeSeats(player: Player, data): { { Seat: Seat, Table: Structures.Structure } }
	local base = BaseManager:GetBaseFromPlayer(player)
	if not base then
		return {}
	end

	local taken = {}
	for _, record in self._npcs[player] or {} do
		if record.seat then
			taken[record.seat] = true
		end
	end

	local free = {}
	for uid, placed in data.Structures do
		local structure = Structures.GetStructureFromId(placed.Type)
		if not structure or structure.SeatCount == 0 then
			continue
		end

		-- Missing while the base is still rendering it, which just means no seat there yet
		local model = base:GetStructureModel(uid)
		local seats = model and model:FindFirstChild(Structures.SEATS_NAME)
		if not seats then
			continue
		end

		for _, seat in seats:GetChildren() do
			if seat:IsA("Seat") and not taken[seat] then
				table.insert(free, { Seat = seat, Table = structure })
			end
		end
	end

	return free
end

-- Claims the best free seat for the customer: a rich one heads for a table that draws them, then anyone for the best payout. False if none is free.
function CustomOrderNpcManager:_claimSeat(player: Player, record, data): boolean
	local best, bestScore = nil, -math.huge

	for _, candidate in self:_getFreeSeats(player, data) do
		local structure = candidate.Table

		-- The random fraction is under the payout step, so it only breaks ties between equal seats
		local score = (if record.isRich and structure.RichChanceBonus then 100 else 0)
			+ (structure.CustomerPayoutMultiplier or 1) * 10
			+ self._rng:NextNumber()

		if score > bestScore then
			best, bestScore = candidate, score
		end
	end

	if not best then
		return false
	end

	record.seat, record.seatTable = best.Seat, best.Table
	return true
end

-- Walks the customer to its claimed seat and sits it down. False if the rig or the table went while it walked.
function CustomOrderNpcManager:_seatCustomer(record, humanoid: Humanoid): boolean
	NpcRig.WalkTo(humanoid, record.seat.Position)

	if record.npc.Parent == nil or not record.seat:IsDescendantOf(workspace) then
		return false
	end

	record.seat:Sit(humanoid)
	return true
end

-- The chance out of 100 that a visit is a rich customer: the base chance plus every placed table that draws them.
function CustomOrderNpcManager:GetRichChance(data): number
	local chance = CustomOrderNpc.RICH_CHANCE

	for _, placed in data.Structures do
		local structure = Structures.GetStructureFromId(placed.Type)
		if structure and structure.RichChanceBonus then
			chance += structure.RichChanceBonus
		end
	end

	return math.min(chance, CustomOrderNpc.RICH_CHANCE_MAX)
end

-- Runs one whole visit: the ask, the wait, and whatever gets handed over. A `rich` of true forces a rich customer, false an ordinary one, nil rolls for it.
function CustomOrderNpcManager:_spawnCustomOrderCustomer(
	player: Player,
	variation: string?,
	firstVisit: boolean?,
	saved,
	rich: boolean?
): string?
	local spawnPart, standPart = NpcRig.GetBaseParts(player)
	if not spawnPart or not standPart then
		return "their base has no NPCSpawnPart or NPCStandPart"
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return "their profile isn't loaded"
	end

	-- Built before the rig is claimed, since an order nobody could fill is a visit not worth making
	local order = nil
	if saved then
		order = restoreOrder(saved)
	else
		-- Never the introduction, which has to teach the ordinary order first
		if rich == nil then
			rich = not firstVisit and RandomUtil.RollChance(self:GetRichChance(data), self._rng)
		end

		-- A rich one with nothing Rare+ in reach turns into an ordinary visit rather than none
		order = if rich then self:_buildOrder(data, true) else nil
		order = order or self:_buildOrder(data)
	end
	if not order then
		return "no order could be built from the roster"
	end

	local isRich = order.Rich == true

	local tracked = self._npcs[player]
	if not tracked then
		tracked = {}
		self._npcs[player] = tracked
	end

	-- The sell stand's slot allocator, so this one lines up beside its customers rather than inside them
	local slot, standPosition = NpcRig.ClaimStandPosition(player, spawnPart, standPart)

	-- A saved order comes back wearing the look it left in; one saved before looks were kept has none, and rolls fresh
	local savedLook = if saved then saved.Look else nil

	local npc = if isRich then SellNpcManager:AcquireRichNpc(savedLook) else NpcRig.Acquire()
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	-- Tracked before anything yields, so the pacing check counts it and a mid-lookup cleanup destroys the rig rather than orphaning it
	-- Carried on the record rather than threaded on, since both toasts read it from different beats
	local record = {
		npc = npc,
		slot = slot,
		standPosition = standPosition,
		order = order,
		isRich = isRich,
		-- Saved with the order, so a restore brings back the same character rather than a fresh roll
		look = if isRich then npc.Name else nil,
		-- Both come off the save on a restore, so an interrupted introduction still reads as one and the
		-- funnel follows the same order across the rejoin rather than starting a second one
		firstVisit = if saved then saved.FirstVisit else firstVisit,
		-- One id for the whole visit, so the analytics funnel can follow this order across its three beats
		funnelId = if saved then saved.FunnelId else HttpService:GenerateGUID(false),
		thread = coroutine.running(),
	}
	table.insert(tracked, record)

	-- A rich customer is its own character, so there's no appearance to look up
	local description = nil
	if not isRich then
		description, record.look = NpcRig.GetCustomerDescription(player, self._rng, savedLook)
	end
	if npc.Parent == nil then
		return
	end
	if description then
		humanoid:ApplyDescriptionReset(description)
		if npc.Parent == nil then
			return
		end
		-- Applying a description rebuilds the rig's accessory parts, so re-stamp the collision group.
		CollisionManager:SetModelGroup(npc, CollisionManager.NPC)
	end

	-- Primed while still parked, so the rig fades in rather than popping when it's revealed
	NpcRig.Fade(npc, true, SellNpc.FADE_IN_DURATION)

	local point = NpcRig.RandomPointOn(spawnPart, self._rng)
	npc:PivotTo(CFrame.lookAt(point + Vector3.new(0, 3, 0), standPosition))

	-- Stamped before it lands, so it arrives with the rig rather than a frame behind it
	npc:SetAttribute(Structures.OWNER_ATTRIBUTE, player.UserId)
	npc.Parent = workspace

	-- Tagged after, so a client's tag hook can trust the owner stamp is already on
	npc:AddTag(CustomOrderNpc.TAG)

	-- Server-driven movement, so hand the root to the server rather than a nearby client.
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if rootPart and not rootPart.Anchored then
		rootPart:SetNetworkOwner(nil)
	end

	-- A frame between parenting the rig and naming it over a remote. Fired in the same frame the two go
	-- out together, and a client the model hasn't reached yet decodes the argument as nil and silently
	-- drops the opening line. The billboards ride the tag, so only the bubble is at stake
	task.wait()

	if npc.Parent == nil then
		return
	end

	-- A restored order was asked and answered already, so it walks back in without browsing anything
	local inspecting = not saved and if variation
		then variation == CustomOrderNpc.VARIATIONS.Inspect
		-- Nothing on the stand means nothing to look over, so that variation has no beat to play
		else SkewerStandManager:GetPlacedSkewerCount(player) > 0 and RandomUtil.RollChance(
			CustomOrderNpc.INSPECT_CHANCE,
			self._rng
		)

	-- Kept for the offer beat, which is where the two openings are worth telling apart
	record.variation = if inspecting then CustomOrderNpc.VARIATIONS.Inspect else CustomOrderNpc.VARIATIONS.Direct

	-- A Direct one announces itself on arrival and an Inspect one holds its toast for the verdict; restores share the one sent as they're spawned
	if not saved and not inspecting then
		self:_notifyArrived(player, firstVisit, nil, isRich)
	end

	-- Picked here, so the client doesn't have to work out which of the three openings this is
	local greeting = if saved
		then "CustomNPCReturned"
		elseif inspecting then "CustomNPCInspecting"
		else "CustomNPCArrived"

	self.CustomOrderSayEvent:FireAllClients(npc, greeting)

	-- An accepted restore has already been to the stand, so it walks straight to where it waits rather
	-- than queueing up to be served again. _runAcceptedOrder below is what takes it there
	if not (saved and saved.Phase == CustomOrderNpc.PHASES.Accepted) then
		NpcRig.WalkTo(humanoid, standPosition)
	end

	if npc.Parent == nil then
		return
	end

	-- It looks the stand over and turns it down without taking anything: the sell customers are still
	-- competing for those skewers, and the flip reads the same whether it holds one or not
	if inspecting then
		local duration = self._rng:NextNumber(SellNpc.DECIDE_DURATION_MIN, SellNpc.DECIDE_DURATION_MAX)
		self.CustomOrderInspectEvent:FireAllClients(npc, workspace:GetServerTimeNow() + duration)

		-- Split on the verdict landing, which is the beat the toast is held for
		task.wait(duration)
		if npc.Parent == nil then
			return
		end

		self:_notifyArrived(player, firstVisit, nil, isRich)
		task.wait(CustomOrderNpc.REQUEST_DELAY)

		if npc.Parent == nil then
			return
		end
	end

	-- An accepted order re-enters at the deal. Re-asking would double-count CustomOrdersOffered and
	-- re-fire the funnel for a question they have already answered
	if saved and saved.Phase == CustomOrderNpc.PHASES.Accepted then
		-- Restamped off what was banked rather than off the old deadline, so time offline never ran it down
		record.deadline = workspace:GetServerTimeNow() + (saved.SecondsLeft or 0)
		return self:_runAcceptedOrder(player, npc, record, humanoid, spawnPart, standPart)
	end

	if not self:_offerOrder(player, npc, record) then
		if npc.Parent == nil then
			return
		end

		self:_publishOrder(record, nil)

		-- Ignored and turned down are different things, so they leave on different lines
		local ignored = record.offerResponse == nil
		local category = if ignored then "CustomNPCOfferIgnored" else "CustomNPCPlayerDeclined"
		self.CustomOrderSayEvent:FireAllClients(npc, category)
		self:_recordOutcome(player, record, if ignored then "Ignored" else "Declined", nil, 0)

		self:_leave(player, npc, record, humanoid, spawnPart)
		return
	end

	StatsManager:RecordCustomOrderAccepted(player)
	self.OnCustomOrderAccepted:Fire(player, order, record.funnelId)
	self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCPlayerAccepted")

	record.deadline = workspace:GetServerTimeNow() + order.Seconds
	return self:_runAcceptedOrder(player, npc, record, humanoid, spawnPart, standPart)
end

-- The accepted half: step aside with the clock running, then take whatever gets handed over or put out for it. Split out
-- so an order restored from a rejoin can re-enter here without replaying the ask it already answered.
function CustomOrderNpcManager:_runAcceptedOrder(
	player: Player,
	npc: Model,
	record,
	humanoid: Humanoid,
	spawnPart: BasePart,
	standPart: BasePart
)
	local order = record.order

	-- Dropped for the wait, so the rig falls back to its own idle rather than inspecting nothing
	NpcRig.StopAnimation(record)

	-- Live from here, so the rolling stand can start steering toward what the order still wants
	record.awaitingDelivery = true

	-- Rebanked over the pending one, now that there is a clock on it worth coming back to
	self:SaveActiveOrder(player, record, CustomOrderNpc.PHASES.Accepted)
	self:_publishOrder(record, CustomOrderNpc.PHASES.Accepted)

	local delivered = nil
	local waitPosition = nil
	local collected = false

	while not delivered do
		-- Looked over before it steps aside, so a BBQ of theirs already out is collected from the lane it's stood in
		local data = PlayerDataManager:GetLoadedPlayerData(player)
		if data then
			self:ClaimStandSkewerForOrder(player, data.SkewerStand)
		end

		if record.standSkewerUid then
			-- Claimed before the walk yields, so a teardown mid-walk still hands the lane back
			if not record.slot then
				record.slot, record.standPosition = NpcRig.ClaimStandPosition(player, spawnPart, standPart)
			end

			-- Up from its table, which stays claimed so it comes back to eat there
			unseatCustomer(humanoid)

			self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCCollecting")
			NpcRig.WalkTo(humanoid, record.standPosition)

			if npc.Parent == nil then
				return
			end

			delivered = SkewerStandManager:TakeSkewer(player, record.standSkewerUid)
			record.standSkewerUid = nil
			collected = delivered ~= nil

			-- The player took it back before it got there, so it looks the stand over again from its lane
			if not collected then
				record.awaitingDelivery = true
			end
		else
			-- It has stepped aside, so holding a lane would block the sell customers behind it
			NpcRig.ReleaseSlot(player, record.slot)
			record.slot = nil

			-- A free seat beats standing aside, and one it already holds is walked back to
			local seated = false
			if record.seat or (data and self:_claimSeat(player, record, data)) then
				seated = self:_seatCustomer(record, humanoid)
				if not seated then
					record.seat, record.seatTable = nil, nil
				end
			end

			if npc.Parent == nil then
				return
			end

			if seated then
				-- Off the stand's sides, so the customers still stood there spread out as though it had gone
				waitPosition, record.waitSide = nil, nil
			else
				waitPosition = waitPosition or self:_claimWaitPosition(player, record, spawnPart, standPart)
				NpcRig.WalkTo(humanoid, waitPosition)

				if npc.Parent == nil then
					return
				end

				-- Turned back toward the stand, so it waits watching the player rather than facing off the base
				npc:PivotTo(CFrame.lookAt(npc:GetPivot().Position, standPart.Position))
			end

			self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCWaiting")

			delivered = self:_awaitDelivery(player, npc, record)

			-- Out of time, rather than sent over for a BBQ held for it on the stand or stood up by its table going
			if not delivered and not record.standSkewerUid and not record.awaitingDelivery then
				break
			end
		end
	end

	if npc.Parent == nil then
		return
	end

	self:_publishOrder(record, nil)

	if not delivered then
		self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCExpired")
		self:_recordOutcome(player, record, "Expired", nil, 0)

		-- No error effect: they lost the order but did nothing wrong
		NotificationManager:NotifyNormal(player, {
			Text = "Your custom order ran out of time!",
			Duration = 3,
			Sound = "Reject",
		})

		self:_leave(player, npc, record, humanoid, spawnPart)
		return
	end

	-- Read off the table it waited at, even when it went to the stand to collect, since it eats back there
	local bonusTable = record.seatTable and record.seatTable.CustomerPayoutMultiplier and record.seatTable
	local paid = self:_gradeDelivery(order, delivered)
	if bonusTable then
		paid = math.round(paid * bonusTable.CustomerPayoutMultiplier)
	end

	local banked = CurrencyManager:GetBoostedAmount(player, paid)

	-- The plain figure -- applying boosts is IncrementCurrency's job, and a boosted one would double it
	CurrencyManager:IncrementCurrency(player, paid, "CustomOrder")

	self:_recordOutcome(player, record, "Delivered", delivered, banked)
	StatsManager:RecordSaleCompleted(player, { delivered })

	-- Put in its hand now rather than on arrival, since what it walks off with is whatever they made
	record.tool, record.skewerModel = NpcRig.GiveSkewer(npc, delivered)

	-- The payout lets each projectile pop a "+X" that adds up to the counter's jump
	EffectManager:RunEffect("All", "CollectCash", { npc, banked, player })

	self:_notifyDelivered(player, order, delivered, banked, bonusTable)

	self:_sayDeliveryReaction(npc, order, delivered)

	-- Bought off the stand, so it goes back to its seat, or moves out of the lane to eat among the other buyers
	if collected and npc.Parent ~= nil then
		local reseated = record.seat ~= nil and self:_seatCustomer(record, humanoid)

		if npc.Parent == nil then
			return
		end

		if not reseated then
			record.seat, record.seatTable = nil, nil
			NpcRig.WalkTo(humanoid, NpcRig.GetEatPosition(spawnPart, record.standPosition, self._rng))

			if npc.Parent == nil then
				return
			end

			-- Faced a random way, so it doesn't eat staring the same way as the buyers around it
			npc:PivotTo(CFrame.new(npc:GetPivot().Position) * CFrame.Angles(0, self._rng:NextNumber(0, math.pi * 2), 0))
		end
	end

	local seated = record.seat ~= nil and record.seat:IsDescendantOf(workspace)

	NpcRig.PlayAnimation(record, "Eat", self._rng)
	self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCEating")

	-- Never in the tutorial, whose beats a tip would talk over
	if not SellNpcManager:AreCustomersGuaranteed(player) then
		CustomerTipManager:RollCustomOrderTip(
			player,
			npc,
			delivered,
			getOrderAccuracy(order, delivered),
			seated,
			record.isRich,
			function()
				self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCTipping")
			end
		)
	end

	NpcRig.EatSkewerIngredients(
		record.skewerModel,
		if seated then CustomOrderNpc.SEATED_EAT_DURATION else SellNpc.EAT_DURATION
	)

	if npc.Parent == nil then
		return
	end

	self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCLeaving")
	NpcRig.StopAnimation(record)
	unseatCustomer(humanoid)
	record.seat, record.seatTable = nil, nil
	NpcRig.WalkTo(humanoid, spawnPart.Position)
	self:_despawnNpc(player, record)
end

-- Runs one visit with its failure contained, releasing the rig and slot a throw would strand.
function CustomOrderNpcManager:_runGuardedVisit(
	player: Player,
	variation: string?,
	firstVisit: boolean?,
	saved,
	rich: boolean?
)
	local success, result = xpcall(function()
		return self:_spawnCustomOrderCustomer(player, variation, firstVisit, saved, rich)
	end, debug.traceback)

	-- A restore that died drops its own entry, or it sits unrestored and holds every fresh order back for good
	if saved and (not success or result) then
		PlayerDataManager:SetPlayerDataKey(player, { "ActiveCustomOrders", saved.FunnelId }, nil)
	end

	if success then
		-- Said out loud, or a visit that bails before it spawns anything looks like nothing happened
		if result then
			warn(`[CustomOrderNpcManager] No custom order sent to {player.Name}: {result}`)
		end

		return
	end

	warn(`[CustomOrderNpcManager] Custom order visit for {player.Name} failed, releasing its customer:\n{result}`)

	-- Snapshotted first: _despawnNpc removes from the tracked list as it goes, and yields through the fade
	local thread = coroutine.running()
	local orphaned = {}
	for _, record in self._npcs[player] or {} do
		if record.thread == thread then
			-- Owed nothing from here, so steering, a stand claim and a last save all pass it over during the fade
			record.offerPending, record.awaitingDelivery, record.standSkewerUid = false, false, nil
			PlayerDataManager:SetPlayerDataKey(player, { "ActiveCustomOrders", record.funnelId }, nil)
			table.insert(orphaned, record)
		end
	end

	for _, record in orphaned do
		self:_despawnNpc(player, record)
	end
end

-- Whether the player has the machinery to fill an order at all: either half is enough.
function CustomOrderNpcManager:IsUnlocked(data): boolean
	return GrillerManager:CountPlacedGrillers(data) >= CustomOrderNpc.MIN_GRILLERS
		or data.Unlocks.RollingStands >= CustomOrderNpc.MIN_ROLLING_STANDS
end

-- How many custom orders the base can have running at once: the CONCURRENT_ORDER_MARKS rows it clears, in order.
function CustomOrderNpcManager:GetMaxConcurrentOrders(data): number
	local grillers = GrillerManager:CountPlacedGrillers(data)
	local stickStands = StickStandManager:CountPlacedStickStands(data)
	local seats = self:CountPlacedSeats(data)
	local count = 0

	for _, mark in CustomOrderNpc.CONCURRENT_ORDER_MARKS do
		-- Stopped at the first row missed, so a row that doesn't climb in every column can't be cleared past one that does
		if grillers < mark.Grillers or stickStands < mark.StickStands or seats < mark.Seats then
			break
		end

		count += 1
	end

	return count
end

-- Sends the one guaranteed order if the player has just reached the requirement. Returns true if it sent one.
function CustomOrderNpcManager:TrySendFirstCustomOrder(player: Player): boolean
	if not validatePlayer(player) or self._grantedFirstOrder[player] then
		return false
	end

	-- Not during the tutorial -- it has its own beats to teach, and this would talk over them
	if SellNpcManager:AreCustomersGuaranteed(player) then
		return false
	end

	if self:HasCustomOrder(player) then
		return false
	end

	-- Gated on hasData, or a profile that failed to load sends one on every placement for the session
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or data.SeenCustomOrder or not self:IsUnlocked(data) then
		return false
	end

	-- Latched before the writes, which yield, and stamped as the roll stamps it so the timer can't double up
	self._grantedFirstOrder[player] = true
	PlayerDataManager:SetPlayerDataKey(player, "SeenCustomOrder", true)
	PlayerDataManager:SetPlayerDataKey(player, "LastCustomOrderVisit", workspace:GetServerTimeNow())

	-- Direct, since a first encounter opening on a Not Interested verdict reads as a rejection
	self:_runGuardedVisit(player, CustomOrderNpc.VARIATIONS.Direct, true)

	return true
end

-- Their join beat: orders left standing come back first, and only if there were none does the guaranteed first order get its chance. Yields, so callers spawn it with the restoring latch set.
function CustomOrderNpcManager:ResumeCustomOrdersForPlayer(player: Player)
	-- Only a short wait on the restore, so an order they left standing is there as they load in rather than a quarter of a minute later
	local restored = self:TryRestoreCustomOrders(player)

	-- Dropped once the restore has spawned: those customers are tracked and not waiting yet, so the pacing check holds fresh ones back
	self._restoring[player] = nil

	if restored then
		return
	end

	-- A customer's ordinary wait, so a fresh one doesn't materialise the instant they load in -- and so
	-- the base has finished building the spawn and stand parts the visit reads off it
	task.wait(SellNpc.SPAWN_DELAY_MAX)
	self:TrySendFirstCustomOrder(player)
end

-- Brings back every order the player left part-way through, together, each a fresh rig wearing its deal. True if they had any saved.
function CustomOrderNpcManager:TryRestoreCustomOrders(player: Player): boolean
	if not validatePlayer(player) then
		return false
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or next(data.ActiveCustomOrders) == nil then
		return false
	end

	-- A beat before they turn up, rather than materialising on a client still loading its base in
	task.wait(CustomOrderNpc.RESTORE_DELAY)

	-- Read after the wait, so customers a second join beat already brought back aren't sent twice
	local unrestored = self:_getUnrestoredOrders(player, data)
	if not validatePlayer(player) or next(unrestored) == nil then
		return true
	end

	-- Counted as an arrival, so the next fresh order is spaced from these as it would be from any other
	PlayerDataManager:SetPlayerDataKey(player, "LastCustomOrderVisit", workspace:GetServerTimeNow())

	local count = 0
	for _, saved in unrestored do
		count += 1

		-- Each on its own thread, since a visit's orphans are found by the thread it ran on
		task.spawn(function()
			self:_runGuardedVisit(player, nil, nil, saved)
		end)
	end

	-- One toast however many came back, since they turn up together
	self:_notifyArrived(player, nil, count)

	return true
end

-- One pass of the custom-order roll, cheapest checks first. The chance counts their free seats, so it waits on the data read.
function CustomOrderNpcManager:_rollCustomOrderVisits()
	for _, player in Players:GetPlayers() do
		if not validatePlayer(player) then
			continue
		end

		-- Not during the tutorial -- it has its own beats to teach, and this would talk over them
		if SellNpcManager:AreCustomersGuaranteed(player) then
			continue
		end

		local hasData, data = PlayerDataManager:GetPlayerData(player):await()
		if not hasData or not self:IsUnlocked(data) then
			continue
		end

		-- Room to sit them draws them in more often and sooner, each within its cap
		local freeSeats = self:CountFreeSeats(player, data)
		local chance = CustomOrderNpc.SPAWN_CHANCE
			+ math.min(freeSeats * CustomOrderNpc.SEAT_SPAWN_CHANCE_STEP, CustomOrderNpc.SEAT_SPAWN_CHANCE_MAX_BONUS)
		local cooldown = math.max(
			CustomOrderNpc.COOLDOWN - freeSeats * CustomOrderNpc.SEAT_COOLDOWN_STEP,
			CustomOrderNpc.SEAT_COOLDOWN_MIN
		)

		if not RandomUtil.RollChance(chance, self._rng) then
			continue
		end

		-- Read off the tracked customers rather than a flag, so an errored visit can't leave it stuck set
		if not self:CanSendAnotherCustomOrder(player, data) then
			continue
		end

		-- In their data on the synced clock, so rejoining can't hand out a fresh order
		if (workspace:GetServerTimeNow() - data.LastCustomOrderVisit) < cooldown then
			continue
		end

		-- Stamped before the visit, so a long order can't let another be rolled the moment this one leaves
		PlayerDataManager:SetPlayerDataKey(player, "LastCustomOrderVisit", workspace:GetServerTimeNow())

		task.spawn(function()
			self:_runGuardedVisit(player)
		end)
	end
end

-- Sends one now off the command bar, keeping only the checks that would leave it meaningless. A named `variation` or `rich` is forced; without one it rolls as an ordinary visit would.
function CustomOrderNpcManager:ForceCustomOrderVisit(
	player: Player,
	variation: string?,
	rich: boolean?
): (boolean, string?)
	if not validatePlayer(player) then
		return false, `{player.Name} has no base to send a customer to.`
	end

	local data = PlayerDataManager:GetLoadedPlayerData(player)
	if not self:CanSendAnotherCustomOrder(player, data) then
		return false,
			`{player.Name} can't take another custom order yet: one is still on its way, or their base has no room.`
	end

	-- Checked up front, since the visit itself quietly turns an unbuildable rich order into an ordinary one
	if rich and not self:_buildOrder(data, true) then
		return false, `{player.Name} has no Rare or better ingredient in reach, so no rich order can be built.`
	end

	-- Stamped as the roll stamps it, but not read, so the command can still be re-run straight away
	PlayerDataManager:SetPlayerDataKey(player, "LastCustomOrderVisit", workspace:GetServerTimeNow())

	local queued = variation == CustomOrderNpc.VARIATIONS.Inspect
		and SkewerStandManager:GetPlacedSkewerCount(player) == 0

	-- Latched before the spawn, so neither a second command nor the roll can stack one behind it
	self._queued[player] = queued or nil

	task.spawn(function()
		-- An Inspect visit has nothing to look over on an empty stand, so it waits for one rather than
		-- quietly downgrading itself to a Direct one and reading as the command having been ignored
		if queued then
			self:_awaitPlacedSkewer(player)
			self._queued[player] = nil

			if not validatePlayer(player) then
				return
			end
		end

		self:_runGuardedVisit(player, variation, nil, nil, rich)
	end)

	if queued then
		return true, `Queued an Inspect order for {player.Name} until their stand has a BBQ on it.`
	end

	return true
end

-- Whether any customer is with them or still on its way, which the guaranteed first order waits out so it lands alone.
function CustomOrderNpcManager:HasCustomOrder(player: Player): boolean
	return self._queued[player] == true
		or self._restoring[player] == true
		or #(self._npcs[player] or {}) > 0
end

-- The saved orders whose customer isn't with the player yet, by funnel id. A copy, so a restore can walk it while visits clear their entries.
function CustomOrderNpcManager:_getUnrestoredOrders(player: Player, data)
	local unrestored = table.clone(data.ActiveCustomOrders)

	for _, record in self._npcs[player] or {} do
		unrestored[record.funnelId] = nil
	end

	return unrestored
end

-- Whether a fresh custom order customer may come in now: every one already here is stood waiting on its BBQ, and the base has room for another.
function CustomOrderNpcManager:CanSendAnotherCustomOrder(player: Player, data): boolean
	if self._restoring[player] or self._queued[player] then
		return false
	end

	local tracked = self._npcs[player] or {}
	for _, record in tracked do
		-- One through the door at a time: anyone arriving, asking, collecting or leaving holds the next back, and the introduction is never joined
		if not record.awaitingDelivery or record.firstVisit then
			return false
		end
	end

	-- A saved order not back yet is the join beat's to bring, so a fresh one can't take its place
	if next(self:_getUnrestoredOrders(player, data)) ~= nil then
		return false
	end

	return #tracked < self:GetMaxConcurrentOrders(data)
end

-- Waits until the player has something on their stand to look over. Yields, possibly for a long time.
function CustomOrderNpcManager:_awaitPlacedSkewer(player: Player)
	-- The signal fires for every player, and the condition re-reads this one, so no filtering is needed
	while validatePlayer(player) and SkewerStandManager:GetPlacedSkewerCount(player) == 0 do
		SkewerStandManager.OnSkewerPlaced:Wait()
	end
end

-- Tears down a leaving player's customers. Destroyed, not pooled -- clearing the parent is what mid-visit guards bail on.
function CustomOrderNpcManager:_cleanupPlayer(player: Player)
	local tracked = self._npcs[player]
	if tracked then
		for _, record in tracked do
			if record.skewerModel then
				record.skewerModel:Destroy()
			end
			if record.tool then
				record.tool:Destroy()
			end
			record.npc:Destroy()
		end
		self._npcs[player] = nil
	end

	self._delivering[player] = nil
	self._queued[player] = nil
	self._restoring[player] = nil
	self._grantedFirstOrder[player] = nil
end

function CustomOrderNpcManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	SkewerStandManager = require(script.Parent.SkewerStandManager)
	CollisionManager = require(script.Parent.CollisionManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	NotificationManager = require(script.Parent.NotificationManager)
	EffectManager = require(script.Parent.EffectManager)
	StickManager = require(script.Parent.StickManager)
	StatsManager = require(script.Parent.StatsManager)
	SoundManager = require(script.Parent.SoundManager)
	SellNpcManager = require(script.Parent.SellNpcManager)
	GrillerManager = require(script.Parent.GrillerManager)
	StickStandManager = require(script.Parent.StickStandManager)
	BaseManager = require(script.Parent.BaseManager)

	-- On Init, so the fold is in place before any profile can finish loading
	PlayerDataManager:RegisterPostLoadCallback(function(_, data)
		self:MigrateLegacyActiveOrderOnLoad(data)
	end)
end

function CustomOrderNpcManager:OnStart()
	-- Idempotent, so this doesn't depend on SellNpcManager having started first
	NpcRig.BuildPool()

	-- Flattened once, since the roll runs per slot per order and the config is keyed by tier id
	for tierId, weight in CustomOrderNpc.TIER_WEIGHTS do
		if Ingredients.GetTierFromId(tierId) then
			table.insert(self._tierWeights, { tierId, weight })
		else
			warn(
				`[CustomOrderNpcManager] CustomOrderNpc.TIER_WEIGHTS names tier {tierId}, which Ingredients has no entry for`
			)
		end
	end

	for tierId, weight in CustomOrderNpc.RICH_TIER_WEIGHTS do
		local tier = Ingredients.GetTierFromId(tierId)
		if tier then
			table.insert(self._richTierWeights, { tierId, weight })
			self._richMinTierIndex = math.min(self._richMinTierIndex, tier.Index)
		else
			warn(
				`[CustomOrderNpcManager] CustomOrderNpc.RICH_TIER_WEIGHTS names tier {tierId}, which Ingredients has no entry for`
			)
		end
	end

	-- On a timer, so an order turns up while the player is off at the grill
	task.spawn(function()
		while true do
			task.wait(CustomOrderNpc.CHECK_INTERVAL)
			self:_rollCustomOrderVisits()
		end
	end)

	-- The moment they can fill one, their first is given rather than left to the roll. Spawned because
	-- the try reads their profile, and these three are the only ways the requirement is ever reached
	BaseManager.OnStructurePlaced:Connect(function(player: Player)
		task.spawn(function()
			self:TrySendFirstCustomOrder(player)
		end)
	end)

	BaseManager.OnUnlockPurchased:Connect(function(player: Player, unlockId: string)
		if unlockId ~= ROLLING_STANDS_UNLOCK then
			return
		end

		task.spawn(function()
			self:TrySendFirstCustomOrder(player)
		end)
	end)

	-- Catches anyone who crossed the requirement in an earlier session, since they'll never place again
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		-- Latched here rather than inside the thread, so the roll's next sweep can't land a fresh order before the saved ones are back
		self._restoring[player] = true

		task.spawn(function()
			self:ResumeCustomOrdersForPlayer(player)
		end)
	end)

	-- Sweeps players assigned a base before this manager started, or their saved order is never read back
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("BaseId") then
			self._restoring[player] = true

			task.spawn(function()
				self:ResumeCustomOrdersForPlayer(player)
			end)
		end
	end

	self.CustomOrderResponseEvent:OnServerEvent(function(player: Player, npc: Model, accepted: boolean)
		self:AnswerOffer(player, npc, accepted)
	end)

	self.CustomOrderDeliverEvent:OnServerEvent(function(player: Player, npc: Model)
		self:DeliverOrder(player, npc)
	end)

	-- The last save runs inside PlayerDataManager's PlayerRemoving, which is connected on Init against
	-- this one's on Start -- so the record below is read before the teardown further down clears it
	PlayerDataManager:RegisterPreCleanupCallback(function(player: Player, data)
		self:SaveActiveOrdersOnLastSave(player, data)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)
end

return CustomOrderNpcManager
