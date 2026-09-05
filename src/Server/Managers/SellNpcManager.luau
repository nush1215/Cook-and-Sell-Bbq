-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
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
local SellNpc = require(Shared.Config.SellNpc)
local RichNpc = require(Shared.Config.RichNpc)
local CheckingNpc = require(Shared.Config.CheckingNpc)
local CookStates = require(Shared.Config.CookStates)
local EarlyBoost = require(Shared.Config.EarlyBoost)

-- Assets
local RichNpcFolder = ServerStorage.Assets.RichNPC
local RichUiTemplate = ReplicatedStorage.Assets.UI.RichUI
local RichParticlesTemplate = ReplicatedStorage.Assets.Particles.RichParticles

local RICH_LABEL = `<font color="#ffd400">RICH</font>`

-- A pool rather than one string, since this fires on every offer until the refusals decay
local REFUSED_ARRIVAL_TEXTS = {
	"A customer is here, but you've been saying no so they're offering less",
	"A customer is here - turning offers down has your prices down",
	"A customer heard you turn people away, so they're offering less",
	"A customer is here, lowballing you for all those refusals",
	"A customer is here - your refused offers are still costing you",
}

local RICH_REFUSED_ARRIVAL_TEXTS = {
	`A {RICH_LABEL} customer is here, but your refusals have it offering less`,
	`A {RICH_LABEL} customer heard you turn people down - it's offering less`,
	`A {RICH_LABEL} customer is here, and it's lowballing you for it`,
}

-- Said once the last refusal decays, so the penalty has an end and not just a beginning
local REFUSALS_CLEARED_TEXTS = {
	"Customers have forgotten your refusals - offers are back to normal",
	"Your refusals are forgotten, offers are back up",
	"Word's died down - customers are paying full price again",
}

--
local PlayerDataManager
local SkewerStandManager
local CollisionManager
local CurrencyManager
local NotificationManager
local EffectManager
local BaseManager
local StatsManager
local SoundManager

-- Sends customer NPCs to a base's sell stand: one visit thread per placed skewer, retrying until it sells
local SellNpcManager = {
	NpcDecideEvent = Network.Event("NpcDecide"),
	NpcRichArriveEvent = Network.Event("NpcRichArrive"),
	NpcCheckingArriveEvent = Network.Event("NpcCheckingArrive"),
	NpcOfferEvent = Network.Event("NpcOffer"),
	NpcOfferEndEvent = Network.Event("NpcOfferEnd"),
	NpcOfferResponseEvent = Network.Event("NpcOfferResponse"),
	NpcSayEvent = Network.Event("NpcSay"),

	-- (player, offer, skewerRecords, customerType) once a customer's offer is taken and paid out.
	OnSaleCompleted = Signal.new(),
	-- (player, offer, skewerRecords, customerType, reason) on a leave; reason is "Declined" or "TimedOut"
	OnSaleDeclined = Signal.new(),
	-- (player, converted, waited) when a checking customer's wait ends, either way
	OnCheckingVisitEnded = Signal.new(),

	_npcs = {}, -- [player] = { { npc = Model, tool = Tool }, ... } spawned instances, for cleanup
	_rng = ServerRandom.MakeRNG("SellNpc"),

	_guaranteed = {}, -- [player] = true while their customers skip the wait and always come in interested
	_noticedRefusals = {}, -- [player] = refusals they were last told about, so the all-clear fires once
	-- [player] = true once the free first counter is given, so concurrent visits don't all grant it
	_grantedFirstCounter = {},
	-- [player] = true once their guaranteed first rich customer is sent; the saved key alone yields
	_grantedFirstRich = {},
}

-- True while the player is still in-game and has a base to send customers to.
local function validatePlayer(player: Player): boolean
	return player:IsDescendantOf(Players) and player:GetAttribute("BaseId") ~= nil
end

-- Clones a random rich rig with its badge and particles. Not pooled -- each is its own character.
function SellNpcManager:_acquireRichNpc(): Model
	local npc = RandomUtil.GetRandomFromArray(RichNpcFolder:GetChildren(), nil, self._rng):Clone()
	CollisionManager:SetModelGroup(npc, CollisionManager.NPC)

	RichUiTemplate:Clone().Parent = npc.Head
	RichParticlesTemplate:Clone().Parent = npc.Torso

	-- Parked with the pooled rigs, so a leave tears its billboards down the same way
	npc.Parent = NpcRig.PoolFolder
	return npc
end

-- Runs one whole visit. Returns true once settled, false if the customer walked off unsold.
function SellNpcManager:_spawnCustomer(player: Player): boolean
	local spawnPart, standPart = NpcRig.GetBaseParts(player)
	if not spawnPart or not standPart then
		return true
	end

	local tracked = self._npcs[player]
	if not tracked then
		tracked = {}
		self._npcs[player] = tracked
	end

	-- An explicit slot rather than a count of tracked customers, since visits run concurrently.
	local slot, standPosition = NpcRig.ClaimStandPosition(player, spawnPart, standPart)

	local npc = NpcRig.Acquire()
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	-- Tracked before the lookup yields, so a mid-lookup cleanup destroys the rig rather than orphaning it
	local record = { npc = npc, tool = nil, slot = slot, thread = coroutine.running() }
	table.insert(tracked, record)

	-- Both calls yield, and a leave during either has already destroyed the parked rig
	local description = NpcRig.GetFriendDescription(player, self._rng)
	if npc.Parent == nil then
		return true
	end
	if description then
		humanoid:ApplyDescriptionReset(description)
		if npc.Parent == nil then
			return true
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

	NpcRig.WalkTo(humanoid, standPosition)

	-- The player may have left (and their NPCs been cleaned up) during the walk.
	if npc.Parent == nil then
		return true
	end

	return self:_serveStandSkewer(player, npc, record, humanoid, spawnPart, standPart, standPosition)
