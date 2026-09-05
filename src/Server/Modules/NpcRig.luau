-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- Managers
local CollisionManager = require(script.Parent.Parent.Managers.CollisionManager)

-- Shared
local Shared = ReplicatedStorage.Shared
local GlobalUtil = require(Shared.GlobalUtil)
local StickModel = require(Shared.StickModel)
local RandomUtil = require(Shared.RandomUtil)
local Animations = require(Shared.Animations)
local SellNpc = require(Shared.Config.SellNpc)

-- Assets
local NpcTemplate = ServerStorage.Assets.NPCTemplate
local SkewerToolTemplate = ReplicatedStorage.Assets.Tools.NPCSkewerTool

-- Parked out of workspace so their client replicas die, which tears down the billboards
local PoolFolder = Instance.new("Folder")
PoolFolder.Name = "NpcRigPool"
PoolFolder.Parent = ServerStorage

-- Each part's real transparency, so a fade-out to 1 isn't read back as the next fade-in target
local FADE_BASE_TRANSPARENCY_ATTR = "FadeBaseTransparency"

-- The rig plumbing every customer shares: the pool, the walk, the fade, the stand slots and the held skewer. Its numbers are SellNpc's, since that's the customer everything else is written against.
local NpcRig = {
	PoolFolder = PoolFolder, -- exposed so an unpooled rig can park alongside, and die on a leave the same way

	_slots = {}, -- [player] = { [slotIndex] = true } occupied stand positions, so customers don't overlap
	_pool = {}, -- available parked rigs, handed out and returned instead of cloning/destroying each visit
	_defaultDescription = nil, -- the template's own HumanoidDescription, re-applied to reset a released rig
	_descCache = {}, -- [userId] = HumanoidDescription, so each friend's look is fetched at most once
	_friendIds = {}, -- [player] = { userId, ... }, the owner's friend list fetched once per player
}

-- Resolves the base's spawn/stand parts, or nil if the player has no base in the world.
function NpcRig.GetBaseParts(player: Player): (BasePart?, BasePart?)
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
function NpcRig.RandomPointOn(part: BasePart, rng: Random): Vector3
	local size = part.Size
	local x = rng:NextNumber(-size.X / 2, size.X / 2)
	local z = rng:NextNumber(-size.Z / 2, size.Z / 2)
	return (part.CFrame * CFrame.new(x, size.Y / 2, z)).Position
end

-- Claims the lowest free stand slot, spacing concurrent customers along the stand (see STAND_SPACING).
function NpcRig.ClaimSlot(player: Player): number
	local slots = NpcRig._slots[player]
	if not slots then
		slots = {}
		NpcRig._slots[player] = slots
	end

	local index = 0
	while slots[index] do
		index += 1
	end
	slots[index] = true
	return index
end

-- Frees a claimed stand slot. Tolerates a missing map: ClearPlayer may have cleared it already.
function NpcRig.ReleaseSlot(player: Player, slot: number)
	local slots = NpcRig._slots[player]
	if slots then
		slots[slot] = nil
	end
end

-- Claims a slot and its wait position; lanes alternate around the stand's centre to stay centred.
function NpcRig.ClaimStandPosition(player: Player, spawnPart: BasePart, standPart: BasePart): (number, Vector3)
	local slot = NpcRig.ClaimSlot(player)
	local lane = math.ceil(slot / 2) * (if slot % 2 == 0 then 1 else -1)
	local position = (standPart.CFrame * CFrame.new(lane * SellNpc.STAND_SPACING, 0, 0)).Position

	-- Zig-zag: alternate lanes sit a row back, so a full line's billboards separate by depth.
	if lane % 2 == 1 then
		position += (spawnPart.Position - position).Unit * SellNpc.STAND_ROW_OFFSET
	end

	return slot, position
end

-- Pre-creates the reusable customer rigs and captures the template's default appearance. Idempotent, so every manager that uses the pool can call it rather than assuming another already did.
function NpcRig.BuildPool()
	if NpcRig._defaultDescription then
		return
	end

	NpcRig._defaultDescription = NpcTemplate:FindFirstChildOfClass("Humanoid"):GetAppliedDescription()

	for _ = 1, SellNpc.NPC_POOL_SIZE do
		local npc = NpcTemplate:Clone()
		CollisionManager:SetModelGroup(npc, CollisionManager.NPC)
		npc.Parent = PoolFolder
		table.insert(NpcRig._pool, npc)
	end
