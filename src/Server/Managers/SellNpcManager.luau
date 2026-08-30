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

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GlobalUtil = require(Shared.GlobalUtil)
local Colors = require(Shared.Colors)
local StickModel = require(Shared.StickModel)
local RandomUtil = require(Shared.RandomUtil)
local Animations = require(Shared.Animations)
local SellNpc = require(Shared.Config.SellNpc)
local RichNpc = require(Shared.Config.RichNpc)
local CookStates = require(Shared.Config.CookStates)
local EarlyBoost = require(Shared.Config.EarlyBoost)

-- Assets
local NpcTemplate = ServerStorage.Assets.NPCTemplate
local RichNpcFolder = ServerStorage.Assets.RichNPC
local RichUiTemplate = ReplicatedStorage.Assets.UI.RichUI
local RichParticlesTemplate = ReplicatedStorage.Assets.Particles.RichParticles
local SkewerToolTemplate = ReplicatedStorage.Assets.Tools.NPCSkewerTool

-- Parked rigs live out of workspace so they don't render or simulate. The move also destroys their
-- client replicas, which is what tears down their billboards (see SellNpcController's Destroying handler).
local PoolFolder = Instance.new("Folder")
PoolFolder.Name = "SellNpcPool"
PoolFolder.Parent = ServerStorage

-- Each faded part's real transparency, captured before the first fade so a fade-out to 1 never becomes
-- the target a later fade-in reads back.
local FADE_BASE_TRANSPARENCY_ATTR = "FadeBaseTransparency"

-- The game's shared emphasis gold, so a rich visit's toasts match the shop's and the reward's.
local RICH_LABEL = `<font color="#ffd400">RICH</font>`

-- Every line names both what the player did and what it cost, since the penalty only teaches if the two
-- connect. A pool rather than one string: this fires on every offer until the refusals decay.
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

-- Said on the first customer after the last refusal decays. Without it the penalty has a beginning and
-- no end, and a player who sat one out would read it as permanent.
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

--[[
    Sends customer NPCs to a base's sell stand. Each placed skewer owes one customer and runs its own
    visit thread (spawn -> walk -> decide -> sell/leave), retrying with fresh customers until that skewer
    sells -- so live threads track unsold skewers, and concurrent ones take distinct spots via _claimSlot.

    Visits are runtime-only but the stand is saved, so two things bridge a session: held skewers go back
    on the stand before the last save (ReturnHeldSkewersOnLastSave), and one visit is sent per remaining
    skewer on rejoin (SendCustomersForPlacedSkewers). The rich cooldown and standing refusals are saved
    for the same reason -- on a session clock a rejoin would wipe both.

    Rich customers are rolled on a timer (_rollRichVisits) rather than owed by a placement, and take the
    whole stand for one lump sum. They run the same _negotiateSale -- every customer carries an array of
    skewers, an ordinary one just carries a single -- differing only in config, dialogue prefix, and rig.
]]

--
local SellNpcManager = {
	NpcDecideEvent = Network.Event("NpcDecide"),
	NpcRichArriveEvent = Network.Event("NpcRichArrive"),
	NpcOfferEvent = Network.Event("NpcOffer"),
	NpcOfferEndEvent = Network.Event("NpcOfferEnd"),
	NpcOfferResponseEvent = Network.Event("NpcOfferResponse"),
	NpcSayEvent = Network.Event("NpcSay"),

	-- (player, offer, skewerRecords, isRich) once a customer's offer is taken and paid out.
	OnSaleCompleted = Signal.new(),
	-- (player, offer, skewerRecords, isRich, reason) when a customer leaves empty-handed. reason is
	-- "Declined" for a turned-down offer or "TimedOut" for one left to lapse.
	OnSaleDeclined = Signal.new(),

	_npcs = {}, -- [player] = { { npc = Model, tool = Tool }, ... } spawned instances, for cleanup
	_slots = {}, -- [player] = { [slotIndex] = true } occupied stand positions, so customers don't overlap
	_rng = ServerRandom.MakeRNG("SellNpc"),

	_pool = {}, -- available parked rigs, handed out and returned instead of cloning/destroying each visit
	_defaultDescription = nil, -- the template's own HumanoidDescription, re-applied to reset a released rig
	_descCache = {}, -- [userId] = HumanoidDescription, so each friend's look is fetched at most once
	_friendIds = {}, -- [player] = { userId, ... }, the owner's friend list fetched once per player
	_guaranteed = {}, -- [player] = true while their customers skip the wait and always come in interested
	_noticedRefusals = {}, -- [player] = refusals they were last told about, so the all-clear fires once
	-- [player] = true once a customer has given the free first counter-offer. Each visit thread reads
	-- SeenHaggle at its own start, so without this a stand full of them would all grant it at once.
	_grantedFirstCounter = {},
}

--
local function validatePlayer(player: Player): boolean
	return player:IsDescendantOf(Players) and player:GetAttribute("BaseId") ~= nil
end

-- Resolves the base's spawn/stand parts under workspace.Base[BaseId].Core, or nil if the player has no
-- base in the world (or it lacks the parts).
local function getBaseParts(player: Player): (BasePart?, BasePart?)
	local baseId = player:GetAttribute("BaseId")
	if not baseId then
		return nil, nil
	end

	local baseModel = workspace.Base:FindFirstChild(baseId)
	local core = baseModel and baseModel:FindFirstChild("Core")
	if not core then
		return nil, nil
	end

	return core:FindFirstChild("NPCSpawnPart"), core:FindFirstChild("NPCStandPart")
end

-- A random point on the top surface of a part, so customers don't all spawn on the same spot.
function SellNpcManager:_randomPointOn(part: BasePart): Vector3
	local size = part.Size
	local x = self._rng:NextNumber(-size.X / 2, size.X / 2)
	local z = self._rng:NextNumber(-size.Z / 2, size.Z / 2)
	return (part.CFrame * CFrame.new(x, size.Y / 2, z)).Position
end

-- Claims the lowest free stand slot, spacing concurrent customers along the stand (see STAND_SPACING).
function SellNpcManager:_claimSlot(player: Player): number
	local slots = self._slots[player]
	if not slots then
		slots = {}
		self._slots[player] = slots
	end

	local index = 0
	while slots[index] do
		index += 1
	end
	slots[index] = true
	return index
end

-- Frees a claimed stand slot. Tolerates a missing map: _cleanupPlayer may have cleared it already.
function SellNpcManager:_releaseSlot(player: Player, slot: number)
	local slots = self._slots[player]
	if slots then
		slots[slot] = nil
	end
end

-- Pre-creates the reusable customer rigs and captures the template's default appearance.
function SellNpcManager:_buildPool()
	self._defaultDescription = NpcTemplate:FindFirstChildOfClass("Humanoid"):GetAppliedDescription()

	for _ = 1, SellNpc.NPC_POOL_SIZE do
		local npc = NpcTemplate:Clone()
		CollisionManager:SetModelGroup(npc, CollisionManager.NPC)
		npc.Parent = PoolFolder
		table.insert(self._pool, npc)
	end
end

-- Hands out a parked rig, cloning only if the pool is empty. Stays in the pool folder; the caller places it.
function SellNpcManager:_acquireNpc(): Model
	local npc = table.remove(self._pool)
	if npc then
		return npc
	end

	npc = NpcTemplate:Clone()
	CollisionManager:SetModelGroup(npc, CollisionManager.NPC)
	npc.Parent = PoolFolder
	return npc
end

-- Parks a rig back in the pool (tearing down its client billboards) and resets its look, so the next
-- customer doesn't inherit the last one's friend appearance. Rigs past NPC_POOL_SIZE are destroyed.
function SellNpcManager:_releaseNpc(npc: Model)
	npc.Parent = PoolFolder

	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	humanoid:ApplyDescriptionReset(self._defaultDescription)

	if #self._pool < SellNpc.NPC_POOL_SIZE then
		table.insert(self._pool, npc)
	else
		npc:Destroy()
	end
end

-- Clones a random rich rig and dresses it with the RichUI badge and RichParticles, so it reads as the good
-- one from across the map. Not pooled: they're rare, and each rig is its own character with nothing to
-- reset. Both extras are parented server-side, so every visitor sees them. Parked out of workspace so the
-- caller can prime its fade before revealing it.
function SellNpcManager:_acquireRichNpc(): Model
	local npc = RandomUtil.GetRandomFromArray(RichNpcFolder:GetChildren(), nil, self._rng):Clone()
	CollisionManager:SetModelGroup(npc, CollisionManager.NPC)

	RichUiTemplate:Clone().Parent = npc.Head
	RichParticlesTemplate:Clone().Parent = npc.Torso

	npc.Parent = PoolFolder
	return npc
end

-- A HumanoidDescription for a random friend of the base owner, or nil (keeping the default look) if they
-- have none or the web calls fail. Both calls are throttled, so each result is cached.
function SellNpcManager:_getFriendDescription(player: Player): HumanoidDescription?
	local friendIds = self._friendIds[player]
	if not friendIds then
		friendIds = {}
		self._friendIds[player] = friendIds

		local success, pages = pcall(function()
			return Players:GetFriendsAsync(player.UserId)
		end)
		if success then
			for _, friend in pages:GetCurrentPage() do
				table.insert(friendIds, friend.Id)
			end
		end
	end

	if #friendIds == 0 then
		return nil
	end

	local userId = friendIds[self._rng:NextInteger(1, #friendIds)]
	local description = self._descCache[userId]
	if not description then
		local success, result = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(userId)
		end)
		if not success then
			return nil
		end
		description = result
		self._descCache[userId] = description
	end

	return description
end

-- Fades a rig's BaseParts and Decals. Fading in snaps to transparent and tweens back to each part's real
-- value; fading out tweens to 1 and yields until it finishes.
function SellNpcManager:_fadeNpc(npc: Model, fadeIn: boolean, duration: number)
	local tweenInfo = TweenInfo.new(duration)

	for _, descendant in npc:GetDescendants() do
		if not (descendant:IsA("BasePart") or descendant:IsA("Decal")) then
			continue
		end

		-- Captured on first touch, while still opaque: a reused rig was left at 1 by its last fade-out, so
		-- reading the live value would fade it to invisible.
		local base = descendant:GetAttribute(FADE_BASE_TRANSPARENCY_ATTR)
		if base == nil then
			base = descendant.Transparency
			descendant:SetAttribute(FADE_BASE_TRANSPARENCY_ATTR, base)
		end

		if fadeIn then
			descendant.Transparency = 1
			TweenService:Create(descendant, tweenInfo, { Transparency = base }):Play()
		else
			TweenService:Create(descendant, tweenInfo, { Transparency = 1 }):Play()
		end
	end

	if not fadeIn then
		task.wait(duration)
	end
end

-- Equips an NPCSkewerTool with the real skewer (built from `record`) welded to its Handle, so the NPC holds
-- what it took off the stand. Both stay in the Npc collision group so they don't bump players.
function SellNpcManager:_giveSkewer(npc: Model, record): (Tool, Model?)
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	local tool = SkewerToolTemplate:Clone()
	tool.Parent = workspace
	humanoid:EquipTool(tool)
	CollisionManager:SetModelGroup(tool, CollisionManager.NPC)

	local handle = tool:FindFirstChild("Handle")
	local skewer = StickModel.BuildStickModel(record)
	if skewer and handle then
		skewer:ScaleTo(StickModel.DISPLAY_SCALE)

		-- Weld rigid, seat on the Handle, then weld to it so the skewer rides the hand.
		GlobalUtil.WeldModel(skewer, false)
		skewer:PivotTo(handle.CFrame * SellNpc.SKEWER_HOLD_OFFSET)
		GlobalUtil.Weld(handle, skewer.PrimaryPart)

		for _, descendant in skewer:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.CanCollide = false
				descendant.Massless = true
				descendant.CollisionGroup = CollisionManager.NPC
			end
		end

		skewer.Parent = tool
	end

	return tool, skewer
end

-- Walks the NPC to `destination`, re-issuing MoveTo (which times out every ~8s) until it's within
-- ARRIVE_DISTANCE or WALK_TIMEOUT elapses. Yields until the walk ends.
function SellNpcManager:_walkTo(humanoid: Humanoid, destination: Vector3)
	local rootPart = humanoid.RootPart
	local startTime = os.clock()

	while os.clock() - startTime < SellNpc.WALK_TIMEOUT do
		humanoid:MoveTo(destination)
		local reached = humanoid.MoveToFinished:Wait()

		if reached or (rootPart.Position - destination).Magnitude <= SellNpc.ARRIVE_DISTANCE then
			return
		end
	end
end

-- Runs one whole visit: spawn, walk to the stand, take a skewer, decide. Yields throughout. Returns true
-- once the skewer is settled or the visit can't continue, false if the customer walked off unsold and the
-- caller should send another.
function SellNpcManager:_spawnCustomer(player: Player): boolean
	local spawnPart, standPart = getBaseParts(player)
	if not spawnPart or not standPart then
		return true
	end

	local tracked = self._npcs[player]
	if not tracked then
		tracked = {}
		self._npcs[player] = tracked
	end

	-- An explicit slot rather than a count of tracked customers, since visits run concurrently.
	local slot = self:_claimSlot(player)
	local standPosition = (standPart.CFrame * CFrame.new(slot * SellNpc.STAND_SPACING, 0, 0)).Position
	-- Zig-zag: odd slots sit a row back, so a full line's billboards separate by depth.
	if slot % 2 == 1 then
		standPosition += (spawnPart.Position - standPosition).Unit * SellNpc.STAND_ROW_OFFSET
	end

	local npc = self:_acquireNpc()
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	-- Tracked before the appearance lookup yields, so a mid-lookup _cleanupPlayer destroys it rather than
	-- orphaning it. The thread is what _runGuardedVisit matches on to hand the rig back after a throw.
	local record = { npc = npc, tool = nil, slot = slot, thread = coroutine.running() }
	table.insert(tracked, record)

	-- Both the lookup and the apply yield; if the player leaves during either, _cleanupPlayer has already
	-- destroyed the parked rig, so bail.
	local description = self:_getFriendDescription(player)
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

	-- Primed while still parked, so the rig fades in rather than popping when it's revealed below. The
	-- tween keeps playing as it walks to the stand.
	self:_fadeNpc(npc, true, SellNpc.FADE_IN_DURATION)

	local point = self:_randomPointOn(spawnPart)
	npc:PivotTo(CFrame.lookAt(point + Vector3.new(0, 3, 0), standPosition))
	npc.Parent = workspace

	-- Server-driven movement, so hand the root to the server rather than a nearby client.
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if rootPart and not rootPart.Anchored then
		rootPart:SetNetworkOwner(nil)
	end

	self:_walkTo(humanoid, standPosition)

	-- The player may have left (and their NPCs been cleaned up) during the walk.
	if npc.Parent == nil then
		return true
	end

	-- An empty stand means nothing to sell, so the customer just leaves (no retry).
	local taken = SkewerStandManager:TakeSkewer(player)
	if not taken then
		self:_walkTo(humanoid, spawnPart.Position)
		self:_despawnNpc(player, record)
		return true
	end
	-- An array of one, since a rich customer carries its whole haul here -- so the offer maths, the
	-- return-to-stand paths and cleanup all work the same either way.
	record.skewerRecords = { taken }
	record.tool, record.skewerModel = self:_giveSkewer(npc, taken)

	-- Loops through the decide pause and any haggle, until the eat animation replaces it.
	self:_playNpcAnimation(record, "Inspect")

	-- New players get turned down less often, on the same taper as their income head start. The walk-off
	-- share is what's scaled rather than INTERESTED_CHANCE itself, so 1 is the ceiling by construction. An
	-- unloaded profile rolls the normal odds, same as the spawn delay above.
	local playerData = PlayerDataManager:GetLoadedPlayerData(player)
	local declineScale = if playerData then EarlyBoost.GetDeclineScale(playerData.TotalEarned) else 1
	local interestedChance = 1 - (1 - SellNpc.INTERESTED_CHANCE) * declineScale

	-- Authoritative here; clients get the decision plus its landing timestamp and pace their own flip off
	-- the time left. A guaranteed player skips the roll -- the sale their tutorial hangs on can't miss.
	local interested = self._guaranteed[player] == true or self._rng:NextNumber() < interestedChance
	local duration = self._rng:NextNumber(SellNpc.DECIDE_DURATION_MIN, SellNpc.DECIDE_DURATION_MAX)
	record.interested = interested

	-- The dialogue variant rides along so later lines can react to the skewer in hand. Sent once: the
	-- client holds it per-NPC, and later beats fire NpcSay with a bare category.
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

	self:_stopNpcAnimation(record)
	self:_walkTo(humanoid, spawnPart.Position)
	self:_despawnNpc(player, record)
	return false
end

-- Removes one spawned customer: destroys its skewer and tool, fades the rig out, pools or destroys it, and
-- drops it from the player's list. The customer has already walked back, so it fades as it leaves.
function SellNpcManager:_despawnNpc(player: Player, record)
	-- Catch-all for leave paths that despawn without walking, so no looped track rides the rig into the pool.
	self:_stopNpcAnimation(record)

	if record.skewerModel then
		record.skewerModel:Destroy()
	end
	if record.tool then
		record.tool:Destroy()
	end

	-- Freed up front, the customer having already walked off the line, so a concurrent arrival can take
	-- the spot while this one fades.
	self:_releaseSlot(player, record.slot)

	self:_fadeNpc(record.npc, false, SellNpc.FADE_OUT_DURATION)

	-- The player may have left during the fade, in which case _cleanupPlayer already destroyed the rig.
	if record.npc.Parent == nil then
		return
	end

	-- A rich rig is its own model, not a pooled NPCTemplate: pooling it would reset it to the template's
	-- look and hand that repainted rig to the next ordinary customer.
	if record.isRich then
		record.npc:Destroy()
	else
		self:_releaseNpc(record.npc)
	end

	local tracked = self._npcs[player]
	if tracked then
		local index = table.find(tracked, record)
		if index then
			table.remove(tracked, index)
		end
	end
end

-- Stops and clears the customer's looped animation. Destroyed rather than just stopped: rigs are pooled for
-- the life of the server, so a stopped track stays loaded on the Animator -- one more per visit, forever.
function SellNpcManager:_stopNpcAnimation(record)
	local track = record.animationTrack
	if not track then
		return
	end

	record.animationTrack = nil
	track:Stop()
	track.Animation:Destroy()
	track:Destroy()
end

-- Plays a random clip from Animations.Npc[animationName] on a customer's rig, stopping whatever it was
-- playing. The server owns these rigs, so loading here replicates to everyone. Nil if there's no id yet,
-- so the flow works before the assets exist.
function SellNpcManager:_playNpcAnimation(record, animationName: string): AnimationTrack?
	self:_stopNpcAnimation(record)

	local ids = Animations.Npc[animationName]
	local animationId = ids and RandomUtil.GetRandomFromArray(ids, nil, self._rng)
	if not animationId then
		return nil
	end

	local humanoid = record.npc:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end

	local animation = Instance.new("Animation")
	animation.Name = animationName
	animation.AnimationId = animationId

	local track = animator:LoadAnimation(animation)
	track:Play()
	record.animationTrack = track
	return track
end

-- Fades the skewer's ingredients out in order over `duration`, so the food looks eaten off the stick before
-- the model is cleared. Yields until the last one fades.
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

-- Records the owner's answer to an offer. Finding the NPC among their own customers is the authority check.
-- Only the first answer counts, so a double-click is a no-op.
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

-- Turned-down offers still counting against a player: what's saved, less one per REFUSAL_DECAY seconds
-- since the last, clamped to 0..REFUSAL_PENALTY_MAX. Yields on their data.
--
-- This is what stops a declined skewer being a free reroll -- without it, declining everything would
-- eventually land near the ceiling for the cost of a wait. Both the opening offer (_negotiateSale) and the
-- replacement gap (_runVisit) scale with it.
function SellNpcManager:GetStandingSaleRefusals(player: Player): number
	local hasRefusals, refusals = PlayerDataManager:GetPlayerDataKey(player, "SaleRefusals"):await()
	if not hasRefusals or refusals.Count <= 0 then
		return 0
	end

	local forgiven = math.floor((workspace:GetServerTimeNow() - refusals.At) / SellNpc.REFUSAL_DECAY)
	return math.clamp(refusals.Count - forgiven, 0, SellNpc.REFUSAL_PENALTY_MAX)
end

-- What those refusals actually cost: the standing count less REFUSAL_GRACE, floored at 0. Everything that
-- charges the player reads this, the arrival line included. The grace separates haggling from fishing --
-- declining once is the mechanic working as taught, so charging for it would teach them never to decline.
-- Yields on their data.
function SellNpcManager:GetChargedSaleRefusals(player: Player): number
	return math.max(self:GetStandingSaleRefusals(player) - SellNpc.REFUSAL_GRACE, 0)
end

-- Moves the refusal count by delta and re-stamps the clock. Writes back the *decayed* count, not the saved
-- one -- that's what lets a single timestamp carry the decay, banking earned forgiveness rather than
-- losing it with the stamp.
-- @param player: The player whose record this adjusts
-- @param delta: How many refusals to add (or, negative, to shed)
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

-- Sheds one refusal after a sale: a refusal is only suspicion of fishing for a better roll, and a completed
-- sale disproves it. The early-out stops a sale stamping a fresh clock onto an empty record.
function SellNpcManager:ForgiveSaleRefusal(player: Player)
	if self:GetStandingSaleRefusals(player) <= 0 then
		return
	end

	self:_adjustSaleRefusals(player, -1)
end

-- Guaranteed mode: customers arrive after GUARANTEED_SPAWN_DELAY rather than a random wait, and never roll
-- uninterested. For onboarding, whose one taught sale can't stall behind a customer that walks off.
-- Everything past the decision is untouched, so the offer they're shown is a real one.
-- @param player: The player whose customers this applies to
-- @param guaranteed: true to turn it on, false (or nil) to go back to the normal rolls
function SellNpcManager:SetCustomersGuaranteed(player: Player, guaranteed: boolean?)
	self._guaranteed[player] = guaranteed or nil
end

-- Haggles the skewers and, on a deal, sells them: pays out, then the customer steps back, eats and leaves.
-- Yields throughout. Returns true once settled, false if the customer gave up and put them back.
--
-- Declining is a reroll rather than a loss, so two things keep it from being free: MAX_COUNTER_ROUNDS
-- bounds one visit, and a refusal drags the *next* customer's opening range down. The first is free and a
-- sale hands one back -- what's priced in is rerolling, not using the mechanic as taught.
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

	-- Offer, counter and cap all scale with the skewer's value; the cook state then decides how the customer
	-- haggles -- near the floor and immovable on a burnt one, high and pushable on one cooked right. A rich
	-- customer prices each skewer this way before its premium, so cooking well still pays in bulk.
	local count = #record.skewerRecords
	local value, offer = 0, 0
	local counterChance = 0
	local counterCap = 0

	-- Unforgiven refusals drag the whole opening range down. The charged count, not the standing one: the
	-- first refusal is free, so it neither moves the offer nor gets mentioned below.
	local refusals = self:GetChargedSaleRefusals(player)
	local penalty = refusals * SellNpc.REFUSAL_OFFER_PENALTY

	-- Whether a customer has countered this player before -- the first is given, not rolled for.
	local hasData, seenHaggle = PlayerDataManager:GetPlayerDataKey(player, "SeenHaggle"):await()

	for _, skewerRecord in record.skewerRecords do
		local cookState = CookStates.GetStateFromId(StickModel.GetCookStateId(skewerRecord))
		local skewerValue = StickModel.GetSellValue(skewerRecord)

		-- Floored at the skewer's plain worth, so a refused one stops earning a bonus but never sells at a
		-- loss. OfferMax is held a sliver above OfferMin, or a state already opening at 1 would converge on
		-- a single number and quote it identically every visit -- which reads as broken, not penalised.
		local offerMin = math.max(cookState.OfferMin - penalty, 1)
		local offerMax = math.max(cookState.OfferMax - penalty, offerMin + SellNpc.MIN_OFFER_SPREAD)

		value += skewerValue
		offer += skewerValue * self._rng:NextNumber(offerMin, offerMax)
		-- A normal customer carries exactly one skewer, so these land on that skewer's own numbers.
		counterChance = cookState.CounterChance
		counterCap = cookState.CounterCap
	end

	-- The rich one's bulk premium, plus its own counter chance and cap: a mixed haul has no single cook
	-- state for the per-skewer values above to mean anything.
	if isRich then
		offer *= RichNpc.BULK_MULTIPLIER
		counterChance = RichNpc.COUNTER_CHANCE
		counterCap = RichNpc.OFFER_CAP_FACTOR
	end
	offer = math.round(offer)

	local accepted = false
	local timedOut = false
	local counterRounds = 0

	-- The offer's billboard is no help to a player off at the grill, and the window shuts after
	-- OFFER_TIMEOUT, so a toast brings them back. Opening offers only -- a counter means they're here.
	-- A player carrying refusals is told why the offer dropped, and told again when the last one decays.
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

		-- The boosted figure, since that's what lands in their balance -- quoting the bare offer would have
		-- a boosted player watch the counter jump past the number they agreed to. The badge carries the
		-- boosts too, so both describe the same number. Re-derived each round, so a counter moves them.
		local payout = CurrencyManager:GetBoostedAmount(player, offer)
		local bonus = math.round((payout / value - 1) * 100)
		self.NpcOfferEvent:FireClient(player, npc, payout, count, bonus)

		-- Never waits forever: an ignored offer would stall every later customer. Nudges run on counter
		-- rounds too, unlike the opening toast -- declining says they were here, not that they stayed.
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
		-- The player's first counter ever is given, not rolled for. Onboarding can't teach declining --
		-- it takes the Decline button off the offer it walks them to -- so their first real no would be
		-- answered on the cook state's own 30%, and going unanswered would teach them no is simply a loss.
		--
		-- Gated on hasData, or a profile that failed to load gets a free counter every visit for the
		-- session. The latch is the other half: sibling visits each read their own seenHaggle at the top,
		-- so the saved key alone can't stop several granting the same counter at once.
		local firstCounter = hasData and not seenHaggle and not self._grantedFirstCounter[player]
		if not firstCounter and not RandomUtil.RollChance(counterChance, self._rng) then
			break
		end
		counterRounds += 1

		-- Spent on grant, not on settle, so later rounds of this haggle are rolled for like any other. The
		-- latch goes up *before* the write, since the write yields and a sibling would find it going spare.
		if firstCounter then
			seenHaggle = true
			self._grantedFirstCounter[player] = true
			PlayerDataManager:SetPlayerDataKey(player, "SeenHaggle", true)

			-- The bubble and sound show something happened; this says what -- in terms of what they did,
			-- since naming it "haggling" only explains it to someone who already knows the mechanic.
			NotificationManager:NotifyNormal(player, {
				Text = "You said no, so they're offering more! Declining can get you a better price",
				Duration = 5,
				Sound = "Notify",
				Effect = "Success",
			})
		end

		-- A share of the *remaining* headroom rather than a flat slice of value, so a haggle decelerates
		-- into the cap instead of marching at it in equal strides and needing to be clamped off it.
		local headroom = value * counterCap - offer
		offer = math.round(
			offer + headroom * self._rng:NextNumber(config.COUNTER_INCREASE_MIN, config.COUNTER_INCREASE_MAX)
		)
		counterChance *= SellNpc.COUNTER_CHANCE_FALLOFF

		self.NpcSayEvent:FireAllClients(npc, `{prefix}CounterOffer`)

		-- The first counter has its own sound; later ones pitch up off a shared one, so a customer pushed a
		-- third time sounds like it. Positional and heard by everyone, matching the bubble.
		SoundManager:PlaySound("All", if counterRounds == 1 then "Haggle1" else "Haggle2", npc:GetPivot(), {
			PlaybackSpeed = 1 + math.max(counterRounds - 2, 0) * SellNpc.HAGGLE_PITCH_STEP,
		})
	end

	self.NpcOfferEndEvent:FireClient(player, npc)

	if not accepted then
		-- No deal: the skewers go back on the stand and the customer leaves, so another comes for them.
		self.NpcSayEvent:FireAllClients(npc, `{prefix}PlayerDeclined`)
		StatsManager:RecordSaleDeclined(player)
		self.OnSaleDeclined:Fire(player, offer, record.skewerRecords, isRich, if timedOut then "TimedOut" else "Declined")

		-- Only a deliberate refusal counts: a lapse already cost them OFFER_TIMEOUT and wasn't a choice.
		if not timedOut then
			self:RecordSaleRefusal(player)
		end

		-- A deliberate decline needs no telling; a lapse does. No error effect -- they lost the sale, but
		-- didn't do anything wrong.
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

		self:_stopNpcAnimation(record)
		self:_walkTo(humanoid, spawnPart.Position)
		self:_despawnNpc(player, record)
		return false
	end

	-- Read *before* the payout: the early boost decays against TotalEarned, which IncrementCurrency bumps,
	-- so asking afterwards would price this sale's bonus off a figure this sale already moved. Display only.
	local payout = CurrencyManager:GetBoostedAmount(player, offer)

	-- Handed the plain offer, not the payout above -- applying boosts is IncrementCurrency's own job, and
	-- a pre-boosted figure would boost the sale twice.
	CurrencyManager:IncrementCurrency(player, offer, "SkewerSale")

	-- The commit point: cleared here rather than after the eat, since both paths that put a customer's
	-- skewers back read the record, and either landing mid-eat would return what was just paid for.
	local soldRecords = record.skewerRecords
	record.skewerRecords = nil

	StatsManager:RecordSaleCompleted(player, soldRecords)
	self.OnSaleCompleted:Fire(player, offer, soldRecords, isRich)

	-- Down here rather than with the payout because it yields on their data, which is only safe once the
	-- record's skewers have been cleared above.
	self:ForgiveSaleRefusal(player)

	-- Cash bursts off the customer to the seller, so everyone nearby sees the sale land. The payout lets
	-- each projectile pop a "+X" on arrival, adding up to the jump on the currency counter.
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

	-- Step back to a randomized spot to eat, so finished customers scatter into a loose crowd rather than
	-- lining up behind the stand.
	local backDir = (spawnPart.Position - standPosition).Unit
	local sideDir = Vector3.new(-backDir.Z, 0, backDir.X) -- perpendicular, on the ground plane
	local eatPosition = standPosition
		+ backDir * self._rng:NextNumber(SellNpc.EAT_BACK_DISTANCE_MIN, SellNpc.EAT_BACK_DISTANCE_MAX)
		+ sideDir * self._rng:NextNumber(-SellNpc.EAT_SPREAD, SellNpc.EAT_SPREAD)
	self:_walkTo(humanoid, eatPosition)
	if npc.Parent == nil then
		return true
	end

	-- Face a random direction while eating, so eaters don't all stare the same way.
	npc:PivotTo(CFrame.new(npc:GetPivot().Position) * CFrame.Angles(0, self._rng:NextNumber(0, math.pi * 2), 0))

	self:_playNpcAnimation(record, "Eat")
	self.NpcSayEvent:FireAllClients(npc, `{prefix}Eating`)

	-- The ingredients fade off the stick over the eat, so it looks consumed before it's cleared. A rich
	-- customer only ever built the one it's holding; the rest of its haul it just carries off.
	if record.skewerModel then
		self:_eatSkewerIngredients(record.skewerModel, SellNpc.EAT_DURATION)
	else
		task.wait(SellNpc.EAT_DURATION)
	end
	if npc.Parent == nil then
		return true
	end

	-- Eaten, so the model it was holding goes too.
	if record.skewerModel then
		record.skewerModel:Destroy()
		record.skewerModel = nil
	end
	if record.tool then
		record.tool:Destroy()
		record.tool = nil
	end

	self.NpcSayEvent:FireAllClients(npc, `{prefix}Leaving`)
	self:_stopNpcAnimation(record)
	self:_walkTo(humanoid, spawnPart.Position)
	self:_despawnNpc(player, record)
	return true
end

-- Runs one visit (_spawnCustomer / _spawnRichCustomer) with its failure contained. A visit yields across a
-- rig, a tool, a stand slot and the skewers it took, and a throw would otherwise strand all four for the
-- life of the server. Returns true after a failure -- settled, so a bad visit can't retry into a loop.
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

-- Handles one owed sale on its own thread: wait, send a customer, and keep sending one (after a retry gap)
-- until one buys or the player leaves. One thread lives per unsold skewer.
function SellNpcManager:_runVisit(player: Player)
	-- A guaranteed player's customer is on its way as soon as the skewer lands.
	if self._guaranteed[player] then
		task.wait(SellNpc.GUARANTEED_SPAWN_DELAY)
	else
		-- New players wait less, on the same taper as their income head start. An unloaded profile waits
		-- the full delay rather than being assumed to be at zero earned, as CurrencyManager does.
		local playerData = PlayerDataManager:GetLoadedPlayerData(player)
		local scale = if playerData then EarlyBoost.GetSpawnDelayScale(playerData.TotalEarned) else 1
		task.wait(self._rng:NextNumber(SellNpc.SPAWN_DELAY_MIN, SellNpc.SPAWN_DELAY_MAX) * scale)
	end

	if not validatePlayer(player) then
		return
	end

	-- Refusals stretch the gap before the replacement arrives, so declining costs selling time on top of
	-- the offer penalty. Read fresh each pass, so it decays while a player who's stopped declining waits.
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

-- Sends one customer per skewer already on the stand. This is what picks a stall back up after a rejoin:
-- the stand's contents persist but its visit threads don't. Each opens with its own delay, so they trickle in.
function SellNpcManager:SendCustomersForPlacedSkewers(player: Player)
	local placed = SkewerStandManager:GetPlacedSkewerCount(player)

	for _ = 1, placed do
		task.spawn(function()
			self:_runVisit(player)
		end)
	end
end

-- Sends one rich customer: a random RichNPC rig takes every skewer on the stand and haggles over the lot as
-- one sum. Yields throughout. No retry loop -- a refusal puts the stand back and the roll must come round again.
function SellNpcManager:_spawnRichCustomer(player: Player)
	local spawnPart, standPart = getBaseParts(player)
	if not spawnPart or not standPart then
		return
	end

	local tracked = self._npcs[player]
	if not tracked then
		tracked = {}
		self._npcs[player] = tracked
	end

	-- The ordinary customers' slot allocator, so a rich one lines up beside them rather than inside them.
	local slot = self:_claimSlot(player)
	local standPosition = (standPart.CFrame * CFrame.new(slot * SellNpc.STAND_SPACING, 0, 0)).Position
	if slot % 2 == 1 then
		standPosition += (spawnPart.Position - standPosition).Unit * SellNpc.STAND_ROW_OFFSET
	end

	local npc = self:_acquireRichNpc()
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	-- Tracked before anything yields: _rollRichVisits reads it to know one is already here, _cleanupPlayer
	-- destroys it on a mid-visit leave, and _runGuardedVisit matches its thread to release the rig.
	local record = { npc = npc, tool = nil, slot = slot, isRich = true, thread = coroutine.running() }
	table.insert(tracked, record)

	-- A rich customer is its own character, so there's no appearance lookup to yield on before the fade.
	self:_fadeNpc(npc, true, SellNpc.FADE_IN_DURATION)

	local point = self:_randomPointOn(spawnPart)
	npc:PivotTo(CFrame.lookAt(point + Vector3.new(0, 3, 0), standPosition))
	npc.Parent = workspace

	-- Server-driven movement, so hand the root to the server rather than a nearby client.
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if rootPart and not rootPart.Anchored then
		rootPart:SetNetworkOwner(nil)
	end

	-- Rare enough to be worth pulling the player back to watch. The offer toast in _negotiateSale is a
	-- separate beat, about answering in time.
	NotificationManager:NotifyNormal(player, {
		Text = `A {RICH_LABEL} customer is heading to your stand!`,
		Duration = 3,
		Sound = "RichSpawn",
	})

	self:_walkTo(humanoid, standPosition)

	if npc.Parent == nil then
		return
	end

	-- One write. The stand was stocked when the roll landed, but can have emptied during the walk.
	local taken = SkewerStandManager:TakeAllSkewers(player)
	if #taken == 0 then
		self:_walkTo(humanoid, spawnPart.Position)
		self:_despawnNpc(player, record)
		return
	end
	record.skewerRecords = taken

	-- Carries only the pick of the haul, six welded into one hand reading as a mess; the offer line says
	-- how many it's actually buying.
	local best = taken[1]
	local bestValue = StickModel.GetSellValue(best)
	for index = 2, #taken do
		local skewerValue = StickModel.GetSellValue(taken[index])
		if skewerValue > bestValue then
			best, bestValue = taken[index], skewerValue
		end
	end
	record.tool, record.skewerModel = self:_giveSkewer(npc, best)

	self:_playNpcAnimation(record, "Inspect")

	-- No decide beat: a rich customer always buys, being gated behind a long roll -- a walk-off would burn
	-- the event and hand the stand back for nothing. The client is still told, since that builds its UI.
	self.NpcRichArriveEvent:FireAllClients(npc)
	task.wait(self._rng:NextNumber(RichNpc.APPRAISE_DURATION_MIN, RichNpc.APPRAISE_DURATION_MAX))

	if npc.Parent == nil then
		return
	end

	-- On a refusal the haul returns to a stand with no visits left on it -- they all resolved when it went
	-- empty -- so send one per skewer or it sits dead.
	if not self:_negotiateSale(player, npc, record, humanoid, spawnPart, standPart, standPosition) then
		for _ = 1, #taken do
			task.spawn(function()
				self:_runVisit(player)
			end)
		end
	end
end

-- One pass of the rich-customer roll over every player. The checks run cheapest first, so the data reads
-- only happen for someone who's actually in line for one.
function SellNpcManager:_rollRichVisits()
	for _, player in Players:GetPlayers() do
		if not validatePlayer(player) then
			continue
		end

		-- One at a time -- one already at the stand holds the stock the next would want. Read off the
		-- tracked customers rather than a flag, so an errored visit can't leave it stuck set.
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

		-- In their data on the synced clock, not a session timer, so rejoining or hopping servers doesn't
		-- hand out a fresh rich customer.
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

-- Sends a rich customer now, skipping the timer, chance roll, cooldown and MIN_SKEWERS. Fired off the
-- command bar. The checks it keeps are the ones that would leave the visit meaningless, not merely unlikely.
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

	-- Under MIN_SKEWERS is fine -- that's the gate being skipped -- but an empty stand would have it walk
	-- in and straight back out.
	if SkewerStandManager:GetPlacedSkewerCount(player) == 0 then
		return false, `{player.Name}'s stand is empty, so there's nothing to buy.`
	end

	-- Stamped as the roll stamps it, so the timer can't send a second one on top. Not read here, so the
	-- command can still be re-run straight away.
	PlayerDataManager:SetPlayerDataKey(player, "LastRichVisit", workspace:GetServerTimeNow())

	task.spawn(function()
		self:_runGuardedVisit(player, function()
			self:_spawnRichCustomer(player)
		end)
	end)

	return true
end

-- Tears down a leaving player's customers. Rigs are destroyed rather than pooled: a visit thread may still
-- be mid-walk, and clearing the parent is what its `npc.Parent == nil` guards bail on.
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

	-- Drop their friends' looks unless someone still here shares them, or the cache grows to hold a
	-- description for every friend of everyone who has ever joined.
	local friendIds = self._friendIds[player]
	self._friendIds[player] = nil
	if friendIds then
		local stillWanted = {}
		for _, otherIds in self._friendIds do
			for _, userId in otherIds do
				stillWanted[userId] = true
			end
		end

		for _, userId in friendIds do
			local description = self._descCache[userId]
			if description and not stillWanted[userId] then
				self._descCache[userId] = nil
				description:Destroy()
			end
		end
	end

	self._slots[player] = nil
	self._guaranteed[player] = nil
	self._noticedRefusals[player] = nil
	self._grantedFirstCounter[player] = nil
end

-- Returns held skewers to the stand just before the last save. A customer takes them off the moment it
-- picks them up, so without this, leaving mid-decision deletes them for good -- the whole stand if a rich
-- customer took the lot.
--
-- A pre-cleanup callback because that's the one hook covering every way a session ends (leaving, shutdown,
-- session handover) where _cleanupPlayer covers only the first, and because it runs before this manager's
-- own PlayerRemoving handler, so the customers are still tracked.
--
-- Mutates `data` directly and never yields, as the hook requires: the player may already be gone from
-- Players, which SetPlayerDataKey needs.
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
	self:_buildPool()

	-- One skewer, one customer: each placement runs its own visit thread, so they come concurrently.
	SkewerStandManager.OnSkewerPlaced:Connect(function(player: Player)
		task.spawn(function()
			self:_runVisit(player)
		end)
	end)

	-- Visits are owed by placements but the stand outlives the session, so without this a full stall comes
	-- back to nobody visiting it. Waits on the base, which is what says the stand exists.
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:SendCustomersForPlacedSkewers(player)
	end)

	-- A player assigned a base before this manager started won't fire the signal above, so sweep them.
	-- Sending yields on their data, so keep it off the main thread.
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("BaseId") then
			task.spawn(function()
				self:SendCustomersForPlacedSkewers(player)
			end)
		end
	end

	-- Rolled on a timer rather than owed by a placement, so a stocked stand can draw one while the player
	-- is off at the grill. Waits first, so the first roll doesn't fire before anyone has a base.
	task.spawn(function()
		while true do
			task.wait(RichNpc.CHECK_INTERVAL)
			self:_rollRichVisits()
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