end

-- Takes a skewer off the stand and runs the decide beat, then the haggle. Returns true once settled.
function SellNpcManager:_serveStandSkewer(
	player: Player,
	npc: Model,
	record,
	humanoid: Humanoid,
	spawnPart: BasePart,
	standPart: BasePart,
	standPosition: Vector3
): boolean
	-- An empty stand means nothing to sell, so the customer just leaves (no retry).
	local taken = SkewerStandManager:TakeSkewer(player)
	if not taken then
		NpcRig.WalkTo(humanoid, spawnPart.Position)
		self:_despawnNpc(player, record)
		return true
	end
	-- An array of one, so the offer maths, return paths and cleanup work the same for a rich haul
	record.skewerRecords = { taken }
	record.tool, record.skewerModel = NpcRig.GiveSkewer(npc, taken)

	-- Loops through the decide pause and any haggle, until the eat animation replaces it.
	NpcRig.PlayAnimation(record, "Inspect", self._rng)

	-- New players get turned down less often; scaling the walk-off share keeps 1 the ceiling
	local declineScale = EarlyBoost.GetDeclineScale(CurrencyManager:GetEarlyBoostEarnings(player))
	local interestedChance = 1 - (1 - SellNpc.INTERESTED_CHANCE) * declineScale

	-- Authoritative; clients pace their own flip off the timestamp. Guaranteed players skip the roll
	local interested = self._guaranteed[player] == true or self._rng:NextNumber() < interestedChance
	local duration = self._rng:NextNumber(SellNpc.DECIDE_DURATION_MIN, SellNpc.DECIDE_DURATION_MAX)
	record.interested = interested

	-- Sent once -- the client holds the variant per-NPC and later beats fire NpcSay with a bare category
	self.NpcDecideEvent:FireAllClients(
		npc,
		interested,
		workspace:GetServerTimeNow() + duration,
		StickModel.GetDialogueVariant(taken)
	)
	task.wait(duration)

	-- The player may have left during the decide pause.
	if npc.Parent == nil then
		return true
	end

	if interested then
		return self:_negotiateSale(player, npc, record, humanoid, spawnPart, standPart, standPosition)
	end

	-- Uninterested: hold the verdict a beat, put the skewer back, walk out. The caller sends another.
	task.wait(SellNpc.LEAVE_DELAY)
	if npc.Parent == nil then
		return true
	end

	SkewerStandManager:ReturnSkewers(player, record.skewerRecords)
	record.skewerRecords = nil

	if record.skewerModel then
		record.skewerModel:Destroy()
		record.skewerModel = nil
	end
	if record.tool then
		record.tool:Destroy()
		record.tool = nil
	end

	NpcRig.StopAnimation(record)
	NpcRig.WalkTo(humanoid, spawnPart.Position)
	self:_despawnNpc(player, record)
	return false
end

-- Removes one spawned customer: clears its skewer and tool, fades the rig out, pools or destroys it.
function SellNpcManager:_despawnNpc(player: Player, record)
	-- Catch-all for leave paths that despawn without walking, so no looped track rides the rig into the pool.
	NpcRig.StopAnimation(record)

	if record.skewerModel then
		record.skewerModel:Destroy()
	end
	if record.tool then
		record.tool:Destroy()
	end

	-- Freed up front so a concurrent arrival can take the spot while this one fades
	NpcRig.ReleaseSlot(player, record.slot)

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

-- Fades the skewer's ingredients out in order over `duration`, so the food looks eaten off the stick.
function SellNpcManager:_eatSkewerIngredients(skewer: Model, duration: number)
	local ingredients = {}
	for _, child in skewer:GetChildren() do
		if child:GetAttribute("SkewerIndex") then
			table.insert(ingredients, child)
		end
	end
	table.sort(ingredients, function(a, b)
		return a:GetAttribute("SkewerIndex") < b:GetAttribute("SkewerIndex")
	end)

	if #ingredients == 0 then
		task.wait(duration)
		return
	end

	local slice = duration / #ingredients
	local fadeInfo = TweenInfo.new(slice)
	for _, ingredient in ingredients do
		for _, descendant in ingredient:GetDescendants() do
			if descendant:IsA("BasePart") or descendant:IsA("Decal") then
				TweenService:Create(descendant, fadeInfo, { Transparency = 1 }):Play()
			elseif descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
			end
		end
		task.wait(slice)
	end
end

-- Records the owner's answer; finding the NPC among their own customers is the authority check.
function SellNpcManager:AnswerOffer(player: Player, npc: Model, accepted: boolean)
	local tracked = self._npcs[player]
	if not tracked then
		return
	end

	for _, record in tracked do
		if record.npc == npc and record.offerPending then
			record.offerPending = false
			record.offerResponse = accepted == true
			return
		end
	end
end

-- Standing refusals: the saved count less one per REFUSAL_DECAY, clamped. Stops declining being a free reroll.
function SellNpcManager:GetStandingSaleRefusals(player: Player): number
	local hasRefusals, refusals = PlayerDataManager:GetPlayerDataKey(player, "SaleRefusals"):await()
	if not hasRefusals or refusals.Count <= 0 then
		return 0
	end

	local forgiven = math.floor((workspace:GetServerTimeNow() - refusals.At) / SellNpc.REFUSAL_DECAY)
	return math.clamp(refusals.Count - forgiven, 0, SellNpc.REFUSAL_PENALTY_MAX)
end

-- What those refusals cost: the standing count less REFUSAL_GRACE, so declining once is still free.
function SellNpcManager:GetChargedSaleRefusals(player: Player): number
	return math.max(self:GetStandingSaleRefusals(player) - SellNpc.REFUSAL_GRACE, 0)
end

