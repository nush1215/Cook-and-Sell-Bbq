-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
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
local Boosts = require(Shared.Config.Boosts)
local Ingredients = require(Shared.Config.Ingredients)
local CookStates = require(Shared.Config.CookStates)
local Structures = require(Shared.Config.Structures)
local SellNpc = require(Shared.Config.SellNpc)
local HungryJoeNpc = require(Shared.Config.HungryJoeNpc)

-- Managers
local PlayerDataManager = require(script.Parent.PlayerDataManager)
local CurrencyManager = require(script.Parent.CurrencyManager)
local NotificationManager = require(script.Parent.NotificationManager)
local EffectManager = require(script.Parent.EffectManager)
local SoundManager = require(script.Parent.SoundManager)
local CollisionManager = require(script.Parent.CollisionManager)
local StickManager = require(script.Parent.StickManager)
local IngredientManager = require(script.Parent.IngredientManager)
local StatsManager = require(script.Parent.StatsManager)
local BoostManager = require(script.Parent.BoostManager)
local BaseManager = require(script.Parent.BaseManager)
local SellNpcManager = require(script.Parent.SellNpcManager)
local CustomOrderNpcManager = require(script.Parent.CustomOrderNpcManager)

-- Assets
-- Found rather than indexed: both are authored in Studio, and a missing one should leave him out rather than fail the load
local HungryJoeTemplate = ServerStorage.Assets:FindFirstChild("HungryJoe")
local HungryJoeStick = Sticks.GetStickFromId(HungryJoeNpc.STICK_ID)

-- How often the wait is checked. Not per frame: it can run for as long as the cook takes
local DELIVERY_POLL_INTERVAL = 0.1

-- Seconds between looks at their grills for his stick, which is what swaps the hidden clock for the cook one
local GRILL_CHECK_INTERVAL = 1

-- His stick at half its own size in his hand, bigger than an ordinary customer's shrunken skewer
local HELD_STICK_SCALE = 0.75

-- The customer who lends a stick and waits on a clock for it to come back cooked. His walk and fade are the sell stand's; what is his own is the loan, the wait and the feast he pays for it.
local HungryJoeNpcManager = {
	HungryJoeOfferResponseEvent = Network.Event("HungryJoeOfferResponse"),
	HungryJoeDeliverEvent = Network.Event("HungryJoeDeliver"),
	HungryJoeSayEvent = Network.Event("HungryJoeSay"),

	-- (player, trigger, sinceLast, funnelId) when a fresh Hungry Joe sets off; trigger is "Roll", "Pity" or "Forced"
	OnHungryJoeVisitSent = Signal.new(),
	-- (player, outcome, funnelId) once his job is answered; outcome is "Accepted", "Declined" or "TimedOut"
	OnHungryJoeOfferResolved = Signal.new(),
	-- (player, delivered, reward, waited, funnelId) once he's handed his stick back and paid for it
	OnHungryJoeFed = Signal.new(),
	-- (player, clockPhase, funnelId) once he gives up and takes his stick back; clockPhase is the clock that ran out, "Idle" or "Cook"
	OnHungryJoeLeftAngry = Signal.new(),

	_visits = {}, -- [player] = record, the one Hungry Joe at their base
	_delivering = {}, -- [player] = true across the read -> write window, so a spammed prompt can't pay twice
	_rng = ServerRandom.MakeRNG("HungryJoeNpc"),
}

-- True while the player is still in-game and has a base to send customers to.
local function validatePlayer(player: Player): boolean
	return player:IsDescendantOf(Players) and player:GetAttribute("BaseId") ~= nil
end

-- Whether the player has Hungry Joe's stick anywhere it can be: loose, on a stand, in hand, on a grill or on the sauce plate. Huts and the stall refuse it, so they aren't looked in.
function HungryJoeNpcManager:HasHungryJoeStickAnywhere(data): boolean
	if (data.Sticks[HungryJoeNpc.STICK_ID] or 0) > 0 then
		return true
	end

	for _, records in { data.StickStands, data.FilledSticks, data.Grillers } do
		for _, record in records do
			-- A legacy string-shaped stand entry reads as empty rather than erroring on .StickId
			if type(record) == "table" and record.StickId == HungryJoeNpc.STICK_ID then
				return true
			end
		end
	end

	for _, dispenser in data.SauceDispensers do
		if dispenser.Skewer and dispenser.Skewer.StickId == HungryJoeNpc.STICK_ID then
			return true
		end
	end

	return false
end

-- Lends the player Hungry Joe's stick unless they already have it somewhere. True if one was handed over.
function HungryJoeNpcManager:GrantHungryJoeStickIfMissing(player: Player, skipEquip: boolean): boolean
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or self:HasHungryJoeStickAnywhere(data) then
		return false
	end

	StickManager:GrantStick(player, HungryJoeNpc.STICK_ID, 1, skipEquip)
	return true
end

