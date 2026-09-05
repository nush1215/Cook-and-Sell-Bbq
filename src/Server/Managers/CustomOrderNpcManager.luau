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
local StickModel = require(Shared.StickModel)
local RandomUtil = require(Shared.RandomUtil)
local Sticks = require(Shared.Config.Sticks)
local SellNpc = require(Shared.Config.SellNpc)
local CookStates = require(Shared.Config.CookStates)
local Ingredients = require(Shared.Config.Ingredients)
local CustomOrderNpc = require(Shared.Config.CustomOrderNpc)

-- How often the wait is checked. Not per frame: this runs for minutes, and a tenth of a second is
-- imperceptible on both the hand-over reaction and the run-out warning
local DELIVERY_POLL_INTERVAL = 0.1

-- The unlock whose level MIN_ROLLING_STANDS is counted in. It defaults to 1, so a buy first lands on 2
local ROLLING_STANDS_UNLOCK = "RollingStands"

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
local BaseManager

-- Sends the customer who asks for a named recipe against a clock. Its rig, walk and fade are the sell stand's; what is its own is the order, the timer and the hand-over.
local CustomOrderNpcManager = {
	CustomOrderArriveEvent = Network.Event("CustomOrderArrive"),
	CustomOrderInspectEvent = Network.Event("CustomOrderInspect"),
	CustomOrderShowEvent = Network.Event("CustomOrderShow"),
	CustomOrderResponseEvent = Network.Event("CustomOrderResponse"),
	CustomOrderAcceptedEvent = Network.Event("CustomOrderAccepted"),
	CustomOrderDeliverEvent = Network.Event("CustomOrderDeliver"),
	CustomOrderEndEvent = Network.Event("CustomOrderEnd"),
	CustomOrderSayEvent = Network.Event("CustomOrderSay"),

	-- (player, order, payout, variation, firstVisit, funnelId) once an order is put to the player
	OnCustomOrderOffered = Signal.new(),
	-- (player, order, funnelId) once they take it on
	OnCustomOrderAccepted = Signal.new(),
	-- (player, entry, funnelId) once an order resolves, however it went. The same record StatsManager banks.
	OnCustomOrderResolved = Signal.new(),

	_npcs = {}, -- [player] = { record, ... } spawned instances, for cleanup
	_orders = {}, -- [player] = the live order, so the rolling stand can bias toward what it wants
	_delivering = {}, -- [player] = true across the read -> write window, so a spammed prompt can't pay twice
	_queued = {}, -- [player] = true while a forced Inspect visit waits for their stand to be stocked
	-- [player] = true once their guaranteed first order is sent; the saved key alone yields
	_grantedFirstOrder = {},
	_tierWeights = {}, -- CustomOrderNpc.TIER_WEIGHTS flattened for the weighted roll, built once on start
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

-- What a perfect exact fill of `ids` is worth on `stick`, which the quote and its badge are both figured from.
local function getReferenceValue(stick, ids: { string }): number
	return StickModel.GetSellValue({
		StickId = stick.Id,
		Ingredients = ids,
		Cooked = true,
		CookState = "Perfect",
	})
end

-- Builds an order: what to ask for, what a perfect exact fill earns, and how long they get.
function CustomOrderNpcManager:_buildOrder(data)
	local stick = getBestOwnedStick(data)
	local slots =
		math.min(self._rng:NextInteger(CustomOrderNpc.SLOT_COUNT_MIN, CustomOrderNpc.SLOT_COUNT_MAX), stick.Capacity)

	-- What they can reach: owned outright, or cheap enough that rolling for it is a trip rather than a wall
	local affordable = data.Currency * CustomOrderNpc.AFFORD_FACTOR
	local byTier = {}
	for _, ingredient in Ingredients.GetAllIngredients() do
		local owned = (data.Ingredients[ingredient.Id] or 0) > 0
		if not owned and ingredient.Price > affordable then
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

	for _ = 1, slots do
		local wanted = RandomUtil.GetResultFromWeight(self._tierWeights, self._rng)

		-- Walked down from the rolled tier, so a band with nothing reachable in it falls back rather than failing
		local candidates = nil
		for index = Ingredients.GetTierFromId(wanted).Index, 1, -1 do
			candidates = byTier[Ingredients.Tiers[index].Id]
			if candidates then
				break
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
	local multiplier = math.min(
		CustomOrderNpc.BASE_MULTIPLIER + CustomOrderNpc.TIER_STEP * (tierIndexTotal / slots - 1),
		CustomOrderNpc.MULTIPLIER_CAP
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
	}
end

-- The ordered ingredients the player still hasn't got, so the rolling stand knows what to steer toward.
function CustomOrderNpcManager:GetMissingOrderIngredients(player: Player, data): { string }
	local order = self._orders[player]
	if not order then
		return {}
	end

	local missing = {}
	for id, needed in order.Counts do
		if (data.Ingredients[id] or 0) < needed then
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

	NpcRig.Fade(record.npc, false, SellNpc.FADE_OUT_DURATION)

	-- The player may have left during the fade, in which case _cleanupPlayer already destroyed the rig.
	if record.npc.Parent == nil then
		return
	end

	NpcRig.Release(record.npc)

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

	StatsManager:RecordCustomOrderResolved(player, entry)
	self.OnCustomOrderResolved:Fire(player, entry, record.funnelId)
end

-- What a hand-over is worth: the quote graded by how much of the recipe landed and how it cooked.
function CustomOrderNpcManager:_gradeDelivery(order, delivered): number
	local matched, extras = measureDelivery(order, delivered)

	-- Padding a stick out with whatever was to hand must not pay, so extras come off the share
	local accuracy = math.max(matched / #order.Ingredients - extras * CustomOrderNpc.EXTRA_INGREDIENT_PENALTY, 0)

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
	SoundManager:PlaySound({ Type = "Player", Player = player }, "Reject", npc:GetPivot(), nil, { Limit = true })
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

-- Says the two beats a hand-over earns: what they made, and then how it cooked.
function CustomOrderNpcManager:_sayDeliveryReaction(npc: Model, order, delivered)
	local matched, extras = measureDelivery(order, delivered)

	-- An exact fill gets one clean reaction; anything else is remarked on before the cook is
	if matched < #order.Ingredients or extras > 0 then
		local category = if matched == 0 then "CustomNPCDeliveredWrong" else "CustomNPCDeliveredPartial"
		self.CustomOrderSayEvent:FireAllClients(npc, category)
		task.wait(1)
	end

	-- The variant is only knowable now: it arrived holding nothing, so the client has none stored
	self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCDelivered", StickModel.GetDialogueVariant(delivered))
end

-- Waits out the deadline, flagging the customer as it runs down. Returns the delivered skewer, or nil on an expiry.
function CustomOrderNpcManager:_awaitDelivery(player: Player, npc: Model, record)
	local nextHurry = record.deadline - CustomOrderNpc.HURRY_THRESHOLD

	while record.awaitingDelivery and npc.Parent ~= nil do
		local now = workspace:GetServerTimeNow()
		if now >= record.deadline then
			break
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

-- The toast that calls the player over. Timed differently per variation, so it's its own method.
function CustomOrderNpcManager:_notifyArrived(player: Player, firstVisit: boolean?)
	-- Their first says why it's worth taking, since the recipe card shows what it wants but not that it pays more
	NotificationManager:NotifyNormal(player, {
		Text = if firstVisit
			then "Someone's here with a custom order! It pays extra!"
			else "Someone's here with a custom order!",
		Duration = if firstVisit then 4 else 3,
		Sound = "CustomerArrived",
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
	StatsManager:RecordCustomOrderOffered(player)
	self.OnCustomOrderOffered:Fire(player, order, payout, record.variation, record.firstVisit, record.funnelId)
	self.CustomOrderShowEvent:FireClient(player, npc, order.Ingredients, payout, bonus)

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

-- Walks the customer off the base and pools it, on whichever line the visit ended.
function CustomOrderNpcManager:_leave(player: Player, npc: Model, record, humanoid: Humanoid, spawnPart: BasePart)
	task.wait(SellNpc.LEAVE_DELAY)
	if npc.Parent == nil then
		return
	end

	NpcRig.StopAnimation(record)
	NpcRig.WalkTo(humanoid, spawnPart.Position)
	self:_despawnNpc(player, record)
end

-- Runs one whole visit: the ask, the wait, and whatever gets handed over.
function CustomOrderNpcManager:_spawnCustomOrderCustomer(
	player: Player,
	variation: string?,
	firstVisit: boolean?
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
	local order = self:_buildOrder(data)
	if not order then
		return "no order could be built from the roster"
	end

	local tracked = self._npcs[player]
	if not tracked then
		tracked = {}
		self._npcs[player] = tracked
	end

	-- The sell stand's slot allocator, so this one lines up beside its customers rather than inside them
	local slot, standPosition = NpcRig.ClaimStandPosition(player, spawnPart, standPart)

	local npc = NpcRig.Acquire()
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	-- Tracked before the lookup yields, so a mid-lookup cleanup destroys the rig rather than orphaning it
	-- Carried on the record rather than threaded on, since both toasts read it from different beats
	local record = {
		npc = npc,
		slot = slot,
		order = order,
		firstVisit = firstVisit,
		-- One id for the whole visit, so the analytics funnel can follow this order across its three beats
		funnelId = HttpService:GenerateGUID(false),
		thread = coroutine.running(),
	}
	table.insert(tracked, record)

	local description = NpcRig.GetFriendDescription(player, self._rng)
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
	npc.Parent = workspace

	-- Server-driven movement, so hand the root to the server rather than a nearby client.
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if rootPart and not rootPart.Anchored then
		rootPart:SetNetworkOwner(nil)
	end

	-- A forced variation is the command bar's, which has already waited for a stand to look over
	local inspecting = if variation
		then variation == CustomOrderNpc.VARIATIONS.Inspect
		-- Nothing on the stand means nothing to look over, so that variation has no beat to play
		else SkewerStandManager:GetPlacedSkewerCount(player) > 0 and RandomUtil.RollChance(
			CustomOrderNpc.INSPECT_CHANCE,
			self._rng
		)

	-- Kept for the offer beat, which is where the two openings are worth telling apart
	record.variation = if inspecting then CustomOrderNpc.VARIATIONS.Inspect else CustomOrderNpc.VARIATIONS.Direct

	-- A Direct one announces itself on arrival. An Inspect one is still browsing, so its toast waits
	-- for the verdict -- called over any earlier, the player arrives to watch their stand turned down
	if not inspecting then
		self:_notifyArrived(player, firstVisit)
	end

	self.CustomOrderArriveEvent:FireAllClients(npc, inspecting)
	NpcRig.WalkTo(humanoid, standPosition)

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

		self:_notifyArrived(player, firstVisit)
		task.wait(CustomOrderNpc.REQUEST_DELAY)

		if npc.Parent == nil then
			return
		end
	end

	if not self:_offerOrder(player, npc, record) then
		if npc.Parent == nil then
			return
		end

		self.CustomOrderEndEvent:FireAllClients(npc)

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

	-- Dropped for the wait, so the rig falls back to its own idle rather than inspecting nothing
	NpcRig.StopAnimation(record)

	-- Live from the moment the deal is struck, so the rolling stand can start steering toward it
	self._orders[player] = order

	record.deadline = workspace:GetServerTimeNow() + order.Seconds
	record.awaitingDelivery = true

	-- It has stepped aside, so holding a lane would block the sell customers behind it
	NpcRig.ReleaseSlot(player, record.slot)
	record.slot = nil

	-- Off to one side rather than straight back, so it waits out of the way but stays in sight
	local backDir = (spawnPart.Position - standPosition).Unit
	local sideDir = Vector3.new(-backDir.Z, 0, backDir.X) -- perpendicular, on the ground plane
	local side = self._rng:NextNumber(CustomOrderNpc.WAIT_SIDE_DISTANCE_MIN, CustomOrderNpc.WAIT_SIDE_DISTANCE_MAX)
		* (if self._rng:NextNumber() < 0.5 then -1 else 1)

	-- Owner only: the countdown and the hand-over prompt are theirs, as the offer frame was
	self.CustomOrderAcceptedEvent:FireClient(player, npc, record.deadline)
	NpcRig.WalkTo(humanoid, standPosition + backDir * CustomOrderNpc.WAIT_BACK_DISTANCE + sideDir * side)

	if npc.Parent == nil then
		return
	end

	-- Turned back toward the stand, so it waits watching the player rather than facing off the base
	npc:PivotTo(CFrame.lookAt(npc:GetPivot().Position, standPosition))
	self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCWaiting")

	local delivered = self:_awaitDelivery(player, npc, record)
	self._orders[player] = nil

	if npc.Parent == nil then
		return
	end

	self.CustomOrderEndEvent:FireAllClients(npc)

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

	local paid = self:_gradeDelivery(order, delivered)
	local banked = CurrencyManager:GetBoostedAmount(player, paid)

	-- The plain figure -- applying boosts is IncrementCurrency's job, and a boosted one would double it
	CurrencyManager:IncrementCurrency(player, paid, "CustomOrder")

	self:_recordOutcome(player, record, "Delivered", delivered, banked)
	StatsManager:RecordSaleCompleted(player, { delivered })

	-- Put in its hand now rather than on arrival, since what it walks off with is whatever they made
	record.tool, record.skewerModel = NpcRig.GiveSkewer(npc, delivered)

	-- The payout lets each projectile pop a "+X" that adds up to the counter's jump
	EffectManager:RunEffect("All", "CollectCash", { npc, banked, player })

	-- {value} is NotificationManager's placeholder for Count, so it must survive uninterpolated.
	NotificationManager:NotifyNormal(player, {
		Text = "Custom order filled for {value}!",
		Duration = 3,
		Count = {
			Value = banked,
			Format = "Price",
			Color = Colors.Currency,
		},
	})

	self:_sayDeliveryReaction(npc, order, delivered)

	NpcRig.PlayAnimation(record, "Eat", self._rng)
	self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCEating")
	task.wait(SellNpc.EAT_DURATION)

	if npc.Parent == nil then
		return
	end

	self.CustomOrderSayEvent:FireAllClients(npc, "CustomNPCLeaving")
	NpcRig.StopAnimation(record)
	NpcRig.WalkTo(humanoid, spawnPart.Position)
	self:_despawnNpc(player, record)
end

-- Runs one visit with its failure contained, releasing the rig and slot a throw would strand.
function CustomOrderNpcManager:_runGuardedVisit(player: Player, variation: string?, firstVisit: boolean?)
	local success, result = xpcall(function()
		return self:_spawnCustomOrderCustomer(player, variation, firstVisit)
	end, debug.traceback)
	if success then
		-- Said out loud, or a visit that bails before it spawns anything looks like nothing happened
		if result then
			warn(`[CustomOrderNpcManager] No custom order sent to {player.Name}: {result}`)
		end

		return
	end

	warn(`[CustomOrderNpcManager] Custom order visit for {player.Name} failed, releasing its customer:\n{result}`)

	-- Dropped first, or the rolling stand would keep steering toward an order nobody is waiting on
	self._orders[player] = nil

	-- Snapshotted first: _despawnNpc removes from the tracked list as it goes, and yields through the fade
	local thread = coroutine.running()
	local orphaned = {}
	for _, record in self._npcs[player] or {} do
		if record.thread == thread then
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

-- One pass of the custom-order roll, cheapest checks first so the data reads are rare.
function CustomOrderNpcManager:_rollCustomOrderVisits()
	for _, player in Players:GetPlayers() do
		-- Read off the tracked customers rather than a flag, so an errored visit can't leave it stuck set
		if not validatePlayer(player) or self:HasCustomOrder(player) then
			continue
		end

		-- Not during the tutorial -- it has its own beats to teach, and this would talk over them
		if SellNpcManager:AreCustomersGuaranteed(player) then
			continue
		end

		if not RandomUtil.RollChance(CustomOrderNpc.SPAWN_CHANCE, self._rng) then
			continue
		end

		local hasData, data = PlayerDataManager:GetPlayerData(player):await()
		if not hasData or not self:IsUnlocked(data) then
			continue
		end

		-- In their data on the synced clock, so rejoining can't hand out a fresh order
		if (workspace:GetServerTimeNow() - data.LastCustomOrderVisit) < CustomOrderNpc.COOLDOWN then
			continue
		end

		-- Stamped before the visit, so a long order can't let another be rolled the moment this one leaves
		PlayerDataManager:SetPlayerDataKey(player, "LastCustomOrderVisit", workspace:GetServerTimeNow())

		task.spawn(function()
			self:_runGuardedVisit(player)
		end)
	end
end

-- Sends one now off the command bar, keeping only the checks that would leave it meaningless. A named `variation` is forced; without one it rolls as an ordinary visit would.
function CustomOrderNpcManager:ForceCustomOrderVisit(player: Player, variation: string?): (boolean, string?)
	if not validatePlayer(player) then
		return false, `{player.Name} has no base to send a customer to.`
	end

	if self:HasCustomOrder(player) then
		return false, `{player.Name} already has a custom order customer.`
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

		self:_runGuardedVisit(player, variation)
	end)

	if queued then
		return true, `Queued an Inspect order for {player.Name} until their stand has a BBQ on it.`
	end

	return true
end

-- Whether one is already with them, or still waiting to be sent. Either way a second would crowd it.
function CustomOrderNpcManager:HasCustomOrder(player: Player): boolean
	return self._queued[player] == true or #(self._npcs[player] or {}) > 0
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

	self._orders[player] = nil
	self._delivering[player] = nil
	self._queued[player] = nil
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
	BaseManager = require(script.Parent.BaseManager)
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
		task.spawn(function()
			-- A customer's ordinary wait, so one doesn't materialise the instant they load in -- and so
			-- the base has finished building the spawn and stand parts the visit reads off it
			task.wait(SellNpc.SPAWN_DELAY_MAX)
			self:TrySendFirstCustomOrder(player)
		end)
	end)

	self.CustomOrderResponseEvent:OnServerEvent(function(player: Player, npc: Model, accepted: boolean)
		self:AnswerOffer(player, npc, accepted)
	end)

	self.CustomOrderDeliverEvent:OnServerEvent(function(player: Player, npc: Model)
		self:DeliverOrder(player, npc)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)
end

return CustomOrderNpcManager