-- Moves the count by `delta` and re-stamps; writes the decayed count so one timestamp banks the decay.
function SellNpcManager:_adjustSaleRefusals(player: Player, delta: number)
	local standing = self:GetStandingSaleRefusals(player)

	PlayerDataManager:SetPlayerDataKey(player, "SaleRefusals", {
		Count = math.clamp(standing + delta, 0, SellNpc.REFUSAL_PENALTY_MAX),
		At = workspace:GetServerTimeNow(),
	})
end

-- Holds one more refused offer against the player.
function SellNpcManager:RecordSaleRefusal(player: Player)
	self:_adjustSaleRefusals(player, 1)
end

-- Sheds one refusal after a sale, which disproves the fishing a refusal only suspected.
function SellNpcManager:ForgiveSaleRefusal(player: Player)
	if self:GetStandingSaleRefusals(player) <= 0 then
		return
	end

	self:_adjustSaleRefusals(player, -1)
end

-- Guaranteed mode for onboarding: customers arrive on a fixed delay and never roll uninterested.
function SellNpcManager:SetCustomersGuaranteed(player: Player, guaranteed: boolean?)
	self._guaranteed[player] = guaranteed or nil
end

-- Whether the player is in guaranteed mode, so other customers can stay out of the tutorial's way.
function SellNpcManager:AreCustomersGuaranteed(player: Player): boolean
	return self._guaranteed[player] == true
end