-- Puts a line in Hungry Joe's bubble. Sent to whoever is standing near him rather than the whole server.
function HungryJoeNpcManager:SpeakHungryJoeNpc(npc: Model, category: string)
	local audience = NpcRig.GetAudience(npc)
	if #audience == 0 then
		return
	end

	self.HungryJoeSayEvent:FireClients(audience, npc, category)
end

-- Records the owner's answer to his job; finding him at their own base is the authority check.
function HungryJoeNpcManager:AnswerHungryJoeOffer(player: Player, npc: Model, accepted: boolean)
	local record = self._visits[player]
	if not record or record.npc ~= npc or not record.offerPending then
		return
	end

	record.offerPending = false
	record.offerResponse = accepted == true
end

-- Runs one whole visit: the walk over, the job put to them, and the wait for his stick. A `startedAt` brings back one they'd already taken on, straight into the wait.
function HungryJoeNpcManager:_spawnHungryJoeCustomer(
	player: Player,
	trigger: string,
	sinceLast: number,
	startedAt: number?
)
	local spawnPart, standPart = NpcRig.GetBaseParts(player)
	if not spawnPart or not standPart then
		return
	end

	-- Not pooled -- he's his own character, and NpcRig.Release would repaint him as the template
	local npc = HungryJoeTemplate:Clone()
	CollisionManager:SetModelGroup(npc, CollisionManager.NPC)

	-- Whole or not at all: under default mode the tag lands on the client long before the head the billboards hang off
	npc.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	npc.Parent = NpcRig.PoolFolder

	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	-- Floored, since it's saved as the loan's stamp and doubles as the funnel id a restore carries on
	local arrivedAt = startedAt or math.floor(workspace:GetServerTimeNow())

	-- Tracked before anything yields, so the roll, cleanup and guarded-visit release all see it
	local record = {
		npc = npc,
		arrivedAt = arrivedAt,
		funnelId = tostring(arrivedAt),
		thread = coroutine.running(),
	}
	self._visits[player] = record

	-- Just off to one side of the stand, a random side each visit. Flattened, so a spawn part at another height can't tilt it
	local backDir = ((spawnPart.Position - standPart.Position) * Vector3.new(1, 0, 1)).Unit
	local sideDir = Vector3.new(-backDir.Z, 0, backDir.X)
	local side = if self._rng:NextNumber() < 0.5 then -1 else 1
	local waitPosition = standPart.Position
		+ backDir * HungryJoeNpc.WAIT_BACK_DISTANCE
		+ sideDir * HungryJoeNpc.WAIT_SIDE_DISTANCE * side

	NpcRig.Fade(npc, true, SellNpc.FADE_IN_DURATION)

	local point = NpcRig.RandomPointOn(spawnPart, self._rng)
	npc:PivotTo(CFrame.lookAt(point + Vector3.new(0, 3, 0), waitPosition))

	-- Stamped before he lands, so it arrives with the rig rather than a frame behind it
	npc:SetAttribute(Structures.OWNER_ATTRIBUTE, player.UserId)
	npc.Parent = workspace

	-- Tagged after, so a client's tag hook can trust the owner stamp is already on
	npc:AddTag(HungryJoeNpc.TAG)

	-- Server-driven movement, so hand the root to the server rather than a nearby client.
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if rootPart and not rootPart.Anchored then
		rootPart:SetNetworkOwner(nil)
	end

	-- A fresh visit walks in holding the stick he's come to lend. A restored one already lent it, so his hands are empty
	if not startedAt then
		record.tool, record.skewerModel =
			NpcRig.GiveSkewer(npc, { StickId = HungryJoeNpc.STICK_ID, Ingredients = {} }, HELD_STICK_SCALE)
	end

	-- A frame between parenting the rig and naming it over a remote, or a client it hasn't reached yet drops the line
	task.wait()
	if npc.Parent == nil then
		return
	end

	if startedAt then
		NotificationManager:NotifyNormal(player, {
			Text = `{HungryJoeNpc.LABEL} is back!`,
			Duration = 4,
			Sound = "CustomerArrived",
		})
		self:SpeakHungryJoeNpc(npc, "HungryJoeNPCReturned")
	else
		self.OnHungryJoeVisitSent:Fire(player, trigger, sinceLast, record.funnelId)

		-- Marked as he's sent, however it goes, so the hourly pace takes over from the next one
		PlayerDataManager:SetPlayerDataKey(player, "SeenHungryJoe", true)

		NotificationManager:NotifyNormal(player, {
			Text = `{HungryJoeNpc.LABEL} is here!`,
			Duration = 3,
			Sound = "CustomerArrived",
		})
		self:SpeakHungryJoeNpc(npc, "HungryJoeNPCArrived")
	end

	NpcRig.WalkTo(humanoid, waitPosition)
	if npc.Parent == nil then
		return
	end

	-- Turned back toward the stand, so he waits watching the player rather than facing off the base
	npc:PivotTo(CFrame.lookAt(npc:GetPivot().Position, standPart.Position))

	if startedAt then
		-- Lost somehow while he was away, so he lends another rather than waiting on one they can't bring
		if self:GrantHungryJoeStickIfMissing(player, true) then
			NotificationManager:NotifyNormal(player, {
				Text = `{HungryJoeNpc.LABEL} gave you a new stick`,
				Duration = 4,
				Sound = "Notify",
			})
		end

		local hasData, data = PlayerDataManager:GetPlayerData(player):await()
		if not hasData or npc.Parent == nil then
			return
		end

		-- Picked up where the last save banked it, so time away never ran it down. One saved before the clock existed starts fresh
		local saved = data.HungryJoeClock
		self:_setHungryJoeClock(
			player,
			record,
			saved.Phase or HungryJoeNpc.CLOCK_PHASES.Idle,
			saved.SecondsLeft or HungryJoeNpc.IDLE_TIMEOUT
		)

		self:_runHungryJoeJob(player, npc, record, humanoid, spawnPart)
		return
	end

	if not self:_offerHungryJoeJob(player, npc, record) then
		if npc.Parent == nil then
			return
		end

		npc:SetAttribute(HungryJoeNpc.PHASE_ATTRIBUTE, nil)

		-- Ignored and turned down are different things, so they leave on different lines. No refusal is charged either way
		local ignored = record.offerResponse == nil
		self.OnHungryJoeOfferResolved:Fire(player, if ignored then "TimedOut" else "Declined", record.funnelId)
		self:SpeakHungryJoeNpc(npc, if ignored then "HungryJoeNPCOfferIgnored" else "HungryJoeNPCPlayerDeclined")

		-- His gap runs from when he left, so the next one is spaced from this one rather than from his arrival
		PlayerDataManager:SetPlayerDataKey(player, "LastHungryJoeVisit", workspace:GetServerTimeNow())

		if ignored then
			NotificationManager:NotifyNormal(player, {
				Text = `{HungryJoeNpc.LABEL} left!`,
				Duration = 3,
				Sound = "Reject",
			})
		end

		task.wait(SellNpc.LEAVE_DELAY)
		if npc.Parent == nil then
			return
		end

		self:_leaveHungryJoe(player, record, humanoid, spawnPart)
		return
	end

	-- Banked before the stick changes hands, so leaving from here on brings him back rather than stranding the loan
	PlayerDataManager:SetPlayerDataKey(player, "HungryJoeVisitStartedAt", arrivedAt)
	self.OnHungryJoeOfferResolved:Fire(player, "Accepted", record.funnelId)
	self:SpeakHungryJoeNpc(npc, "HungryJoeNPCPlayerAccepted")

	-- Out of his hand and into theirs, the moment it's granted below
	record.skewerModel:Destroy()
	record.skewerModel = nil
	record.tool:Destroy()
	record.tool = nil

	self:GrantHungryJoeStickIfMissing(player, false)
	NotificationManager:NotifyNormal(player, {
		Text = `Fill {HungryJoeNpc.LABEL}'s stick and cook it!`,
		Duration = 4,
		Sound = "Notify",
	})

	self:_setHungryJoeClock(player, record, HungryJoeNpc.CLOCK_PHASES.Idle, HungryJoeNpc.IDLE_TIMEOUT)
	self:_runHungryJoeJob(player, npc, record, humanoid, spawnPart)
