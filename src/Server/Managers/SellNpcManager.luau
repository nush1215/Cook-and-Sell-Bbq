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

-- Assets
local NpcTemplate = ServerStorage.Assets.NPCTemplate
local RichNpcFolder = ServerStorage.Assets.RichNPC
local RichUiTemplate = ReplicatedStorage.Assets.UI.RichUI
local RichParticlesTemplate = ReplicatedStorage.Assets.Particles.RichParticles
local SkewerToolTemplate = ReplicatedStorage.Assets.Tools.NPCSkewerTool

-- Parked (unused) customer rigs live here rather than in workspace, so they don't render or simulate.
-- Moving a rig out of workspace into here also destroys its client-side replica, which is what tears
-- down its billboards on despawn (see SellNpcController's npc.Destroying handler).
local PoolFolder = Instance.new("Folder")
PoolFolder.Name = "SellNpcPool"
PoolFolder.Parent = ServerStorage

-- Attribute each faded part carries its real (opaque) transparency under, captured before the first fade, so
-- a fade-out to 1 never becomes the target a later fade-in reads back.
local FADE_BASE_TRANSPARENCY_ATTR = "FadeBaseTransparency"

-- The word tinted gold wherever a rich customer's toasts say it -- the same emphasis colour the shop and
-- reward toasts use -- so a rich visit doesn't read as an ordinary one with a louder word in it.
local RICH_LABEL = `<font color="#ffd400">RICH</font>`

-- The arrival toast for a player carrying standing sale refusals. Every line names both what they did and
-- what it cost, because the penalty only teaches anything if they can connect the two -- one saying the
-- offer is low without saying why is just the numbers quietly getting worse. Written as a pool rather than
-- one string because this fires on every offer until the refusals decay, and the same sentence four
-- customers running reads as a bug in the toast rather than a state the player is in.
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

-- Said once when the last standing refusal decays, on the first customer to arrive after it. The other half
-- of the loop: without it the penalty has a beginning and no end, so a player who sat one out has no way to
-- know it lifted and reasonably reads it as permanent.
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
    Sends customer NPCs to a base's sell stand. When a cooked skewer is placed (SkewerStandManager fires
    OnSkewerPlaced), one customer is owed: after a random delay it spawns at the base's Core.NPCSpawnPart,
    walks to Core.NPCStandPart, and ends up holding an NPCSkewerTool welded into its hand.

    Spawns are per skewer, not per store: each placement runs its own visit thread (spawn -> walk ->
    decide -> sell/leave), so a burst of placements sends several customers at once -- up to one per
    skewer on the stand (MAX_SKEWERS). A visit keeps drawing a new customer (after a retry gap) until
    that skewer sells, so the number of live threads tracks the number of unsold skewers.

    Concurrent customers stand at distinct spots along the stand via the slot allocator (_claimSlot),
    since their arrival order isn't serialized any more.

    None of that survives a session -- the visit threads and the customers they're driving are pure
    runtime state -- but the stand they work off is saved, so two things bridge the gap. On the way out,
    the skewers a customer is holding go back on the stand before the profile's last save
    (ReturnHeldSkewersOnLastSave), since they were taken off it the moment it picked them up. On the way
    back in, one visit is sent per skewer still on the stand (SendCustomersForPlacedSkewers), or a stall
    left stocked would sit there with nobody coming for it. The rich customer's cooldown is saved for the
    same reason: on a session clock, rejoining or hopping servers would hand out a fresh one. A player's
    recent refusals are saved on that same reasoning -- they're what makes declining an offer cost anything
    (GetStandingSaleRefusals), so a session timer would hand out a clean slate for the price of a rejoin.

    Rich customers are the other kind: rare bulk buyers rolled for on a timer (_rollRichVisits) rather
    than owed by a placement, and gated on the stand actually holding enough to be worth the trip. One
    takes the whole stand at once and haggles over a single lump sum, so its visit runs the same
    _negotiateSale as an ordinary customer -- every customer carries an array of skewers, and an ordinary
    one just carries an array of one. What differs is which config the offer maths reads, which dialogue
    prefix its lines come from, and that a rich rig is its own model rather than a pooled NPCTemplate.
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
	-- [player] = true once one of their customers has given the free first counter-offer. One visit thread
	-- runs per unsold skewer and each reads SeenHaggle at its own start, so without this a stand full of
	-- concurrent visits all read it unset, all give the free counter, and all fire the toast explaining it.
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

-- Claims the lowest free stand slot for a player and marks it occupied. Slots space concurrent customers
-- out along the stand (see STAND_SPACING) so they don't stand inside each other.
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

-- Frees a previously claimed stand slot. Tolerant of a missing map, since _cleanupPlayer may have already
-- cleared it out from under a customer whose player left.
function SellNpcManager:_releaseSlot(player: Player, slot: number)
	local slots = self._slots[player]
	if slots then
		slots[slot] = nil
	end
end