end

-- Hands out a parked rig, cloning only if the pool is empty. Stays in the pool folder; the caller places it.
function NpcRig.Acquire(): Model
	local npc = table.remove(NpcRig._pool)
	if npc then
		return npc
	end

	npc = NpcTemplate:Clone()
	CollisionManager:SetModelGroup(npc, CollisionManager.NPC)
	npc.Parent = PoolFolder
	return npc
end

-- Parks a rig back in the pool and resets its look, so the next customer doesn't inherit it.
function NpcRig.Release(npc: Model)
	npc.Parent = PoolFolder

	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	humanoid:ApplyDescriptionReset(NpcRig._defaultDescription)

	if #NpcRig._pool < SellNpc.NPC_POOL_SIZE then
		table.insert(NpcRig._pool, npc)
	else
		npc:Destroy()
	end
end

-- A random friend's HumanoidDescription, or nil. Cached, since both web calls are throttled.
function NpcRig.GetFriendDescription(player: Player, rng: Random): HumanoidDescription?
	local friendIds = NpcRig._friendIds[player]
	if not friendIds then
		friendIds = {}
		NpcRig._friendIds[player] = friendIds

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

	local userId = friendIds[rng:NextInteger(1, #friendIds)]
	local description = NpcRig._descCache[userId]
	if not description then
		local success, result = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(userId)
		end)
		if not success then
			return nil
		end
		description = result
		NpcRig._descCache[userId] = description
	end

	return description
end

-- Fades a rig's parts and decals. Fading out tweens to 1 and yields until it finishes.
function NpcRig.Fade(npc: Model, fadeIn: boolean, duration: number)
	local tweenInfo = TweenInfo.new(duration)

	for _, descendant in npc:GetDescendants() do
		if not (descendant:IsA("BasePart") or descendant:IsA("Decal")) then
			continue
		end

		-- Captured while still opaque: a reused rig sits at 1, so the live value would fade it invisible
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

-- Equips an NPCSkewerTool holding the skewer built from `record`, in the Npc collision group.
function NpcRig.GiveSkewer(npc: Model, record): (Tool, Model?)
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	local tool = SkewerToolTemplate:Clone()
	tool.Parent = workspace
	humanoid:EquipTool(tool)
	CollisionManager:SetModelGroup(tool, CollisionManager.NPC)

	local handle = tool:FindFirstChild("Handle")
	local skewer = StickModel.BuildStickModel(record)
	if skewer and handle then
		skewer:ScaleTo(StickModel.DISPLAY_SCALE)

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

-- Walks the NPC to `destination`, re-issuing MoveTo until it arrives or WALK_TIMEOUT elapses.
function NpcRig.WalkTo(humanoid: Humanoid, destination: Vector3)
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

-- Stops and destroys the looped track -- pooled rigs would otherwise stack one Animator track per visit.
function NpcRig.StopAnimation(record)
	local track = record.animationTrack
	if not track then
		return
	end

	record.animationTrack = nil
	track:Stop()
	track.Animation:Destroy()
	track:Destroy()
end

-- Plays a random Animations.Npc[animationName] clip on a rig, or nil if there's no id yet.
function NpcRig.PlayAnimation(record, animationName: string, rng: Random): AnimationTrack?
	NpcRig.StopAnimation(record)

	local ids = Animations.Npc[animationName]
	local animationId = ids and RandomUtil.GetRandomFromArray(ids, nil, rng)
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

-- Drops a leaving player's slots and their share of the appearance cache.
function NpcRig.ClearPlayer(player: Player)
	NpcRig._slots[player] = nil

	-- Dropped unless someone still here shares them, or the cache holds every friend of everyone who joined
	local friendIds = NpcRig._friendIds[player]
	NpcRig._friendIds[player] = nil
	if not friendIds then
		return
	end

	local stillWanted = {}
	for _, otherIds in NpcRig._friendIds do
		for _, userId in otherIds do
			stillWanted[userId] = true
		end
	end

	for _, userId in friendIds do
		local description = NpcRig._descCache[userId]
		if description and not stillWanted[userId] then
			NpcRig._descCache[userId] = nil
			description:Destroy()
		end
	end
end

-- Owned here rather than by a caller: two managers share these caches, so neither can be the one to clear them
Players.PlayerRemoving:Connect(NpcRig.ClearPlayer)

return NpcRig