end

-- Calls the player's attention to him: an error toast, and a pulse on his outline so they can find him.
function HungryJoeNpcManager:_nudgeHungryJoe(player: Player, npc: Model, text: string)
	NotificationManager:NotifyNormal(player, {
		Text = text,
		Duration = 3,
		Sound = "CustomerPinged",
		Effect = "Error",
	})

	EffectManager:RunEffect({ Type = "Player", Player = player }, "HighlightPulse", {
		npc,
		SellNpc.NUDGE_PULSE_COLOR,
		SellNpc.NUDGE_PULSE_DURATION,
		SellNpc.NUDGE_PULSE_START_TRANSPARENCY,
		SellNpc.NUDGE_PULSE_COUNT,
	})
end

-- Starts his clock on `phase` with `seconds` to run: shown on the rig unless it's the hidden idle stretch, and banked so a crash still brings it back.
function HungryJoeNpcManager:_setHungryJoeClock(player: Player, record, phase: string, seconds: number)
	record.clockPhase = phase
	record.clockDeadline = workspace:GetServerTimeNow() + seconds

	record.npc:SetAttribute(
		HungryJoeNpc.CLOCK_ATTRIBUTE,
		if phase == HungryJoeNpc.CLOCK_PHASES.Idle then nil else record.clockDeadline
	)

	PlayerDataManager:SetPlayerDataKey(player, "HungryJoeClock", { Phase = phase, SecondsLeft = seconds })
end