-- Pre-creates the pool of reusable customer rigs and captures the template's default appearance. Each rig
-- is collision-grouped once here and parked in the pool folder until a customer needs it.
function SellNpcManager:_buildPool()
	self._defaultDescription = NpcTemplate:FindFirstChildOfClass("Humanoid"):GetAppliedDescription()

	for _ = 1, SellNpc.NPC_POOL_SIZE do
		local npc = NpcTemplate:Clone()
		CollisionManager:SetModelGroup(npc, CollisionManager.NPC)
		npc.Parent = PoolFolder
		table.insert(self._pool, npc)
	end
end

-- Hands out a parked rig for a new customer, cloning a fresh one only if the pool is empty (a busy server
-- past NPC_POOL_SIZE concurrent customers). The rig stays in the pool folder; the caller positions it.
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

-- Returns a rig to the pool: parks it back in the pool folder (which tears down its client billboards) and
-- resets it to the default look so the next customer doesn't inherit the last one's friend appearance. Rigs
-- past NPC_POOL_SIZE are destroyed instead, so the pool doesn't grow unbounded after a rush.
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

-- Clones one of the rich customer rigs at random and dresses it up: the RichUI badge over its head and the
-- RichParticles attachment on its torso, so it reads as the good one from across the map. These aren't
-- pooled like the ordinary customers: they're rare enough that one clone per visit costs nothing, and each
-- rig is its own character rather than a template to be dressed, so there's nothing to reset. Both are
-- parented server-side, so everyone at the base sees who's turned up -- the decide and offer billboards
-- only live on the client because their buttons have to sit in PlayerGui to take clicks, and neither of
-- these has any. Parked out of workspace so the caller can prime its fade before revealing it.
function SellNpcManager:_acquireRichNpc(): Model
	local npc = RandomUtil.GetRandomFromArray(RichNpcFolder:GetChildren(), nil, self._rng):Clone()
	CollisionManager:SetModelGroup(npc, CollisionManager.NPC)

	RichUiTemplate:Clone().Parent = npc.Head
	RichParticlesTemplate:Clone().Parent = npc.Torso

	npc.Parent = PoolFolder
	return npc
end

-- Returns a HumanoidDescription for one of the base owner's Roblox friends (picked at random), or nil if the
-- player has no friends or the web calls fail -- in which case the customer keeps the default look. The
-- friend list is fetched once per player and each friend's description once per userId, since both are
-- throttled web calls.
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

