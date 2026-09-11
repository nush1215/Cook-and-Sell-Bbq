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
local StickIngredients = require(Shared.StickIngredients)
local RandomUtil = require(Shared.RandomUtil)
local Animations = require(Shared.Animations)
local SellNpc = require(Shared.Config.SellNpc)
local CustomOrderNpc = require(Shared.Config.CustomOrderNpc)
local Employees = require(Shared.Config.Employees)

-- Assets
local NpcTemplate = ServerStorage.Assets.NPCTemplate
local FallbackNpcFolder = ServerStorage.Assets.NPC
local SkewerToolTemplate = ReplicatedStorage.Assets.Tools.NPCSkewerTool

-- Parked out of workspace so their client replicas die, which tears down the billboards
local PoolFolder = Instance.new("Folder")
PoolFolder.Name = "NpcRigPool"
PoolFolder.Parent = ServerStorage

-- Each part's real transparency, so a fade-out to 1 isn't read back as the next fade-in target
local FADE_BASE_TRANSPARENCY_ATTR = "FadeBaseTransparency"

-- Well under the map, and only for the two frames it takes a portrait's accessory welds to solve
local PORTRAIT_BAKE_CFRAME = CFrame.new(0, -1000, 0)

-- The rig plumbing every customer shares: the pool, the walk, the fade, the stand slots and the held skewer. Its numbers are SellNpc's, since that's the customer everything else is written against.
local NpcRig = {
	PoolFolder = PoolFolder, -- exposed so an unpooled rig can park alongside, and die on a leave the same way

	_slots = {}, -- [player] = { [slotIndex] = true } occupied stand positions, so customers don't overlap
	_pool = {}, -- available parked rigs, handed out and returned instead of cloning/destroying each visit
	_defaultDescription = nil, -- the template's own HumanoidDescription, re-applied to reset a released rig
	_descCache = {}, -- [userId] = HumanoidDescription, so each friend's look is fetched at most once
	_friendIds = {}, -- [player] = { userId, ... }, the owner's friend list fetched once per player
	_fallbackDescriptions = {}, -- Assets.NPC's looks, worn when there's no friend to dress a customer as
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

-- A random spot back from the stand for a buyer to eat at, so finished customers scatter rather than lining up behind it.
function NpcRig.GetEatPosition(spawnPart: BasePart, standPosition: Vector3, rng: Random): Vector3
	local backDir = (spawnPart.Position - standPosition).Unit
	local sideDir = Vector3.new(-backDir.Z, 0, backDir.X) -- perpendicular, on the ground plane

	return standPosition
		+ backDir * rng:NextNumber(SellNpc.EAT_BACK_DISTANCE_MIN, SellNpc.EAT_BACK_DISTANCE_MAX)
		+ sideDir * rng:NextNumber(-SellNpc.EAT_SPREAD, SellNpc.EAT_SPREAD)
end

-- Pre-creates the reusable customer rigs and captures the template's default appearance. Idempotent, so every manager that uses the pool can call it rather than assuming another already did.
function NpcRig.BuildPool()
	if NpcRig._defaultDescription then
		return
	end

	NpcRig._defaultDescription = NpcTemplate:FindFirstChildOfClass("Humanoid"):GetAppliedDescription()

	for _, rig in FallbackNpcFolder:GetChildren() do
		table.insert(NpcRig._fallbackDescriptions, rig:FindFirstChildOfClass("Humanoid"):GetAppliedDescription())
	end

	for _ = 1, SellNpc.NPC_POOL_SIZE do
		table.insert(NpcRig._pool, NpcRig.CloneRig())
	end
end

-- Clones a fresh rig into the pool folder, stamped for the NPC collision group and atomic streaming.
function NpcRig.CloneRig(): Model
	local npc = NpcTemplate:Clone()
	CollisionManager:SetModelGroup(npc, CollisionManager.NPC)

	-- Whole or not at all: under default mode the tag lands on the client long before the head the billboards hang off
	npc.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	npc.Parent = PoolFolder
	return npc
end

-- Hands out a parked rig, cloning only if the pool is empty. Stays in the pool folder; the caller places it.
function NpcRig.Acquire(): Model
	return table.remove(NpcRig._pool) or NpcRig.CloneRig()
end

-- Parks a rig back in the pool and resets its look, so the next customer doesn't inherit it.
function NpcRig.Release(npc: Model)
	npc.Parent = PoolFolder

	-- The pool is shared, so a stale order would draw a recipe card over the next customer to wear this rig
	npc:RemoveTag(CustomOrderNpc.TAG)
	npc:SetAttribute(CustomOrderNpc.ORDER_ATTRIBUTE, nil)

	npc:RemoveTag(SellNpc.TAG)
	npc:SetAttribute(SellNpc.VISIT_ATTRIBUTE, nil)

	-- Likewise a seller's claim, or the next customer to wear this rig arrives already spoken for
	npc:SetAttribute(Employees.SERVED_BY_ATTRIBUTE, nil)

	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	humanoid:ApplyDescriptionReset(NpcRig._defaultDescription)

	if #NpcRig._pool < SellNpc.NPC_POOL_SIZE then
		table.insert(NpcRig._pool, npc)
	else
		npc:Destroy()
	end
end

-- A random friend's HumanoidDescription, falling back to an Assets.NPC look. Cached, since both web calls are throttled.
function NpcRig.GetCustomerDescription(player: Player, rng: Random): HumanoidDescription?
	local friendIds = NpcRig._friendIds[player]
	if not friendIds then
		local success, pages = pcall(function()
			return Players:GetFriendsAsync(player.UserId)
		end)
		-- Only cached on success, so one throttled call doesn't hold them on fallbacks all session
		if not success then
			return RandomUtil.GetRandomFromArray(NpcRig._fallbackDescriptions, nil, rng)
		end

		friendIds = {}
		NpcRig._friendIds[player] = friendIds
		for _, friend in pages:GetCurrentPage() do
			table.insert(friendIds, friend.Id)
		end
	end

	if #friendIds == 0 then
		return RandomUtil.GetRandomFromArray(NpcRig._fallbackDescriptions, nil, rng)
	end

	local userId = friendIds[rng:NextInteger(1, #friendIds)]
	local description = NpcRig._descCache[userId]
	if not description then
		local success, result = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(userId)
		end)
		if not success then
			return RandomUtil.GetRandomFromArray(NpcRig._fallbackDescriptions, nil, rng)
		end
		description = result
		NpcRig._descCache[userId] = description
	end

	return description
end

-- Dresses a rig in `cosmetics` -- hair or a hat, a face and a skin tone -- keeping whatever it was authored
-- wearing. A reset apply strips the rig, and the templates are dressed by hand in the place file, so what
-- they have on is kept aside and put back afterwards. Yields on the asset fetch, and the rig must be in the
-- DataModel already.
function NpcRig.ApplyLook(rig: Model, cosmetics): (boolean, string?)
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false, "the rig has no Humanoid"
	end

	-- Clothing goes back as the instances rather than through the description: a ShirtTemplate holds the
	-- texture id, and the description's Shirt field wants the catalog id, so the engine drops the shirt
	local authored = {}
	for _, child in rig:GetChildren() do
		if child:IsA("Shirt") or child:IsA("Pants") or child:IsA("ShirtGraphic") or child:IsA("CharacterMesh") then
			table.insert(authored, child:Clone())
		end
	end

	local success, err = pcall(function()
		local description = humanoid:GetAppliedDescription()

		-- Read off the instance: no description has ever been applied to these rigs, so the one handed back
		-- carries none of what they're wearing
		local bodyColors = rig:FindFirstChildOfClass("BodyColors")
		if bodyColors then
			description.HeadColor = bodyColors.HeadColor3
			description.TorsoColor = bodyColors.TorsoColor3
			description.LeftArmColor = bodyColors.LeftArmColor3
			description.RightArmColor = bodyColors.RightArmColor3
			description.LeftLegColor = bodyColors.LeftLegColor3
			description.RightLegColor = bodyColors.RightLegColor3
		end

		description.HairAccessory = cosmetics.Hair or ""
		description.HatAccessory = cosmetics.Hat or ""

		-- Head, not Face or FaceAccessory: these are head assets, and the engine refuses a description that
		-- names one asset in two fields. Left alone when there's none, or the rig loses the head it was built with
		if cosmetics.Head then
			description.Head = tonumber(cosmetics.Head) or description.Head
		end

		-- Over the authored colours, so a worker with no tone rolled keeps the template's own
		if cosmetics.Skin then
			local tone = Color3.fromHex(cosmetics.Skin)

			description.HeadColor = tone
			description.TorsoColor = tone
			description.LeftArmColor = tone
			description.RightArmColor = tone
			description.LeftLegColor = tone
			description.RightLegColor = tone
		end

		humanoid:ApplyDescriptionReset(description)
	end)

	if not success then
		for _, item in authored do
			item:Destroy()
		end

		return false, err
	end

	-- Whatever the reset left of the same kinds goes first, so nothing is worn twice
	for _, child in rig:GetChildren() do
		if child:IsA("Shirt") or child:IsA("Pants") or child:IsA("ShirtGraphic") or child:IsA("CharacterMesh") then
			child:Destroy()
		end
	end

	for _, item in authored do
		item.Parent = rig
	end

	return true, nil
end

-- Dresses a clone of `template` in `cosmetics` and freezes it, so a client can clone it straight into a viewport. Yields. Hands back the dress error alongside the rig, since a failed dress still bakes the plain body.
function NpcRig.BakePortrait(template: Model, cosmetics): (Model?, string?)
	local rig = template:Clone()
	if not rig:FindFirstChildOfClass("Humanoid") then
		rig:Destroy()
		return nil, "the template has no Humanoid"
	end

	-- Pinned by the root before it lands, or it falls the moment it's parented. The rest stay jointed and
	-- loose, since a handle anchored in place is a handle the weld can never pull onto the head
	local rootPart = rig:FindFirstChild("HumanoidRootPart")
	if rootPart then
		rootPart.Anchored = true
	end

	rig:PivotTo(PORTRAIT_BAKE_CFRAME)
	rig.Parent = workspace

	-- Dressed only once it's in the world: ApplyDescription refuses a rig that isn't in the DataModel at all,
	-- and the welds holding an accessory on are solved by physics, which doesn't run anywhere else either
	local success, err = NpcRig.ApplyLook(rig, cosmetics)

	-- After the dress, not before: applying one rebuilds the rig's accessory parts, so anything stamped
	-- earlier wouldn't have reached the very parts this is for
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	-- Two frames under the map for those welds to settle, then the settled pose is what's kept. Nothing scans
	-- workspace broadly here -- every NPC system keys off its own tag -- so it's seen by nothing
	task.wait()
	task.wait()

	local baked = rig:Clone()
	rig:Destroy()

	-- The Humanoid stays: Shirt, Pants and CharacterMesh only render on a model that has one, viewport or not
	for _, descendant in baked:GetDescendants() do
		if descendant:IsA("BaseScript") or descendant:IsA("Sound") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end

	return baked, if success then nil else err
end

-- Fades a rig's parts and decals. Fading out tweens to 1 and yields until it finishes. `onlyNew` skips anything faded once already, for parts arriving after the rig is up -- cosmetics land late, and re-fading the whole rig around them reads as a flicker.
function NpcRig.Fade(npc: Model, fadeIn: boolean, duration: number, onlyNew: boolean?)
	local tweenInfo = TweenInfo.new(duration)

	for _, descendant in npc:GetDescendants() do
		if not (descendant:IsA("BasePart") or descendant:IsA("Decal")) then
			continue
		end

		-- Captured while still opaque: a reused rig sits at 1, so the live value would fade it invisible
		local base = descendant:GetAttribute(FADE_BASE_TRANSPARENCY_ATTR)
		if base ~= nil then
			if onlyNew then
				continue
			end
		else
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

-- Puts `model` in an NPC's hands on the shared skewer tool. Any model does, so a maker can carry a pile of loose stock the same way a customer carries a finished skewer. Its PrimaryPart must be set -- WeldModel reads it.
function NpcRig.GiveCarried(npc: Model, model: Model?, scale: number?, offset: CFrame?): (Tool, Model?)
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	-- Parented before equipping: EquipTool refuses a tool that isn't in the DataModel
	local tool = SkewerToolTemplate:Clone()
	tool.Parent = workspace
	humanoid:EquipTool(tool)
	CollisionManager:SetModelGroup(tool, CollisionManager.NPC)

	local handle = tool:FindFirstChild("Handle")
	if model and handle then
		-- Scaled before welding, so the weld offsets are baked at the size it'll be carried at
		model:ScaleTo(scale or StickModel.DISPLAY_SCALE)

		GlobalUtil.WeldModel(model, false)
		model:PivotTo(handle.CFrame * (offset or SellNpc.SKEWER_HOLD_OFFSET))
		GlobalUtil.Weld(handle, model.PrimaryPart)

		-- Stamped by hand: SetModelGroup above ran before this model was parented into the tool
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.CanCollide = false
				descendant.Massless = true
				descendant.CollisionGroup = CollisionManager.NPC
			end
		end

		model.Parent = tool
	end

	return tool, model
end

-- Balances `model` over an NPC's head, the way a player carries what they're holding. Welded to the head rather than a hand: a tool handle rides the arm's Motor6D, so any hold pose tips a hand-built pile onto its side. Its PrimaryPart must be set -- WeldModel reads it.
function NpcRig.GiveOverhead(npc: Model, model: Model, height: number): Model
	local humanoid = npc:FindFirstChildOfClass("Humanoid")

	GlobalUtil.WeldModel(model, false)

	-- Lifted by half its own height, so a lone ingredient and a full armful both clear the head alike. Its
	-- height, not its biggest side: a pile with a stick laid across it is wider than it is tall, and half a
	-- stick's length of lift would leave the whole load hanging in the air above the head
	local _, size = model:GetBoundingBox()
	local seat = CFrame.new(0, height + size.Y / 2, 0)
	model:PivotTo(humanoid.RootPart.CFrame * seat * StickIngredients.GetPivotToCenter(model):Inverse())

	GlobalUtil.Weld(model.PrimaryPart, npc.Head)

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.Massless = true
			descendant.CollisionGroup = CollisionManager.NPC
		end
	end

	model.Parent = workspace

	return model
end

-- Equips an NPCSkewerTool holding the skewer built from `record`. `scale` defaults to the customer's shrunken display size; staff carrying one hold it at the size a player does.
function NpcRig.GiveSkewer(npc: Model, record, scale: number?): (Tool, Model?)
	return NpcRig.GiveCarried(npc, StickModel.BuildStickModel(record), scale)
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

-- Stops and destroys one track. Pooled rigs would otherwise stack an Animator track per visit.
function NpcRig.StopAnimationTrack(track: AnimationTrack?)
	if not track then
		return
	end

	track:Stop()
	track.Animation:Destroy()
	track:Destroy()
end

-- Plays one animation id on a rig and hands the track back for the caller to stop. Looped unless told otherwise, since a pose is held until it's taken off -- either way it's set here rather than left to how the asset was uploaded.
function NpcRig.PlayAnimationId(npc: Model, animationId: string, name: string?, looped: boolean?): AnimationTrack?
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end

	local animation = Instance.new("Animation")
	animation.Name = name or "Animation"
	animation.AnimationId = animationId

	local track = animator:LoadAnimation(animation)
	track.Looped = looped ~= false
	track:Play()

	return track
end

-- Stops the track a record is holding, if it has one.
function NpcRig.StopAnimation(record)
	NpcRig.StopAnimationTrack(record.animationTrack)
	record.animationTrack = nil
end

-- Plays a random Animations.Npc[animationName] clip on a rig, or nil if there's no id yet.
function NpcRig.PlayAnimation(record, animationName: string, rng: Random): AnimationTrack?
	NpcRig.StopAnimation(record)

	local ids = Animations.Npc[animationName]
	local animationId = ids and RandomUtil.GetRandomFromArray(ids, nil, rng)
	if not animationId then
		return nil
	end

	record.animationTrack = NpcRig.PlayAnimationId(record.npc, animationId, animationName)

	return record.animationTrack
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