-- Puts his job to the player and waits for an answer, nudging them while it's up. True if they took it on.
function HungryJoeNpcManager:_offerHungryJoeJob(player: Player, npc: Model, record): boolean
	record.offerResponse = nil
	record.offerPending = true
	npc:SetAttribute(HungryJoeNpc.PHASE_ATTRIBUTE, HungryJoeNpc.PHASES.Offering)

	local deadline = os.clock() + HungryJoeNpc.OFFER_TIMEOUT
	local nudgeAt = os.clock() + SellNpc.OFFER_NUDGE_INTERVAL
	while record.offerResponse == nil and os.clock() < deadline and npc.Parent ~= nil do
		if os.clock() >= nudgeAt then
			nudgeAt = os.clock() + SellNpc.OFFER_NUDGE_INTERVAL
			self:_nudgeHungryJoe(player, npc, `{HungryJoeNpc.LABEL} is waiting!`)
		end

		task.wait()
	end
	record.offerPending = false

	return npc.Parent ~= nil and record.offerResponse == true
end

-- The accepted half: waits on his clock for his stick to come back, then eats it and leaves, or gives up and takes it back. Split out so a restore re-enters here without asking again.
function HungryJoeNpcManager:_runHungryJoeJob(
	player: Player,
	npc: Model,
	record,
	humanoid: Humanoid,
	spawnPart: BasePart
)
	record.awaitingStick = true
	npc:SetAttribute(HungryJoeNpc.PHASE_ATTRIBUTE, HungryJoeNpc.PHASES.Waiting)

	local nextSayAt = 0
	local nextGrillCheckAt = 0
	while not record.fed and npc.Parent ~= nil do
		if os.clock() >= nextSayAt then
			-- Silent on the first pass, which only schedules the next, since his accept or return line was just said
			if nextSayAt > 0 then
				self:SpeakHungryJoeNpc(npc, "HungryJoeNPCWaiting")
			end
			nextSayAt = os.clock()
				+ self._rng:NextNumber(HungryJoeNpc.WAIT_SAY_INTERVAL_MIN, HungryJoeNpc.WAIT_SAY_INTERVAL_MAX)
		end

		-- Only the hidden stretch watches for the grill: once the cook clock or the warning is up it runs out, so pulling and re-grilling can't reset it
		if record.clockPhase == HungryJoeNpc.CLOCK_PHASES.Idle and os.clock() >= nextGrillCheckAt then
			nextGrillCheckAt = os.clock() + GRILL_CHECK_INTERVAL

			-- Nil only in the moment between them leaving and the teardown taking him down
			local data = PlayerDataManager:GetLoadedPlayerData(player)
			local grillers = if data then data.Grillers else {}

			for _, grill in grillers do
				if grill.StickId == HungryJoeNpc.STICK_ID then
					-- Sized as a custom order's clock is, off what went on his stick
					local seconds = Ingredients.GetTotalCookTime(grill.Ingredients) / CookStates.RAW_END
						+ HungryJoeNpc.COOK_LEEWAY_BASE
						+ HungryJoeNpc.COOK_LEEWAY_PER_INGREDIENT * #grill.Ingredients

					self:_setHungryJoeClock(player, record, HungryJoeNpc.CLOCK_PHASES.Cook, math.round(seconds))
					break
				end
			end
		end

		-- Not while a hand-over is paying out, which has already cleared awaitingStick and is about to feed him
		if record.awaitingStick and workspace:GetServerTimeNow() >= record.clockDeadline then
			if record.clockPhase == HungryJoeNpc.CLOCK_PHASES.Warning then
				break
			end

			-- Kept for analytics, which reads which clock ran him out of patience
			record.warnedFrom = record.clockPhase
			self:_setHungryJoeClock(player, record, HungryJoeNpc.CLOCK_PHASES.Warning, HungryJoeNpc.WARNING_DURATION)
			self:SpeakHungryJoeNpc(npc, "HungryJoeNPCHurry")
			self:_nudgeHungryJoe(player, npc, `{HungryJoeNpc.LABEL} is waiting for his BBQ!`)
		end

		task.wait(DELIVERY_POLL_INTERVAL)
	end
	if npc.Parent == nil then
		return
	end

	npc:SetAttribute(HungryJoeNpc.PHASE_ATTRIBUTE, nil)
	npc:SetAttribute(HungryJoeNpc.CLOCK_ATTRIBUTE, nil)

	if not record.fed then
		self:_leaveHungryJoeAngry(player, npc, record, humanoid, spawnPart)
		return
	end

	record.tool, record.skewerModel = NpcRig.GiveSkewer(npc, record.fed, HELD_STICK_SCALE)
	NpcRig.PlayAnimation(record, "HungryJoeEat", self._rng)
	self:SpeakHungryJoeNpc(npc, "HungryJoeNPCEating")

	NpcRig.EatSkewerIngredients(record.skewerModel, HungryJoeNpc.EAT_DURATION)
	if npc.Parent == nil then
		return
	end

	record.skewerModel:Destroy()
	record.skewerModel = nil
	record.tool:Destroy()
	record.tool = nil

	self:SpeakHungryJoeNpc(npc, "HungryJoeNPCLeaving")
	self:_leaveHungryJoe(player, record, humanoid, spawnPart)