-- Fades a rig's transparency across all its BaseParts and Decals (body, face and accessories). Fading in
-- snaps everything to fully transparent and tweens back to each part's real transparency; fading out tweens
-- everything to fully transparent and yields until the fade finishes.
function SellNpcManager:_fadeNpc(npc: Model, fadeIn: boolean, duration: number)
	local tweenInfo = TweenInfo.new(duration)

	for _, descendant in npc:GetDescendants() do
		if not (descendant:IsA("BasePart") or descendant:IsA("Decal")) then
			continue
		end

		-- Remember the part's real transparency the first time it's touched (right after its appearance is
		-- applied, so it's the opaque value). A reused rig was left at 1 by its last fade-out, so reading the
		-- live value here instead would fade it to 1 -- invisible.
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

-- Equips a fresh NPCSkewerTool and welds the real skewer (built from `record`) onto its Handle, so the NPC
-- holds the actual skewer it took off the stand. Returns the tool and the skewer model. Both are kept in
-- the Npc collision group so they don't bump players or other NPCs.
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

		-- Weld the skewer rigid, seat it on the Handle, then weld it to the Handle so it rides the hand.
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

-- Spawns one customer: clones the NPC at the base's spawn part, walks it to the stand, hands it a skewer,
-- and runs the decide beat. Yields through the whole visit. Returns true once the skewer is settled (a
-- customer was interested, or the visit can't continue) and false when the customer walked off unsold, so
-- the caller sends another.
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

	-- Its own spot along the stand so it doesn't stand inside customers already there. Visits run
	-- concurrently now, so claim an explicit slot rather than counting tracked customers.
	local slot = self:_claimSlot(player)
	local standPosition = (standPart.CFrame * CFrame.new(slot * SellNpc.STAND_SPACING, 0, 0)).Position
	-- Zig-zag: odd slots sit a row back toward the customer side so a full line's billboards separate
	-- by depth instead of stacking flat.
	if slot % 2 == 1 then
		standPosition += (spawnPart.Position - standPosition).Unit * SellNpc.STAND_ROW_OFFSET
	end

	local npc = self:_acquireNpc()
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	-- Track it before the appearance lookup yields, so a mid-lookup _cleanupPlayer finds and destroys it
	-- rather than leaving it orphaned in the world. The thread is what _runGuardedVisit matches on to
	-- hand the rig back if this visit throws partway through.
	local record = { npc = npc, tool = nil, slot = slot, thread = coroutine.running() }
	table.insert(tracked, record)

	-- Dress the customer as one of the base owner's friends (if they have any). The lookup and the apply
	-- both yield; if the player leaves during either, _cleanupPlayer destroys the parked rig, so bail.
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

	-- Prime the fade-in (snaps the rig transparent) while it's still parked, then reveal it in the world
	-- so it fades in rather than popping. The tween keeps playing as the customer walks to the stand.
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

	-- Take the real skewer off the stand to consider. If it's empty by now there's nothing to sell, so the
	-- customer just leaves (no retry).
	local taken = SkewerStandManager:TakeSkewer(player)
	if not taken then
		self:_walkTo(humanoid, spawnPart.Position)
		self:_despawnNpc(player, record)
		return true
	end
	-- An array of one: a rich customer carries its whole haul here, so everything downstream (the offer
	-- maths, the return-to-stand paths, cleanup) works the same either way.
	record.skewerRecords = { taken }
	record.tool, record.skewerModel = self:_giveSkewer(npc, taken)

	-- Inspect the skewer while deciding. It loops, so it carries through the decide pause and any haggle
	-- until it's replaced by the eat animation or stopped when the customer leaves.
	self:_playNpcAnimation(record, "Inspect")

	-- The customer now pauses to decide whether to buy. The outcome is authoritative here (the purchase
	-- phase reads record.interested); clients get the decision plus the timestamp it lands at and pace
	-- their own flip off the time left. The server waits the same duration so its walk-away stays in step.
	-- A guaranteed player's customer skips the roll: the one sale their tutorial hangs on can't be the
	-- one that comes up uninterested and walks off.
	local interested = self._guaranteed[player] == true or self._rng:NextNumber() < SellNpc.INTERESTED_CHANCE
	local duration = self._rng:NextNumber(SellNpc.DECIDE_DURATION_MIN, SellNpc.DECIDE_DURATION_MAX)
	record.interested = interested

	-- The dialogue variant rides along so every line this customer says from here on can react to the
	-- skewer in its hand -- how well it cooked, or the mutation on it if it has one, which outranks the
	-- cook state. Sent once because the client holds it per-NPC -- the later beats fire NpcSay with a
	-- bare category and it colours them itself.
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

	-- An interested customer haggles over the skewer with the owner, and buys it if they take a deal.
	if interested then
		return self:_negotiateSale(player, npc, record, humanoid, spawnPart, standPart, standPosition)
	end

	-- An uninterested customer holds the verdict a beat, puts the skewer back on the stand (and out of its
	-- hand), then walks back out empty-handed and despawns; the caller sends another for the skewer.
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

-- Removes one spawned customer: destroys its held skewer and tool, fades the rig out, returns it to the
-- pool (or destroys it, for a rich customer's own rig), and drops it from the player's list. The customer
-- has already walked back to the spawn point by now, so it fades out as it leaves.
function SellNpcManager:_despawnNpc(player: Player, record)
	-- Catch-all in case a leave path despawns without walking: don't let a looped track ride the rig back
	-- into the pool and resume when it's reused.
	self:_stopNpcAnimation(record)

	if record.skewerModel then
		record.skewerModel:Destroy()
	end
	if record.tool then
		record.tool:Destroy()
	end

	-- Free the stand spot up front (the customer has already walked back off the line) so a concurrent
	-- arrival can take it while this one fades out.
	self:_releaseSlot(player, record.slot)

	self:_fadeNpc(record.npc, false, SellNpc.FADE_OUT_DURATION)

	-- The player may have left during the fade, in which case _cleanupPlayer already destroyed the rig and
	-- cleared the list -- nothing left to pool or untrack.
	if record.npc.Parent == nil then
		return
	end

	-- A rich customer's rig is its own model cloned for the visit, not one of the pooled NPCTemplates, so
	-- it's destroyed rather than parked. Pooling it would reset it to the template's look and then hand
	-- that repainted rig to the next ordinary customer.
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

-- Stops and clears the customer's current looped animation (eat/inspect), so it doesn't keep playing as they
-- walk off or ride the rig back into the pool. A no-op if nothing's playing.
--
-- Destroyed, not just stopped: the rigs are pooled for the life of the server and every visit loads a fresh
-- track, so a stopped track left on the Animator stays loaded there -- one more per visit, forever.
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

-- Plays one of a customer's animations (a random clip from Animations.Npc[animationName]) on its rig. The
-- server owns these rigs, so loading it here replicates to everyone. The clips loop, so it stops whatever
-- track the customer is already playing first and stashes the new one on the record to stop later. Returns
-- the track, or nil if there's no id yet, so the flow works before the assets exist.
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

-- Fades the skewer's ingredients out one after another over `duration`, so the food looks eaten off the
-- stick before the model is cleared. Mirrors _fadeNpc's transparency tween. Yields until the last fades.
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

-- Records the owner's answer to a customer's offer. Finding the NPC among the player's own customers is the
-- authority check -- you can only answer a customer standing at your base. Only the first answer per offer
-- counts, so a double-click is a no-op.
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

-- How many of this player's turned-down offers still count against them: what's saved, less one for every
-- REFUSAL_DECAY seconds since the last, clamped into 0..REFUSAL_PENALTY_MAX. Yields on their data.
--
-- This is what stops a declined skewer being a free reroll. It goes straight back on the stand and another
-- customer comes for it, so without a memory of the refusal that customer would price it from the full
-- range again and declining everything would eventually land near the ceiling for the cost of a wait.
-- Both the opening offer (_negotiateSale) and the gap before the replacement arrives (_runVisit) scale
-- with it -- see SellNpc's REFUSAL_ block for the numbers.
function SellNpcManager:GetStandingSaleRefusals(player: Player): number
	local hasRefusals, refusals = PlayerDataManager:GetPlayerDataKey(player, "SaleRefusals"):await()
	if not hasRefusals or refusals.Count <= 0 then
		return 0
	end

	local forgiven = math.floor((workspace:GetServerTimeNow() - refusals.At) / SellNpc.REFUSAL_DECAY)
	return math.clamp(refusals.Count - forgiven, 0, SellNpc.REFUSAL_PENALTY_MAX)
end

-- What those standing refusals actually charge the player: their count less SellNpc.REFUSAL_GRACE, floored
-- at 0. Everything that costs them something reads this rather than the standing count, the arrival line
-- included -- being told offers are down while nothing is down is worse than not being told at all.
--
-- The grace is what separates a player haggling from a player fishing. Declining once is the mechanic
-- working exactly as the counter-offer toast taught it, and the counter roll going against them isn't
-- something they did; charging for it teaches them not to decline at all. Repeated refusals still land.
-- Yields on their data.
function SellNpcManager:GetChargedSaleRefusals(player: Player): number
	return math.max(self:GetStandingSaleRefusals(player) - SellNpc.REFUSAL_GRACE, 0)
end

-- Moves the player's refusal count by delta and re-stamps the clock. The count written back is the
-- *decayed* one rather than whatever was saved, which is what lets a single timestamp carry the decay:
-- every write banks the forgiveness already earned into the count instead of losing it with the stamp.
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

-- Sheds one refusal for a player who just sold something. A refusal is only ever suspicion that they're
-- turning offers down to fish for a better opening roll, and a completed sale is the plainest evidence
-- they aren't -- so making one buys the goodwill back rather than leaving them to sit out a penalty they
-- have already disproved. Without it, declining a single lowball and then selling the next five skewers
-- still costs the full REFUSAL_DECAY.
--
-- The early-out is what keeps a sale from stamping a fresh clock onto a record with nothing on it, which
-- would hand a clean player a timestamp for their next refusal to decay from.
function SellNpcManager:ForgiveSaleRefusal(player: Player)
	if self:GetStandingSaleRefusals(player) <= 0 then
		return
	end

	self:_adjustSaleRefusals(player, -1)
end

-- Puts the player's customers into (or out of) guaranteed mode: while it's on, a customer sent to them comes
-- after SellNpc.GUARANTEED_SPAWN_DELAY instead of a random one, and never rolls uninterested. Set
-- for a player still in their onboarding, whose one taught sale can't be allowed to stall behind a slow arrival
-- or a customer that walks off without ever making an offer. Everything past the decision is untouched -- the
-- offer is priced and haggled exactly as normal, so what they're shown is a real one.
-- @param player: The player whose customers this applies to
-- @param guaranteed: true to turn it on, false (or nil) to go back to the normal rolls
function SellNpcManager:SetCustomersGuaranteed(player: Player, guaranteed: boolean?)
	self._guaranteed[player] = guaranteed or nil
end

-- Haggles the skewers with the owner and, if they take a deal, sells them: pays out, then the customer steps
-- back, eats and leaves. Yields through the whole exchange. Returns true once the skewers are settled, or false
-- if the customer gave up and put them back, so the queue sends another for them.
--
-- Declining is a reroll, not a loss -- the skewers go back on the stand and another customer comes -- so the
-- two things that keep it from being free both live here: MAX_COUNTER_ROUNDS bounds how far one customer can
-- be pushed in a single visit, and a refusal is recorded against the player to drag the *next* customer's
-- opening range down (GetChargedSaleRefusals). Free for the first one, though, and a sale hands one back --
-- what's being priced in is a player rerolling, not a player using the mechanic the stand taught them.
function SellNpcManager:_negotiateSale(
	player: Player,
	npc: Model,
	record,
	humanoid: Humanoid,
	spawnPart: BasePart,
	standPart: BasePart,
	standPosition: Vector3
): boolean
	-- A rich customer says its own lines and haggles off its own numbers. Both are settled once here, so the
	-- beats below read as one exchange rather than a branch at every step.
	local isRich = record.isRich
	local prefix = if isRich then "RichNPC" else "NPC"
	local config = if isRich then RichNpc else SellNpc

	-- A sauced skewer is worth a multiple of its ingredients and a badly cooked one a fraction, so every
	-- offer, counter and the cap below scale with it. How the customer haggles comes off the cook state
	-- on top of that: they open near the floor on a burnt or raw skewer and barely budge from there,
	-- and open high and push happily on one that's been cooked right. A rich customer prices every skewer
	-- in its haul that same way before its premium goes on, so cooking well still pays in a bulk sale.
	local count = #record.skewerRecords
	local value, offer = 0, 0
	local counterChance = 0
	local counterCap = 0

	-- Every offer this player has turned down and not yet had forgiven drags the whole opening range down,
	-- so the customer they sent away costs them the goodwill of the next one. The charged count rather than
	-- the standing one: the first refusal is free, so it neither moves the offer nor gets mentioned below.
	local refusals = self:GetChargedSaleRefusals(player)
	local penalty = refusals * SellNpc.REFUSAL_OFFER_PENALTY

	-- Whether a customer has ever countered this player before. Their first one is given rather than
	-- rolled for -- see the decline branch below.
	local hasData, seenHaggle = PlayerDataManager:GetPlayerDataKey(player, "SeenHaggle"):await()

	for _, skewerRecord in record.skewerRecords do
		local cookState = CookStates.GetStateFromId(StickModel.GetCookStateId(skewerRecord))
		local skewerValue = StickModel.GetSellValue(skewerRecord)

		-- Floored at the skewer's plain worth rather than let run under it: a refused skewer stops earning a
		-- bonus, it never sells at a loss, and the offer still can't come in under the estimate the player
		-- was shown. OfferMax is held a sliver above OfferMin rather than allowed to meet it -- a state that
		-- already opens at 1 would otherwise converge onto a single number and quote it identically every
		-- visit, which reads as a broken customer rather than a penalised one. See SellNpc.MIN_OFFER_SPREAD.
		local offerMin = math.max(cookState.OfferMin - penalty, 1)
		local offerMax = math.max(cookState.OfferMax - penalty, offerMin + SellNpc.MIN_OFFER_SPREAD)

		value += skewerValue
		offer += skewerValue * self._rng:NextNumber(offerMin, offerMax)
		-- A normal customer carries exactly one skewer, so these land on that skewer's own numbers.
		counterChance = cookState.CounterChance
		counterCap = cookState.CounterCap
	end

	-- What the rich one pays over the odds for clearing the stand in one go, plus its own willingness to be
	-- pushed and its own ceiling to be pushed to -- a mixed haul has no single cook state for a per-skewer
	-- counter chance or cap to mean anything.
	if isRich then
		offer *= RichNpc.BULK_MULTIPLIER
		counterChance = RichNpc.COUNTER_CHANCE
		counterCap = RichNpc.OFFER_CAP_FACTOR
	end
	offer = math.round(offer)

	local accepted = false
	local timedOut = false
	local counterRounds = 0

	-- The offer's own UI is a billboard on the NPC, which is no help to a player off at the grill --
	-- and the window shuts on its own after OFFER_TIMEOUT. This is what brings them back for it. Only
	-- the opening offer gets one: a counter-offer means they just declined, so they're already here.
	--
	-- A player carrying refusals is told that's why the offer dropped, rather than left to notice the
	-- numbers quietly got worse -- the penalty only teaches anything if they know they're paying it. And
	-- once the last one decays they're told that too, off the count they were last warned about: a penalty
	-- nobody announces the end of is one the player goes on believing they're still paying.
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

		-- What the sale is actually worth to the player, which is the customer's offer plus whatever their
		-- boosts add on top of it. The frame quotes this rather than the bare offer because this is what
		-- lands in their balance -- a boosted player shown the plain figure watches the counter jump by
		-- half as much again as the number they just agreed to.
		--
		-- The badge is how far over the skewers' own worth that leaves them, so it carries the boosts too
		-- and the two describe the same number. Both re-derived each round, so a counter-offer moves them.
		local payout = CurrencyManager:GetBoostedAmount(player, offer)
		local bonus = math.round((payout / value - 1) * 100)
		self.NpcOfferEvent:FireClient(player, npc, payout, count, bonus)

		-- Wait on their answer, but never forever -- an ignored offer would stall every later customer.
		-- Nudging on the way is what stops a player at the grill losing the sale to a toast they missed.
		-- Unlike the opening toast this does run on a counter-offer round too: declining says they were
		-- here, not that they stayed.
		local deadline = os.clock() + config.OFFER_TIMEOUT
		local nudgeAt = os.clock() + SellNpc.OFFER_NUDGE_INTERVAL
		while record.offerResponse == nil and os.clock() < deadline and npc.Parent ~= nil do
			if os.clock() >= nudgeAt then
				-- Re-derived rather than advanced by the interval, so a server hitch can't queue two
				-- nudges back to back.
				nudgeAt = os.clock() + SellNpc.OFFER_NUDGE_INTERVAL

				NotificationManager:NotifyNormal(player, {
					Text = if isRich
						then `The {RICH_LABEL} customer is still waiting!`
						else "A customer is still waiting on you!",
					Duration = 3,
					Sound = "CustomerPinged",
					Effect = "Error",
				})

				-- The toast says someone's waiting; this says which one, for a player looking at a
				-- stand with a queue behind it. Only the seller sees it -- it's their offer to answer.
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

		-- Ignored: the window shut on its own. Split out from a decline so the player can be told --
		-- otherwise the toast that announced the offer just quietly stops meaning anything.
		if record.offerResponse == nil then
			timedOut = true
			break
		end

		-- Turned down. The customer may sweeten it, but only so many times, and gets far less willing each
		-- round. The hard round cap is what the decaying chance alone can't give: a long haggle is unlikely
		-- rather than impossible, and an unbounded one is something a patient player rides to the ceiling.
		if counterRounds >= config.MAX_COUNTER_ROUNDS then
			break
		end
		-- The player's first counter-offer ever is the one that isn't rolled for, but given.
		-- Declining is the one mechanic the onboarding can't teach -- it takes the Decline button off the
		-- offer it walks them to, since a first-timer turning down the sale the whole sequence built to
		-- has no idea what they've just done -- so their first real no is answered on the cook state's
		-- own chance, which is 30% on the raw skewers a new player is making. A first no that goes
		-- unanswered teaches them declining is simply a loss, and they never meet the mechanic at all.
		--
		-- Gated on hasData so a profile that failed to load isn't handed a guarantee that can't be
		-- recorded, which would mean a free counter on every visit for the rest of the session. The
		-- session latch is the other half of that: seenHaggle was read at the top of this negotiation and
		-- the sibling visits read their own, so the saved key alone can't stop several of them granting
		-- the same one counter at once.
		local firstCounter = hasData and not seenHaggle and not self._grantedFirstCounter[player]
		if not firstCounter and not RandomUtil.RollChance(counterChance, self._rng) then
			break
		end
		counterRounds += 1

		-- Spent the moment it's granted rather than once the exchange settles, so the later rounds of
		-- this same haggle are rolled for like any other. The latch goes up before the write rather than
		-- after it, since the write is what yields and a sibling visit resuming inside it would otherwise
		-- still find the grant going spare.
		if firstCounter then
			seenHaggle = true
			self._grantedFirstCounter[player] = true
			PlayerDataManager:SetPlayerDataKey(player, "SeenHaggle", true)

			-- The bubble and the haggle sound show that something happened; this is what says what. Put
			-- in terms of what they did and what it got them rather than named as haggling, which only
			-- reads as an explanation to someone who already knows the mechanic.
			NotificationManager:NotifyNormal(player, {
				Text = "You said no, so they're offering more! Declining can get you a better price",
				Duration = 5,
				Sound = "Notify",
				Effect = "Success",
			})
		end

		-- A share of the ground still left between what's on the table and this skewer's ceiling, rather
		-- than a flat slice of its worth: the same fraction buys less every round, so a haggle decelerates
		-- into the cap instead of marching at it in equal strides and having to be clamped off it.
		local headroom = value * counterCap - offer
		offer = math.round(
			offer + headroom * self._rng:NextNumber(config.COUNTER_INCREASE_MIN, config.COUNTER_INCREASE_MAX)
		)
		counterChance *= SellNpc.COUNTER_CHANCE_FALLOFF

		self.NpcSayEvent:FireAllClients(npc, `{prefix}CounterOffer`)

		-- The first counter has its own sound and every one after pitches up off a shared one, so a customer
		-- being pushed a third time audibly sounds like it. Positional on the customer and heard by everyone,
		-- matching the bubble above -- the haggle is something the whole stand can watch.
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

		-- Only a deliberate refusal is held against the next offer. Letting the window lapse has already
		-- cost them OFFER_TIMEOUT and wasn't a choice they made, so it isn't charged for twice.
		if not timedOut then
			self:RecordSaleRefusal(player)
		end

		-- Declining is a deliberate choice and needs no telling; letting the offer lapse does. No error
		-- effect -- the player didn't do anything wrong, they just lost the sale.
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

	-- What the player is about to be paid, worked out before the payout rather than after it: the early
	-- boost decays against TotalEarned, and IncrementCurrency bumps TotalEarned, so asking afterwards
	-- would price this sale's bonus off a figure this sale already moved. Display only -- everything
	-- below that quotes a number to the player quotes this one.
	local payout = CurrencyManager:GetBoostedAmount(player, offer)

	-- Sold: pay up, then the customer takes it round the back to eat. Handed the plain offer, not the
	-- payout above: applying the boosts is IncrementCurrency's own job, and giving it a figure that
	-- already carries them would boost the sale twice.
	CurrencyManager:IncrementCurrency(player, offer, "SkewerSale")

	-- This is the one point a sale is committed, so it's where the skewers stop being the stand's: they're
	-- bought, and never go back on it. Cleared off the record right here rather than after the eat, since
	-- both paths that put a customer's skewers back -- the last-save return when the player leaves, and a
	-- visit that throws -- read the record, and either landing during the eat would hand back what has
	-- just been paid for.
	local soldRecords = record.skewerRecords
	record.skewerRecords = nil

	StatsManager:RecordSaleCompleted(player, soldRecords)
	self.OnSaleCompleted:Fire(player, offer, soldRecords, isRich)

	-- Selling buys back a refusal, so a player who turned one offer down and took the next isn't left
	-- paying for it. Down here rather than up with the payout because it yields on their data, and the
	-- record's skewers are only safe to yield past once they've been cleared off it above.
	self:ForgiveSaleRefusal(player)

	-- Cash bursts off the customer and flies to the seller, so everyone nearby sees the sale land.
	-- Passing the payout lets each projectile pop one "+X" label on arrival for the seller, and the
	-- labels then add up to the jump they can watch on the currency counter.
	EffectManager:RunEffect("All", "CollectCash", { npc, payout, player })

	-- {value} is NotificationManager's own placeholder for the Count below, so it has to survive into the
	-- text as-is rather than being interpolated here.
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

	-- Step back out of the queue to a randomized spot and eat, so finished customers scatter into a loose
	-- crowd instead of lining up behind the stand.
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

-- Runs one customer visit (`visit` is a _spawnCustomer / _spawnRichCustomer call) with its failure
-- contained. A visit is a long chain of yields across a rig, a tool, a slot on the stand and the skewers
-- it took, and a throw partway through used to leave all of them where they were for the rest of the
-- server's life: the rig stood in workspace replicating to every client, the slot claimed so every later
-- customer lined up further down, the pool one rig short, the skewers gone. On a throw, whatever this
-- thread was tracking is put back the way a finished visit puts it back. Returns what the visit
-- returned, or true after a failure -- settled, the same as the dead thread used to leave it, so a bad
-- visit can't retry into the same error every few seconds.
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

-- Handles one owed sale on its own thread: wait a random delay, then send a customer for the skewer --
-- and keep sending one (after a short retry gap) until one buys (or the player leaves). Runs concurrently
-- with the other placements' visits, so one thread lives per unsold skewer.
function SellNpcManager:_runVisit(player: Player)
	-- A guaranteed player waits their own short delay rather than a random stretch of the normal range, so
	-- the customer they've been told to wait for is on their way as soon as the skewer lands.
	if self._guaranteed[player] then
		task.wait(SellNpc.GUARANTEED_SPAWN_DELAY)
	else
		task.wait(self._rng:NextNumber(SellNpc.SPAWN_DELAY_MIN, SellNpc.SPAWN_DELAY_MAX))
	end

	if not validatePlayer(player) then
		return
	end

	-- A turned-down skewer keeps drawing customers: retry until one buys (or the player leaves). Refusals
	-- stretch the gap before the replacement turns up, so declining costs selling time on top of the offer
	-- penalty -- the half of the cost that can't read as unfair. Read fresh each pass rather than once, so
	-- it decays away while a player who's stopped declining waits.
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

-- Sends one customer for each skewer already sitting on the player's stand, the same one-per-skewer the
-- placements owe. This is what picks a stall back up after a rejoin: the stand's contents persist but the
-- visit threads that were working through them don't, so nothing would come for what they left on display.
-- Each visit opens with its own spawn delay, so they trickle in rather than arriving all at once.
function SellNpcManager:SendCustomersForPlacedSkewers(player: Player)
	local placed = SkewerStandManager:GetPlacedSkewerCount(player)

	for _ = 1, placed do
		task.spawn(function()
			self:_runVisit(player)
		end)
	end
end

-- Sends one rich customer: a random rig from the RichNPC assets walks to the stand, takes every skewer on
-- it, and haggles over the lot as a single sum. Yields through the whole visit. There's no retry loop like
-- an ordinary customer's -- one that's turned down puts the whole stand back and the roll has to come
-- round again.
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

	-- The same slot allocator the ordinary customers use, so a rich one lines up beside whoever's already
	-- waiting rather than standing inside them.
	local slot = self:_claimSlot(player)
	local standPosition = (standPart.CFrame * CFrame.new(slot * SellNpc.STAND_SPACING, 0, 0)).Position
	if slot % 2 == 1 then
		standPosition += (spawnPart.Position - standPosition).Unit * SellNpc.STAND_ROW_OFFSET
	end

	local npc = self:_acquireRichNpc()
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	-- Tracked before anything yields: this record is both what _rollRichVisits reads to know a rich
	-- customer is already here, and what _cleanupPlayer destroys if the player leaves mid-visit. The
	-- thread is what _runGuardedVisit matches on to hand the rig back if this visit throws.
	local record = { npc = npc, tool = nil, slot = slot, isRich = true, thread = coroutine.running() }
	table.insert(tracked, record)

	-- No friend lookalike -- a rich customer is its own character -- so there's no appearance lookup to
	-- yield on before the fade.
	self:_fadeNpc(npc, true, SellNpc.FADE_IN_DURATION)

	local point = self:_randomPointOn(spawnPart)
	npc:PivotTo(CFrame.lookAt(point + Vector3.new(0, 3, 0), standPosition))
	npc.Parent = workspace

	-- Server-driven movement, so hand the root to the server rather than a nearby client.
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if rootPart and not rootPart.Anchored then
		rootPart:SetNetworkOwner(nil)
	end

	-- A rich visit is rare and clears the whole stand, so it's worth pulling the player back to watch it walk
	-- in. The offer toast in _negotiateSale is a separate beat -- that one's about answering in time.
	NotificationManager:NotifyNormal(player, {
		Text = `A {RICH_LABEL} customer is heading to your stand!`,
		Duration = 3,
		Sound = "RichSpawn",
	})

	self:_walkTo(humanoid, standPosition)

	if npc.Parent == nil then
		return
	end

	-- Clears the stand in one write. It was stocked when the roll landed, but an ordinary customer (or the
	-- player) can have emptied it during the walk, in which case there's nothing to buy and it leaves.
	local taken = SkewerStandManager:TakeAllSkewers(player)
	if #taken == 0 then
		self:_walkTo(humanoid, spawnPart.Position)
		self:_despawnNpc(player, record)
		return
	end
	record.skewerRecords = taken

	-- It only carries one of them -- six welded into one hand reads as a mess -- so it holds the pick of
	-- the haul and the offer line carries how many it's actually buying.
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

	-- No decide beat: a rich customer always buys. It's gated behind a long roll and it's holding the whole
	-- stand, so a walk-off would burn the event and hand six skewers back for nothing. The client still
	-- needs telling it's arrived, since that's what builds its billboards -- the offer frame included.
	self.NpcRichArriveEvent:FireAllClients(npc)
	task.wait(self._rng:NextNumber(RichNpc.APPRAISE_DURATION_MIN, RichNpc.APPRAISE_DURATION_MAX))

	if npc.Parent == nil then
		return
	end

	-- Turned down, the haul goes back on a stand with no customers left waiting on it -- the ordinary
	-- visit threads all resolved when the stand went empty. Send one per skewer so it doesn't sit dead.
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

		-- One at a time: a rich customer already at the stand is holding the stock the next one would want.
		-- Read off the tracked customers rather than a flag of its own, so a visit thread that errors out
		-- can't leave it stuck set and lock the player out of rich customers for the rest of the session.
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

		-- The cooldown lives in their data on the synced clock, not a session timer, so rejoining -- or
		-- hopping to a server that's never sent them one -- doesn't hand out a fresh rich customer.
		local hasStamp, lastRichVisit = PlayerDataManager:GetPlayerDataKey(player, "LastRichVisit"):await()
		if not hasStamp or (workspace:GetServerTimeNow() - lastRichVisit) < RichNpc.COOLDOWN then
			continue
		end

		-- Last: they clear the whole stand in one sale, so a thin one isn't worth the trip.
		if SkewerStandManager:GetPlacedSkewerCount(player) < RichNpc.MIN_SKEWERS then
			continue
		end

		-- Stamped before the visit rather than after, so however long the haggle drags on another can't be
		-- rolled the moment this one leaves.
		PlayerDataManager:SetPlayerDataKey(player, "LastRichVisit", workspace:GetServerTimeNow())

		task.spawn(function()
			self:_runGuardedVisit(player, function()
				self:_spawnRichCustomer(player)
			end)
		end)
	end
end

-- Sends a rich customer to a player's stand right now, skipping everything _rollRichVisits gates on: the
-- timer, the chance roll, the cooldown and MIN_SKEWERS. Fired off the command bar. The checks it does keep
-- are the ones that would otherwise leave the visit meaningless rather than merely unlikely.
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

	-- A stand under MIN_SKEWERS still gets one -- that's the gate being skipped -- but an empty stand leaves
	-- nothing to buy, and _spawnRichCustomer would walk in and straight back out with nothing to show for it.
	if SkewerStandManager:GetPlacedSkewerCount(player) == 0 then
		return false, `{player.Name}'s stand is empty, so there's nothing to buy.`
	end

	-- Stamped the same way the roll stamps it, so the timer can't send a second one on top of this visit.
	-- It isn't read here, so the command can still be run again straight away.
	PlayerDataManager:SetPlayerDataKey(player, "LastRichVisit", workspace:GetServerTimeNow())

	task.spawn(function()
		self:_runGuardedVisit(player, function()
			self:_spawnRichCustomer(player)
		end)
	end)

	return true
end

-- Tears down a leaving player's customers. Rigs are destroyed rather than pooled: a customer's visit
-- thread may still be mid-walk here, and destroying the rig (parent -> nil) is what its npc.Parent == nil
-- guards rely on to bail. Their cached friend list and stand slots are dropped too.
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

	-- Drop the looks fetched for this player's friends unless someone still here shares that friend --
	-- otherwise the cache holds a HumanoidDescription for every friend of everyone who has ever joined.
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

-- Puts the skewers the player's customers are holding back on their stand, right before their profile
-- is saved for the last time. A customer takes its skewers off the stand the moment it picks them up
-- and only ReturnSkewers puts them back, on the paths where it walks off -- so without this, leaving
-- (or the server shutting down) while one is deciding deletes those skewers for good, all six of them
-- if a rich customer took the lot.
--
-- Registered as a pre-cleanup callback because that's the one hook that covers every way a session
-- ends -- leaving, a shutdown, and another server taking the session over -- and _cleanupPlayer covers
-- only the first. It runs first for the same reason: PlayerDataManager loads as the priority module, so
-- its PlayerRemoving handler is connected before this manager's, and EndSession fires OnLastSave before
-- it yields. The customers are therefore still tracked here.
--
-- Mutates the data table directly and never yields, as the hook requires -- the player may already be
-- gone from Players, which is what SetPlayerDataKey needs.
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
			-- The stand can have been restocked while the customer stood there holding these, so it
			-- can't take everything back. Its own cap is the authority on what fits.
			if #data.SkewerStand >= SkewerStandManager.MAX_SKEWERS then
				break
			end

			table.insert(data.SkewerStand, skewer)
		end

		-- Cleared so a visit thread still running past this can't hand the same skewers back a second time.
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

	-- A visit is only ever owed by a placement, and the stand outlives the session it was stocked in --
	-- so without this, someone who logs off with a full stall comes back to one nobody visits until they
	-- place another skewer. The base is what says the stand exists, so wait until they've been given one.
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

	-- Unlike the ordinary customers a rich one isn't owed by a placement -- it's rolled for on a timer, so
	-- a stand left stocked can draw one while the player is off at the grill. Waits first, so the first
	-- roll doesn't fire before anyone has a base.
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