-- Haggles and, on a deal, sells. Returns true once settled, false if the customer put the skewers back.
function SellNpcManager:_negotiateSale(
	player: Player,
	npc: Model,
	record,
	humanoid: Humanoid,
	spawnPart: BasePart,
	standPart: BasePart,
	standPosition: Vector3
): boolean
	-- Settled once here, so the beats below read as one exchange rather than branching at every step.
	local isRich = record.isRich
	local prefix = if isRich then "RichNPC" else "NPC"
	local config = if isRich then RichNpc else SellNpc

	-- A checking customer haggles as a normal one does, so it only differs to whoever is watching the sale
	local customerType = if isRich then "Rich" elseif record.isChecking then "Checking" else "Normal"

	-- Offer, counter and cap scale with value; the cook state then decides how hard the customer haggles
	local count = #record.skewerRecords
	local value, offer = 0, 0
	local counterChance = 0
	local counterCap = 0

	-- The charged count, not the standing one -- the first refusal moves nothing and goes unmentioned
	local refusals = self:GetChargedSaleRefusals(player)
	local penalty = refusals * SellNpc.REFUSAL_OFFER_PENALTY

	-- Whether a customer has countered this player before -- the first is given, not rolled for.
	local hasData, seenHaggle = PlayerDataManager:GetPlayerDataKey(player, "SeenHaggle"):await()

	for _, skewerRecord in record.skewerRecords do
		local cookState = CookStates.GetStateFromId(StickModel.GetCookStateId(skewerRecord))
		local skewerValue = StickModel.GetSellValue(skewerRecord)

		-- Floored at plain worth so a refusal never sells at a loss; the spread stops a state quoting one number
		local offerMin = math.max(cookState.OfferMin - penalty, 1)
		local offerMax = math.max(cookState.OfferMax - penalty, offerMin + SellNpc.MIN_OFFER_SPREAD)

		value += skewerValue
		offer += skewerValue * self._rng:NextNumber(offerMin, offerMax)
		-- A normal customer carries exactly one skewer, so these land on that skewer's own numbers.
		counterChance = cookState.CounterChance
		counterCap = cookState.CounterCap
	end

	-- A mixed haul has no single cook state, so the rich one brings its own premium, chance and cap
	if isRich then
		offer *= RichNpc.BULK_MULTIPLIER
		counterChance = RichNpc.COUNTER_CHANCE
		counterCap = RichNpc.OFFER_CAP_FACTOR
	end
	offer = math.round(offer)

	local accepted = false
	local timedOut = false
	local counterRounds = 0

	-- A toast brings a player back before OFFER_TIMEOUT; one carrying refusals is told why it dropped
	local arrivalText
	if refusals > 0 then
		self._noticedRefusals[player] = refusals
		self.NpcSayEvent:FireAllClients(npc, `{prefix}ArrivedRefused`)

		arrivalText = RandomUtil.GetRandomFromArray(
			if isRich then RICH_REFUSED_ARRIVAL_TEXTS else REFUSED_ARRIVAL_TEXTS
		)
	else
		if self._noticedRefusals[player] then
			self._noticedRefusals[player] = nil

			NotificationManager:NotifyNormal(player, {
				Text = RandomUtil.GetRandomFromArray(REFUSALS_CLEARED_TEXTS),
				Duration = 3,
				Sound = "Notify",
				Effect = "Success",
			})
		end

		arrivalText = if isRich
			then `A {RICH_LABEL} customer wants your whole stand!`
			else "A customer is offering for your BBQ!"
	end

	NotificationManager:NotifyNormal(player, {
		Text = arrivalText,
		Duration = 3,
		Sound = "CustomerArrived",
	})

	while true do
		record.offerResponse = nil
		record.offerPending = true

		-- The boosted figure, since that's what lands in their balance. Re-derived, so a counter moves it
		local payout = CurrencyManager:GetBoostedAmount(player, offer)
		local bonus = math.round((payout / value - 1) * 100)
		self.NpcOfferEvent:FireClient(player, npc, payout, count, bonus)

		-- Never waits forever -- an ignored offer would stall every later customer
		local deadline = os.clock() + config.OFFER_TIMEOUT
		local nudgeAt = os.clock() + SellNpc.OFFER_NUDGE_INTERVAL
		while record.offerResponse == nil and os.clock() < deadline and npc.Parent ~= nil do
			if os.clock() >= nudgeAt then
				-- Re-derived rather than advanced, so a server hitch can't queue two nudges back to back.
				nudgeAt = os.clock() + SellNpc.OFFER_NUDGE_INTERVAL

				NotificationManager:NotifyNormal(player, {
					Text = if isRich
						then `The {RICH_LABEL} customer is still waiting!`
						else "A customer is still waiting on you!",
					Duration = 3,
					Sound = "CustomerPinged",
					Effect = "Error",
				})

				-- The toast says someone's waiting; this says which one, for a stand with a queue on it.
				EffectManager:RunEffect({ Type = "Player", Player = player }, "HighlightPulse", {
					npc,
					SellNpc.NUDGE_PULSE_COLOR,
					SellNpc.NUDGE_PULSE_DURATION,
					SellNpc.NUDGE_PULSE_START_TRANSPARENCY,
					SellNpc.NUDGE_PULSE_COUNT,
				})
			end

			task.wait()
		end
		record.offerPending = false

		if npc.Parent == nil then
			return true
		end

		if record.offerResponse == true then
			accepted = true
			break
		end

		-- The window shut on its own. Split from a decline so the player can be told.
		if record.offerResponse == nil then
			timedOut = true
			break
		end

		-- A hard cap on top of the decaying chance: unbounded, a patient player rides a haggle to the ceiling.
		if counterRounds >= config.MAX_COUNTER_ROUNDS then
			break
		end
		-- First counter ever is given, not rolled -- onboarding never teaches declining. hasData gates a failed load
		local firstCounter = hasData and not seenHaggle and not self._grantedFirstCounter[player]
		if not firstCounter and not RandomUtil.RollChance(counterChance, self._rng) then
			break
		end
		counterRounds += 1

		-- Latched before the write, which yields, or a sibling visit would find the counter going spare
		if firstCounter then
			seenHaggle = true
			self._grantedFirstCounter[player] = true
			PlayerDataManager:SetPlayerDataKey(player, "SeenHaggle", true)

			-- Said in terms of what they did -- naming it "haggling" only explains it to someone who knows it
			NotificationManager:NotifyNormal(player, {
				Text = "You said no, so they're offering more! Declining can get you a better price",
				Duration = 5,
				Sound = "Notify",
				Effect = "Success",
			})
		end

		-- A share of the remaining headroom, so a haggle decelerates into the cap instead of being clamped off it
		local headroom = value * counterCap - offer
		offer = math.round(
			offer + headroom * self._rng:NextNumber(config.COUNTER_INCREASE_MIN, config.COUNTER_INCREASE_MAX)
		)
		counterChance *= SellNpc.COUNTER_CHANCE_FALLOFF

		self.NpcSayEvent:FireAllClients(npc, `{prefix}CounterOffer`)

		-- Later counters pitch up off a shared sound, so a customer pushed a third time sounds like it
		SoundManager:PlaySound("All", if counterRounds == 1 then "Haggle1" else "Haggle2", npc:GetPivot(), {
			PlaybackSpeed = 1 + math.max(counterRounds - 2, 0) * SellNpc.HAGGLE_PITCH_STEP,
		})
	end

	self.NpcOfferEndEvent:FireClient(player, npc)

	if not accepted then
		-- No deal: the skewers go back on the stand and the customer leaves, so another comes for them.
		self.NpcSayEvent:FireAllClients(npc, `{prefix}PlayerDeclined`)
		StatsManager:RecordSaleDeclined(player)
		self.OnSaleDeclined:Fire(
			player,
			offer,
			record.skewerRecords,
			customerType,
			if timedOut then "TimedOut" else "Declined"
		)

		-- Only a deliberate refusal counts: a lapse already cost them OFFER_TIMEOUT and wasn't a choice.
		if not timedOut then
			self:RecordSaleRefusal(player)
		end

		-- A lapse needs telling; no error effect, since they lost the sale but did nothing wrong
		if timedOut then
			NotificationManager:NotifyNormal(player, {
				Text = "The customer got tired of waiting!",
				Duration = 3,
				Sound = "Reject",
			})
		end

		task.wait(SellNpc.LEAVE_DELAY)
		if npc.Parent == nil then
			return true
		end

		SkewerStandManager:ReturnSkewers(player, record.skewerRecords)
		record.skewerRecords = nil

		if record.skewerModel then
			record.skewerModel:Destroy()
			record.skewerModel = nil
		end
		if record.tool then
			record.tool:Destroy()
			record.tool = nil
		end

		NpcRig.StopAnimation(record)
		NpcRig.WalkTo(humanoid, spawnPart.Position)
		self:_despawnNpc(player, record)
		return false
	end

	-- Read before the payout, or the early boost prices this sale off a figure this sale just moved
	local payout = CurrencyManager:GetBoostedAmount(player, offer)

	-- The plain offer -- applying boosts is IncrementCurrency's job, and a boosted figure would double it
	CurrencyManager:IncrementCurrency(player, offer, "SkewerSale")

	-- The commit point -- clearing after the eat would let a mid-eat leave return what was just paid for
	local soldRecords = record.skewerRecords
	record.skewerRecords = nil

	StatsManager:RecordSaleCompleted(player, soldRecords)
	self.OnSaleCompleted:Fire(player, offer, soldRecords, customerType)

	-- Down here because it yields, which is only safe once the record's skewers are cleared
	self:ForgiveSaleRefusal(player)

	-- The payout lets each projectile pop a "+X" that adds up to the counter's jump
	EffectManager:RunEffect("All", "CollectCash", { npc, payout, player })

	-- {value} is NotificationManager's placeholder for Count, so it must survive uninterpolated.
	NotificationManager:NotifyNormal(player, {
		Text = if count > 1 then "Sold " .. count .. " BBQs for {value}!" else "Sold a BBQ for {value}!",
		Duration = 3,
		Count = {
			Value = payout,
			Format = "Price",
			Color = Colors.Currency,
		},
	})
	self.NpcSayEvent:FireAllClients(npc, `{prefix}PlayerAccepted`)

	-- A randomized spot, so finished customers scatter rather than lining up behind the stand
	local backDir = (spawnPart.Position - standPosition).Unit
	local sideDir = Vector3.new(-backDir.Z, 0, backDir.X) -- perpendicular, on the ground plane
	local eatPosition = standPosition
		+ backDir * self._rng:NextNumber(SellNpc.EAT_BACK_DISTANCE_MIN, SellNpc.EAT_BACK_DISTANCE_MAX)
		+ sideDir * self._rng:NextNumber(-SellNpc.EAT_SPREAD, SellNpc.EAT_SPREAD)
	NpcRig.WalkTo(humanoid, eatPosition)
	if npc.Parent == nil then
		return true
	end

	-- Face a random direction while eating, so eaters don't all stare the same way.
	npc:PivotTo(CFrame.new(npc:GetPivot().Position) * CFrame.Angles(0, self._rng:NextNumber(0, math.pi * 2), 0))

	NpcRig.PlayAnimation(record, "Eat", self._rng)
	self.NpcSayEvent:FireAllClients(npc, `{prefix}Eating`)

	-- A rich customer only built the skewer it holds; the rest of its haul it just carries off
	if record.skewerModel then
		self:_eatSkewerIngredients(record.skewerModel, SellNpc.EAT_DURATION)
	else
		task.wait(SellNpc.EAT_DURATION)
	end
	if npc.Parent == nil then
		return true
	end

	if record.skewerModel then
		record.skewerModel:Destroy()
		record.skewerModel = nil
	end
	if record.tool then
		record.tool:Destroy()
		record.tool = nil
	end

	self.NpcSayEvent:FireAllClients(npc, `{prefix}Leaving`)
	NpcRig.StopAnimation(record)
	NpcRig.WalkTo(humanoid, spawnPart.Position)
	self:_despawnNpc(player, record)
	return true