end

-- Takes his stick back if it's cooked, and pays the feast for it on the spot. Anything else is refused and stays in hand.
function HungryJoeNpcManager:DeliverHungryJoeStick(player: Player, npc: Model)
	local record = self._visits[player]
	if self._delivering[player] or not record or record.npc ~= npc or not record.awaitingStick then
		return
	end

	-- The read yields, so the whole window is guarded or a spammed prompt could pay the same stick twice
	self._delivering[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or not record.awaitingStick then
		self._delivering[player] = nil
		return
	end

	-- The prompt is up for the whole wait rather than only while they hold his stick, so a wrong one is answered rather than dropped
	local delivered = StickManager:GetEquippedFilledStick(player, data)
	if not delivered then
		self:_scoldHungryJoeHandOver(player, npc, record, "HungryJoeNPCEmptyHanded")
		self._delivering[player] = nil
		return
	end

	if delivered.StickId ~= HungryJoeNpc.STICK_ID then
		self:_scoldHungryJoeHandOver(
			player,
			npc,
			record,
			"HungryJoeNPCWrongStick",
			`That's not {HungryJoeNpc.LABEL}'s stick!`
		)
		self._delivering[player] = nil
		return
	end

	if HungryJoeNpc.REFUSED_COOK_STATES[StickModel.GetCookStateId(delivered)] then
		self:_scoldHungryJoeHandOver(player, npc, record, "HungryJoeNPCNotReady", "Cook it first!")
		self._delivering[player] = nil
		return
	end

	-- The commit point: the stick leaves their hand and the loan is settled together, so nothing between can bring him back for it
	record.awaitingStick = false
	PlayerDataManager:SetPlayerDataKey(player, { "FilledSticks", delivered.Uid }, nil)
	PlayerDataManager:SetPlayerDataKey(player, "HungryJoeVisitStartedAt", 0)
	PlayerDataManager:SetPlayerDataKey(player, "HungryJoeClock", {})
	PlayerDataManager:SetPlayerDataKey(player, "LastHungryJoeVisit", workspace:GetServerTimeNow())

	-- Still a sale for the stats and rating, just one paid as a feast
	StatsManager:RecordSaleCompleted(player, { delivered })

	local reward = self:GrantHungryJoeFeastReward(player, npc, delivered)
	self.OnHungryJoeFed:Fire(
		player,
		delivered,
		reward,
		workspace:GetServerTimeNow() - record.arrivedAt,
		record.funnelId
	)

	-- Set last, so the waiting loop only wakes on a feast already paid for
	record.fed = delivered
	self._delivering[player] = nil
end

-- Answers a hand-over he won't take, with a bubble and, when it needs explaining, a toast. Rate-limited, so leaning on the prompt can't stack them.
function HungryJoeNpcManager:_scoldHungryJoeHandOver(
	player: Player,
	npc: Model,
	record,
	category: string,
	text: string?
)
	local now = workspace:GetServerTimeNow()

	-- Re-derived rather than advanced, so a server hitch can't queue two back to back. The first press is never swallowed
	if record.lastScoldAt and now - record.lastScoldAt < HungryJoeNpc.SCOLD_INTERVAL then
		return
	end
	record.lastScoldAt = now

	self:SpeakHungryJoeNpc(npc, category)

	if text then
		NotificationManager:NotifyNormal(player, {
			Text = text,
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return
	end

	-- Empty-handed gets no toast, since the bubble is already in their eyeline. Limited, or a Reject toast landing at the same moment doubles up
	SoundManager:PlaySound({ Type = "Player", Player = player }, "Reject", npc.HumanoidRootPart, nil, { Limit = true })
end

-- Pays the feast for his stick: Bux off its worth and Gems by how full it was, then on a full stick Luck by its cook. Each lands as its own toast. The one place the reward model lives. Returns what it paid, for analytics.
function HungryJoeNpcManager:GrantHungryJoeFeastReward(player: Player, npc: Model, delivered)
	local filled = #delivered.Ingredients
	local cookStateId = StickModel.GetCookStateId(delivered)

	-- The plain figure -- applying boosts is IncrementCurrency's job, and the boosted one is only what's shown
	local paid = math.round(StickModel.GetSellValue(delivered) * HungryJoeNpc.FEAST_MULTIPLIER)
	local banked = CurrencyManager:GetBoostedAmount(player, paid)
	CurrencyManager:IncrementCurrency(player, paid, "HungryJoe")

	-- The payout lets each projectile pop a "+X" that adds up to the counter's jump
	EffectManager:RunEffect("All", "CollectCash", { npc, banked, player })

	-- {value} is NotificationManager's placeholder for Count, so it must survive uninterpolated
	NotificationManager:NotifyNormal(player, {
		Text = HungryJoeNpc.LABEL .. " gave you {value}",
		Duration = 4,
		Effect = "Success",
		Count = {
			Value = banked,
			Format = "Price",
			Color = Colors.Currency,
		},
	})

	-- Scaled by the fill, so a stick with one thing on it can't farm the full handful
	local gems = math.round(
		self._rng:NextInteger(HungryJoeNpc.GEMS_MIN, HungryJoeNpc.GEMS_MAX) * filled / HungryJoeStick.Capacity
	)
	CurrencyManager:IncrementGems(player, gems, "HungryJoe")
	EffectManager:RunEffect("All", "CollectGems", { npc, gems, player })

	NotificationManager:NotifyNormal(player, {
		Text = HungryJoeNpc.LABEL .. " gave you {value} Gems",
		Duration = 4,
		Effect = "Success",
		Count = {
			Value = gems,
			Format = "Comma",
			Color = Colors.Gems,
		},
	})

	-- Announced in his name rather than GrantBoost's plain label, so it reads as the third line of his feast
	local luck = if filled >= HungryJoeStick.Capacity then HungryJoeNpc.LUCK_BY_COOK_STATE[cookStateId] else nil
	if luck then
		local label = `{Boosts.GetLabel("Luck", luck.Amount)} for {GuiUtil.ConvertSecondsToDHMS(luck.Duration)}`
		BoostManager:GrantBoost(player, "Luck", luck.Amount, luck.Duration, `{HungryJoeNpc.LABEL} gave you {label}`)
	end

	return {
		Bux = banked,
		Gems = gems,
		Luck = if luck then luck.Amount else 0,
		Filled = filled,
		CookState = cookStateId,
	}
end

-- Ends a job he ran out of patience on: takes his stick back, hands back what's raw on it, and storms off.
function HungryJoeNpcManager:_leaveHungryJoeAngry(
	player: Player,
	npc: Model,
	record,
	humanoid: Humanoid,
	spawnPart: BasePart
)
	-- Owed nothing from here, so a hand-over pressed as he turns can't land
	record.awaitingStick = false

	local returned = 0
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if hasData then
		returned = self:TakeBackHungryJoeStick(player, data)
	end

	PlayerDataManager:SetPlayerDataKey(player, "HungryJoeVisitStartedAt", 0)
	PlayerDataManager:SetPlayerDataKey(player, "HungryJoeClock", {})
	PlayerDataManager:SetPlayerDataKey(player, "LastHungryJoeVisit", workspace:GetServerTimeNow())

	self.OnHungryJoeLeftAngry:Fire(player, record.warnedFrom, record.funnelId)
	self:SpeakHungryJoeNpc(npc, "HungryJoeNPCAngry")

	NotificationManager:NotifyNormal(player, {
		Text = `{HungryJoeNpc.LABEL} left ANGRY and took his stick!`,
		Duration = 4,
		Sound = "Reject",
		Effect = "Error",
	})

	if returned > 0 then
		NotificationManager:NotifyNormal(player, {
			Text = "Your ingredients were returned",
			Duration = 4,
			Sound = "Notify",
		})
	end

	task.wait(SellNpc.LEAVE_DELAY)
	if npc.Parent == nil then
		return
	end

	self:_leaveHungryJoe(player, record, humanoid, spawnPart)
end

-- Takes his stick back from wherever it is. Raw ingredients on it go back to their inventory; cooked or cooking, they go with it. Returns how many came back.
function HungryJoeNpcManager:TakeBackHungryJoeStick(player: Player, data): number
	local returned = {}

	-- Tallied by kind, so each is one grant rather than one per slot
	local function returnRaw(record)
		if record.Cooked then
			return
		end

		for _, id in record.Ingredients do
			returned[id] = (returned[id] or 0) + 1
		end
	end

	local loose = data.Sticks[HungryJoeNpc.STICK_ID] or 0
	if loose > 0 then
		StickManager:ConsumeStick(player, HungryJoeNpc.STICK_ID, loose)
	end

	for uid, record in data.StickStands do
		-- A legacy string-shaped stand entry reads as empty rather than erroring on .StickId
		if type(record) == "table" and record.StickId == HungryJoeNpc.STICK_ID then
			returnRaw(record)
			PlayerDataManager:SetPlayerDataKey(player, { "StickStands", uid }, nil)
		end
	end

	for uid, record in data.FilledSticks do
		if record.StickId == HungryJoeNpc.STICK_ID then
			returnRaw(record)
			PlayerDataManager:SetPlayerDataKey(player, { "FilledSticks", uid }, nil)
		end
	end

	for uid, record in data.Grillers do
		if record.StickId == HungryJoeNpc.STICK_ID then
			PlayerDataManager:SetPlayerDataKey(player, { "Grillers", uid }, nil)
		end
	end

	for slotId, dispenser in data.SauceDispensers do
		if dispenser.Skewer and dispenser.Skewer.StickId == HungryJoeNpc.STICK_ID then
			PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "Skewer" }, nil)
		end
	end

	local count = 0
	for id, amount in returned do
		IngredientManager:GrantIngredient(player, id, amount, true)
		count += amount
	end

	return count
end

-- Walks Hungry Joe off the base and removes him, on whichever line the visit ended.
function HungryJoeNpcManager:_leaveHungryJoe(player: Player, record, humanoid: Humanoid, spawnPart: BasePart)
	NpcRig.StopAnimation(record)
	NpcRig.WalkTo(humanoid, spawnPart.Position)
	self:_despawnHungryJoe(player, record)
end

-- Removes Hungry Joe: clears his skewer and tool, fades him out and destroys him. Never pooled, since he's his own model.
function HungryJoeNpcManager:_despawnHungryJoe(player: Player, record)
	NpcRig.StopAnimation(record)

	if record.skewerModel then
		record.skewerModel:Destroy()
	end
	if record.tool then
		record.tool:Destroy()
	end

	NpcRig.Fade(record.npc, false, SellNpc.FADE_OUT_DURATION)

	-- The player may have left during the fade, in which case _cleanupPlayer already destroyed him
	if record.npc.Parent == nil then
		return
	end

	record.npc:Destroy()

	if self._visits[player] == record then
		self._visits[player] = nil
	end
end

-- Runs one visit with its failure contained, releasing the rig a throw would strand. A loan already taken stays saved, so the next join brings him back.
function HungryJoeNpcManager:_runGuardedHungryJoeVisit(
	player: Player,
	trigger: string,
	sinceLast: number,
	startedAt: number?
)
	local success, err = xpcall(function()
		self:_spawnHungryJoeCustomer(player, trigger, sinceLast, startedAt)
	end, debug.traceback)
	if success then
		return
	end

	warn(`[HungryJoeNpcManager] Hungry Joe visit for {player.Name} failed, releasing him:\n{err}`)

	-- Stamped, or a visit that throws every time would be re-sent on every sweep once the pity is due
	PlayerDataManager:SetPlayerDataKey(player, "LastHungryJoeVisit", workspace:GetServerTimeNow())

	local record = self._visits[player]
	if not record or record.thread ~= coroutine.running() then
		return
	end

	-- Owed nothing from here, so neither an answer nor a hand-over during the fade can land
	record.offerPending, record.awaitingStick = false, false
	self:_despawnHungryJoe(player, record)
end

-- One pass of the Hungry Joe roll: never before MIN_GAP, a chance after it, always by MAX_GAP.
function HungryJoeNpcManager:_rollHungryJoeVisits()
	for _, player in Players:GetPlayers() do
		if not validatePlayer(player) or self._visits[player] then
			continue
		end

		-- Not during the tutorial, whose sequence expects one customer per placement and nothing else
		if SellNpcManager:AreCustomersGuaranteed(player) then
			continue
		end

		-- One still owed his stick is the join beat's to bring back, never a fresh one on top of it
		local data = PlayerDataManager:GetLoadedPlayerData(player)
		if not data or data.HungryJoeVisitStartedAt ~= 0 then
			continue
		end

		local now = workspace:GetServerTimeNow()

		-- A zero stamp starts the clock rather than reading as forever ago, or the first check would be a pity visit
		if data.LastHungryJoeVisit == 0 then
			PlayerDataManager:SetPlayerDataKey(player, "LastHungryJoeVisit", now)
			continue
		end

		-- Their first comes sooner, so meeting him isn't an hour's wait
		local minGap = if data.SeenHungryJoe then HungryJoeNpc.MIN_GAP else HungryJoeNpc.FIRST_MIN_GAP
		local maxGap = if data.SeenHungryJoe then HungryJoeNpc.MAX_GAP else HungryJoeNpc.FIRST_MAX_GAP

		local sinceLast = now - data.LastHungryJoeVisit
		if sinceLast < minGap then
			continue
		end

		-- Two new customers never arrive together, so he waits out a wizard, a rich one, or a custom order still on its way in
		if SellNpcManager:HasSpecialCustomer(player) or CustomOrderNpcManager:HasUnsettledCustomer(player) then
			continue
		end

		local pity = sinceLast >= maxGap
		if not pity and not RandomUtil.RollChance(HungryJoeNpc.SPAWN_CHANCE, self._rng) then
			continue
		end

		-- Not stamped here: his gap runs from when he leaves, and the record the visit tracks holds the next roll back until then
		task.spawn(function()
			self:_runGuardedHungryJoeVisit(player, if pity then "Pity" else "Roll", sinceLast)
		end)
	end
end

-- Sends Hungry Joe now off the command bar, skipping the pacing. One still owed his stick is brought back instead.
function HungryJoeNpcManager:ForceHungryJoeVisit(player: Player): (boolean, string?)
	if not validatePlayer(player) then
		return false, `{player.Name} has no base to send a customer to.`
	end

	if self._visits[player] then
		return false, `{player.Name} already has Hungry Joe at their base.`
	end

	local data = PlayerDataManager:GetLoadedPlayerData(player)
	if not data then
		return false, `{player.Name}'s data hasn't loaded yet.`
	end

	local startedAt = if data.HungryJoeVisitStartedAt ~= 0 then data.HungryJoeVisitStartedAt else nil
	local sinceLast = if data.LastHungryJoeVisit > 0 then workspace:GetServerTimeNow() - data.LastHungryJoeVisit else 0

	task.spawn(function()
		self:_runGuardedHungryJoeVisit(player, "Forced", sinceLast, startedAt)
	end)

	if startedAt then
		return true, `Brought back Hungry Joe, still waiting on {player.Name}'s stick.`
	end

	return true
end

-- Their join beat: brings Hungry Joe back if they left while he was still owed his stick. Yields.
function HungryJoeNpcManager:ResumeHungryJoeVisitForPlayer(player: Player)
	-- A beat before he turns up, rather than materialising on a client still loading its base in
	task.wait(HungryJoeNpc.RESTORE_DELAY)
	if not validatePlayer(player) or self._visits[player] then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or data.HungryJoeVisitStartedAt == 0 then
		return
	end

	self:_runGuardedHungryJoeVisit(player, "Restored", 0, data.HungryJoeVisitStartedAt)
end

-- Whether Hungry Joe is on his way in or putting his job to them. The other special customers wait this out, so two never arrive together.
function HungryJoeNpcManager:IsHungryJoeArriving(player: Player): boolean
	local record = self._visits[player]
	return record ~= nil and not record.awaitingStick and not record.fed
end

-- Banks his visit on the outgoing profile: the gap when his job was never taken, so leaving mid-offer doesn't hand a fresh one straight back, else what's left on his clock. Runs inside the final save, so it writes `data` directly rather than yielding.
function HungryJoeNpcManager:SaveHungryJoeVisitOnLastSave(player: Player, data)
	local record = self._visits[player]
	if not record then
		return
	end

	local now = workspace:GetServerTimeNow()

	if data.HungryJoeVisitStartedAt == 0 then
		data.LastHungryJoeVisit = now
	elseif record.clockDeadline then
		-- At least a second, so a clock caught at its last moment still runs out on the next join rather than restarting
		data.HungryJoeClock = {
			Phase = record.clockPhase,
			SecondsLeft = math.max(math.ceil(record.clockDeadline - now), 1),
		}
	end
end

-- Tears down a leaving player's Hungry Joe. Destroyed rather than walked off -- clearing the parent is what mid-visit guards bail on. A loan still owed stays saved.
function HungryJoeNpcManager:_cleanupPlayer(player: Player)
	-- PlayerRemoving order isn't guaranteed, so this may run before the last save and has to bank the visit itself
	local data = PlayerDataManager:GetLoadedPlayerData(player)
	if data then
		self:SaveHungryJoeVisitOnLastSave(player, data)
	end

	local record = self._visits[player]
	if record then
		if record.skewerModel then
			record.skewerModel:Destroy()
		end
		if record.tool then
			record.tool:Destroy()
		end
		record.npc:Destroy()
		self._visits[player] = nil
	end

	self._delivering[player] = nil
end

function HungryJoeNpcManager:OnStart()
	-- Both come off Studio assets, so a missing rig or stick model leaves him out rather than erroring mid-visit
	if not HungryJoeTemplate or not HungryJoeStick then
		warn(
			"[HungryJoeNpcManager] ServerStorage.Assets.HungryJoe or Assets.Sticks.HungryJoeStick is missing, so Hungry Joe won't visit"
		)
		return
	end

	-- Its own clock, so his floor and pity pace him rather than any other customer's cadence
	task.spawn(function()
		while true do
			task.wait(HungryJoeNpc.CHECK_INTERVAL)
			self:_rollHungryJoeVisits()
		end
	end)

	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		task.spawn(function()
			self:ResumeHungryJoeVisitForPlayer(player)
		end)
	end)

	-- Sweeps players assigned a base before this manager started, or a loan they left owed is never brought back
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("BaseId") then
			task.spawn(function()
				self:ResumeHungryJoeVisitForPlayer(player)
			end)
		end
	end

	self.HungryJoeOfferResponseEvent:OnServerEvent(function(player: Player, npc: Model, accepted: boolean)
		self:AnswerHungryJoeOffer(player, npc, accepted)
	end)

	self.HungryJoeDeliverEvent:OnServerEvent(function(player: Player, npc: Model)
		self:DeliverHungryJoeStick(player, npc)
	end)

	-- Also run by _cleanupPlayer, since the last save can land either side of the teardown clearing the record
	PlayerDataManager:RegisterPreCleanupCallback(function(player: Player, data)
		self:SaveHungryJoeVisitOnLastSave(player, data)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)
end

return HungryJoeNpcManager