end

-- Runs one visit with its failure contained, releasing the rig, tool, slot and skewers a throw would strand.
function SellNpcManager:_runGuardedVisit(player: Player, visit: () -> boolean?): boolean?
	local success, result = xpcall(visit, debug.traceback)
	if success then
		return result
	end

	warn(`[SellNpcManager] Customer visit for {player.Name} failed, releasing its customer:\n{result}`)

	-- Snapshotted first: _despawnNpc removes from the tracked list as it goes, and yields through the fade.
	local thread = coroutine.running()
	local orphaned = {}
	for _, record in self._npcs[player] or {} do
		if record.thread == thread then
			table.insert(orphaned, record)
		end
	end

	for _, record in orphaned do
		-- Skewers a customer had taken off the stand go back on it, as they do when one walks off unsold.
		if record.skewerRecords then
			SkewerStandManager:ReturnSkewers(player, record.skewerRecords)
			record.skewerRecords = nil
		end

		self:_despawnNpc(player, record)
	end

	return true
end

-- Runs one owed sale on its own thread, resending until one buys. One thread per unsold skewer.
function SellNpcManager:_runVisit(player: Player)
	-- A guaranteed player's customer is on its way as soon as the skewer lands.
	if self._guaranteed[player] then
		task.wait(SellNpc.GUARANTEED_SPAWN_DELAY)
	else
		-- New players wait less, on the same taper as their income head start.
		local scale = EarlyBoost.GetSpawnDelayScale(CurrencyManager:GetEarlyBoostEarnings(player))
		task.wait(self._rng:NextNumber(SellNpc.SPAWN_DELAY_MIN, SellNpc.SPAWN_DELAY_MAX) * scale)
	end

	if not validatePlayer(player) then
		return
	end

	-- Refusals stretch the retry gap. Read fresh each pass, so it decays while the player waits
	local resolved = self:_runGuardedVisit(player, function()
		return self:_spawnCustomer(player)
	end)
	while not resolved and validatePlayer(player) do
		local refusalDelay = self:GetChargedSaleRefusals(player) * SellNpc.REFUSAL_RETRY_DELAY
		task.wait(self._rng:NextNumber(SellNpc.RETRY_DELAY_MIN, SellNpc.RETRY_DELAY_MAX) + refusalDelay)
		if not validatePlayer(player) then
			break
		end
		resolved = self:_runGuardedVisit(player, function()
			return self:_spawnCustomer(player)
		end)
	end
end

-- Sends one customer per skewer on the stand -- what picks a stall back up after a rejoin.
function SellNpcManager:SendCustomersForPlacedSkewers(player: Player)
	local placed = SkewerStandManager:GetPlacedSkewerCount(player)

	for _ = 1, placed do
		task.spawn(function()
			self:_runVisit(player)
		end)
	end
end

-- Sends one rich customer, which takes the whole stand as one sum. No retry -- the roll must come round again.
function SellNpcManager:_spawnRichCustomer(player: Player, firstVisit: boolean?)
	local spawnPart, standPart = NpcRig.GetBaseParts(player)
	if not spawnPart or not standPart then
		return
	end

	local tracked = self._npcs[player]
	if not tracked then
		tracked = {}
		self._npcs[player] = tracked
	end

	-- The ordinary customers' slot allocator, so a rich one lines up beside them rather than inside them.
	local slot, standPosition = NpcRig.ClaimStandPosition(player, spawnPart, standPart)

	local npc = self:_acquireRichNpc()
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	-- Tracked before anything yields, so the roll, cleanup and guarded-visit release all see it
	local record = { npc = npc, tool = nil, slot = slot, isRich = true, thread = coroutine.running() }
	table.insert(tracked, record)

	-- A rich customer is its own character, so there's no appearance lookup to yield on before the fade.
	NpcRig.Fade(npc, true, SellNpc.FADE_IN_DURATION)

	local point = NpcRig.RandomPointOn(spawnPart, self._rng)
	npc:PivotTo(CFrame.lookAt(point + Vector3.new(0, 3, 0), standPosition))
	npc.Parent = workspace

	-- Server-driven movement, so hand the root to the server rather than a nearby client.
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if rootPart and not rootPart.Anchored then
		rootPart:SetNetworkOwner(nil)
	end

	-- Their first says what a rich one is, since the gold UI shows it's different but not why it's worth stocking for
	NotificationManager:NotifyNormal(player, {
		Text = if firstVisit
			then `A {RICH_LABEL} customer is heading to your stand! They buy every BBQ at once, and pay extra for it`
			else `A {RICH_LABEL} customer is heading to your stand!`,
		Duration = if firstVisit then 5 else 3,
		Sound = "RichSpawn",
	})

	NpcRig.WalkTo(humanoid, standPosition)

	if npc.Parent == nil then
		return
	end

	-- One write. The stand was stocked when the roll landed, but can have emptied during the walk.
	local taken = SkewerStandManager:TakeAllSkewers(player)
	if #taken == 0 then
		NpcRig.WalkTo(humanoid, spawnPart.Position)
		self:_despawnNpc(player, record)
		return
	end
	record.skewerRecords = taken

	-- Only the pick of the haul -- six welded into one hand reads as a mess; the offer line gives the count
	local best = taken[1]
	local bestValue = StickModel.GetSellValue(best)
	for index = 2, #taken do
		local skewerValue = StickModel.GetSellValue(taken[index])
		if skewerValue > bestValue then
			best, bestValue = taken[index], skewerValue
		end
	end
	record.tool, record.skewerModel = NpcRig.GiveSkewer(npc, best)

	NpcRig.PlayAnimation(record, "Inspect", self._rng)

	-- No decide beat -- a walk-off would burn a long roll. The client is still told, since that builds its UI
	self.NpcRichArriveEvent:FireAllClients(npc)
	task.wait(self._rng:NextNumber(RichNpc.APPRAISE_DURATION_MIN, RichNpc.APPRAISE_DURATION_MAX))

	if npc.Parent == nil then
		return
	end

	-- The returned haul lands on a stand whose visits all resolved when it emptied, so resend one per skewer
	if not self:_negotiateSale(player, npc, record, humanoid, spawnPart, standPart, standPosition) then
		for _ = 1, #taken do
			task.spawn(function()
				self:_runVisit(player)
			end)
		end
	end
end

-- One pass of the rich-customer roll, cheapest checks first so the data reads are rare.
function SellNpcManager:_rollRichVisits()
	for _, player in Players:GetPlayers() do
		if not validatePlayer(player) then
			continue
		end

		-- Read off the tracked customers rather than a flag, so an errored visit can't leave it stuck set
		local busy = false
		for _, record in self._npcs[player] or {} do
			if record.isRich then
				busy = true
				break
			end
		end
		if busy then
			continue
		end

		if not RandomUtil.RollChance(RichNpc.SPAWN_CHANCE, self._rng) then
			continue
		end

		-- In their data on the synced clock, so rejoining can't hand out a fresh rich customer
		local hasStamp, lastRichVisit = PlayerDataManager:GetPlayerDataKey(player, "LastRichVisit"):await()
		if not hasStamp or (workspace:GetServerTimeNow() - lastRichVisit) < RichNpc.COOLDOWN then
			continue
		end

		-- Last: they clear the whole stand in one sale, so a thin one isn't worth the trip.
		if SkewerStandManager:GetPlacedSkewerCount(player) < RichNpc.MIN_SKEWERS then
			continue
		end

		-- Stamped before the visit, so a long haggle can't let another be rolled the moment this one leaves.
		PlayerDataManager:SetPlayerDataKey(player, "LastRichVisit", workspace:GetServerTimeNow())

		task.spawn(function()
			self:_runGuardedVisit(player, function()
				self:_spawnRichCustomer(player)
			end)
		end)
	end
end

-- Sends the one guaranteed rich customer if this placement first reached MIN_SKEWERS. Returns true if it took the visit over.
function SellNpcManager:TrySendFirstRichVisit(player: Player, count: number): boolean
	if count < RichNpc.MIN_SKEWERS or self._grantedFirstRich[player] then
		return false
	end

	-- Not during the tutorial -- a rich one would take the skewer its accept beat waits on
	if self._guaranteed[player] == true then
		return false
	end

	-- Same reason the roll checks it: one already at the stand is holding the stock this one would want.
	for _, record in self._npcs[player] or {} do
		if record.isRich then
			return false
		end
	end

	-- Gated on hasData, or a profile that failed to load sends one on every placement for the session
	local hasData, seen = PlayerDataManager:GetPlayerDataKey(player, "SeenRichCustomer"):await()
	if not hasData or seen then
		return false
	end

	-- Latched before the writes, which yield, and stamped as the roll stamps it so the timer can't double up
	self._grantedFirstRich[player] = true
	PlayerDataManager:SetPlayerDataKey(player, "SeenRichCustomer", true)
	PlayerDataManager:SetPlayerDataKey(player, "LastRichVisit", workspace:GetServerTimeNow())

	-- Already on the placement's own thread, so this runs inline rather than spawning another.
	self:_runGuardedVisit(player, function()
		self:_spawnRichCustomer(player, true)
	end)

	return true
end

-- Sends a rich customer now off the command bar, keeping only the checks that would leave it meaningless.
function SellNpcManager:ForceRichVisit(player: Player): (boolean, string?)
	if not validatePlayer(player) then
		return false, `{player.Name} has no base to send a customer to.`
	end

	-- Same reason the roll checks it: one already at the stand is holding the stock this one would want.
	for _, record in self._npcs[player] or {} do
		if record.isRich then
			return false, `{player.Name} already has a rich customer at their stand.`
		end
	end

	-- Under MIN_SKEWERS is the gate being skipped, but an empty stand would walk it straight back out
	if SkewerStandManager:GetPlacedSkewerCount(player) == 0 then
		return false, `{player.Name}'s stand is empty, so there's nothing to buy.`
	end

	-- Stamped as the roll stamps it, but not read, so the command can still be re-run straight away
	PlayerDataManager:SetPlayerDataKey(player, "LastRichVisit", workspace:GetServerTimeNow())

	task.spawn(function()
		self:_runGuardedVisit(player, function()
			self:_spawnRichCustomer(player)
		end)
	end)

	return true
end

-- Sends one customer to ask whether there's any BBQ going. Waits out of the queue lane, and buys if one lands.
function SellNpcManager:_spawnCheckingCustomer(player: Player)
	local spawnPart, standPart = NpcRig.GetBaseParts(player)
	if not spawnPart or not standPart then
		return
	end

	local tracked = self._npcs[player]
	if not tracked then
		tracked = {}
		self._npcs[player] = tracked
	end

	-- Claimed like any other customer, so the walk over to a skewer lands in a free lane rather than inside one
	local slot, standPosition = NpcRig.ClaimStandPosition(player, spawnPart, standPart)

	local npc = NpcRig.Acquire()
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	-- Tracked before the lookup yields, so a mid-lookup cleanup destroys the rig rather than orphaning it
	local record = { npc = npc, tool = nil, slot = slot, isChecking = true, thread = coroutine.running() }
	table.insert(tracked, record)

	-- Both calls yield, and a leave during either has already destroyed the parked rig
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

	-- The whole point of the visit: they're at the grill or away from the stand, so the bubble alone would miss
	NotificationManager:NotifyNormal(player, {
		Text = "A customer is asking if you have any BBQ for sale",
		Duration = 3,
	})

	-- The client builds its billboards and speaks the arrival line, as a rich customer's arrival does
	self.NpcCheckingArriveEvent:FireAllClients(npc)

	-- Emitted off the rig rather than through the toast, so it lands with the bubble and carries a direction
	SoundManager:PlaySound("All", "CustomerChecking", npc:GetPivot())

	-- Waits back and off to one side, leaving the stand lanes free for a customer that has something to buy
	local backDir = (spawnPart.Position - standPosition).Unit
	local sideDir = Vector3.new(-backDir.Z, 0, backDir.X)
	local side = self._rng:NextNumber(CheckingNpc.LOITER_SIDE_DISTANCE_MIN, CheckingNpc.LOITER_SIDE_DISTANCE_MAX)
		* (if self._rng:NextNumber() < 0.5 then -1 else 1)

	NpcRig.WalkTo(humanoid, standPosition + backDir * CheckingNpc.LOITER_BACK_DISTANCE + sideDir * side)
	if npc.Parent == nil then
		return
	end

	-- Left idle, no Inspect track: that beat is for looking a skewer over, and _serveStandSkewer plays it once one lands
	npc:PivotTo(CFrame.lookAt(npc:GetPivot().Position, standPosition))

	-- Server-local wait, so os.clock rather than the synced clock the client paces beats off
	local startedAt = os.clock()
	local deadline = startedAt + CheckingNpc.WAIT_DURATION
	local nextAsk = os.clock() + self._rng:NextNumber(CheckingNpc.ASK_INTERVAL_MIN, CheckingNpc.ASK_INTERVAL_MAX)
	local stocked = false

	while os.clock() < deadline and npc.Parent ~= nil do
		if SkewerStandManager:GetPlacedSkewerCount(player) > 0 then
			stocked = true
			break
		end

		if os.clock() >= nextAsk then
			nextAsk = os.clock()
				+ self._rng:NextNumber(CheckingNpc.ASK_INTERVAL_MIN, CheckingNpc.ASK_INTERVAL_MAX)
			self.NpcSayEvent:FireAllClients(npc, "NPCCheckingWaiting")
		end

		task.wait(CheckingNpc.POLL_INTERVAL)
	end

	if npc.Parent == nil then
		return
	end

	-- Nothing turned up, so it gives up. Ignoring one costs the player nothing but the trip
	if not stocked then
		self.OnCheckingVisitEnded:Fire(player, false, CheckingNpc.WAIT_DURATION)
		self.NpcSayEvent:FireAllClients(npc, "NPCCheckingLeaving")
		task.wait(SellNpc.LEAVE_DELAY)
		if npc.Parent == nil then
			return
		end

		NpcRig.WalkTo(humanoid, spawnPart.Position)
		self:_despawnNpc(player, record)
		return
	end

	self.OnCheckingVisitEnded:Fire(player, true, os.clock() - startedAt)
	self.NpcSayEvent:FireAllClients(npc, "NPCCheckingSpotted")
	NpcRig.WalkTo(humanoid, standPosition)
	if npc.Parent == nil then
		return
	end

	-- It can still turn the skewer down, and the returned one lands on a stand no visit thread owns
	if not self:_serveStandSkewer(player, npc, record, humanoid, spawnPart, standPart, standPosition) then
		task.spawn(function()
			self:_runVisit(player)
		end)
	end
end

-- One pass of the checking-customer roll, cheapest checks first so the data reads are rare.
function SellNpcManager:_rollCheckingVisits()
	for _, player in Players:GetPlayers() do
		if not validatePlayer(player) then
			continue
		end

		-- Not during the tutorial, whose sequence expects one customer per placement and nothing else
		if self._guaranteed[player] == true then
			continue
		end

		-- Any customer at all means they aren't being ignored -- and a rich one mid-haggle leaves the stand reading empty
		if next(self._npcs[player] or {}) ~= nil then
			continue
		end

		if not RandomUtil.RollChance(CheckingNpc.SPAWN_CHANCE, self._rng) then
			continue
		end

		-- In their data on the synced clock, so rejoining can't hand out a fresh one
		local hasStamp, lastCheckingVisit = PlayerDataManager:GetPlayerDataKey(player, "LastCheckingVisit"):await()
		if not hasStamp or (workspace:GetServerTimeNow() - lastCheckingVisit) < CheckingNpc.COOLDOWN then
			continue
		end

		-- A zero stamp is a player who has never sold, still working towards their first rather than drifting off
		local hasSale, lastSaleAt = PlayerDataManager:GetPlayerDataKey(player, "LastSaleAt"):await()
		if not hasSale or lastSaleAt == 0 then
			continue
		end
		if (workspace:GetServerTimeNow() - lastSaleAt) < CheckingNpc.SALE_IDLE_TIME then
			continue
		end

		-- Last: a stocked stand draws ordinary customers already, and asking about one in front of them reads wrong
		if SkewerStandManager:GetPlacedSkewerCount(player) > 0 then
			continue
		end

		-- Stamped before the visit, so a long wait can't let another be rolled the moment this one leaves.
		PlayerDataManager:SetPlayerDataKey(player, "LastCheckingVisit", workspace:GetServerTimeNow())

		task.spawn(function()
			self:_runGuardedVisit(player, function()
				self:_spawnCheckingCustomer(player)
			end)
		end)
	end
end

-- Sends a checking customer now off the command bar, keeping only the checks that would leave it meaningless.
function SellNpcManager:ForceCheckingVisit(player: Player): (boolean, string?)
	if not validatePlayer(player) then
		return false, `{player.Name} has no base to send a customer to.`
	end

	for _, record in self._npcs[player] or {} do
		if record.isChecking then
			return false, `{player.Name} already has a customer asking at their stand.`
		end
	end

	-- Stamped as the roll stamps it, but not read, so the command can still be re-run straight away
	PlayerDataManager:SetPlayerDataKey(player, "LastCheckingVisit", workspace:GetServerTimeNow())

	task.spawn(function()
		self:_runGuardedVisit(player, function()
			self:_spawnCheckingCustomer(player)
		end)
	end)

	-- A stocked stand is the idle-stand gate being skipped, so say it rather than let the instant buy look like a bug
	if SkewerStandManager:GetPlacedSkewerCount(player) > 0 then
		return true, `Sent a checking customer to {player.Name}. Their stand is stocked, so it'll buy rather than wait.`
	end

	return true
end

-- Tears down a leaving player's customers. Destroyed, not pooled -- clearing the parent is what mid-visit guards bail on.
function SellNpcManager:_cleanupPlayer(player: Player)
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

	-- The slots and the appearance cache are NpcRig's, and it drops them on the same PlayerRemoving

	self._guaranteed[player] = nil
	self._noticedRefusals[player] = nil
	self._grantedFirstCounter[player] = nil
	self._grantedFirstRich[player] = nil
end

-- Returns held skewers before the last save, or leaving mid-decision deletes them. Must not yield.
function SellNpcManager:ReturnHeldSkewersOnLastSave(player: Player, data)
	local tracked = self._npcs[player]
	if not tracked then
		return
	end

	for _, record in tracked do
		if not record.skewerRecords then
			continue
		end

		for _, skewer in record.skewerRecords do
			-- The stand may have been restocked while the customer held these, so its cap decides what fits.
			if #data.SkewerStand >= SkewerStandManager.MAX_SKEWERS then
				break
			end

			table.insert(data.SkewerStand, skewer)
		end

		-- Cleared so a visit thread still running can't hand the same skewers back a second time.
		record.skewerRecords = nil
	end
end

function SellNpcManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	SkewerStandManager = require(script.Parent.SkewerStandManager)
	CollisionManager = require(script.Parent.CollisionManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	NotificationManager = require(script.Parent.NotificationManager)
	EffectManager = require(script.Parent.EffectManager)
	BaseManager = require(script.Parent.BaseManager)
	StatsManager = require(script.Parent.StatsManager)
	SoundManager = require(script.Parent.SoundManager)
end

function SellNpcManager:OnStart()
	NpcRig.BuildPool()

	-- One skewer, one customer. The placement that first stocks the stand hands its visit to a rich one
	SkewerStandManager.OnSkewerPlaced:Connect(function(player: Player, _record, count: number)
		task.spawn(function()
			if self:TrySendFirstRichVisit(player, count) then
				return
			end

			self:_runVisit(player)
		end)
	end)

	-- The stand outlives the session but its visit threads don't, so a full stall would come back unvisited
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:SendCustomersForPlacedSkewers(player)
	end)

	-- Sweeps players assigned a base before this manager started, off the main thread since it yields
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("BaseId") then
			task.spawn(function()
				self:SendCustomersForPlacedSkewers(player)
			end)
		end
	end

	-- On a timer, so a stocked stand draws one while the player is off at the grill
	task.spawn(function()
		while true do
			task.wait(RichNpc.CHECK_INTERVAL)
			self:_rollRichVisits()
		end
	end)

	-- The mirror of the rich sweep: an empty stand and no recent sale is what draws one asking
	task.spawn(function()
		while true do
			task.wait(CheckingNpc.CHECK_INTERVAL)
			self:_rollCheckingVisits()
		end
	end)

	PlayerDataManager:RegisterPreCleanupCallback(function(player: Player, data)
		self:ReturnHeldSkewersOnLastSave(player, data)
	end)

	self.NpcOfferResponseEvent:OnServerEvent(function(player: Player, npc: Model, accepted: boolean)
		self:AnswerOffer(player, npc, accepted)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)
end

return SellNpcManager
