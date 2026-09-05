-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

-- Server
local Server = script.Parent.Parent
local ServerRandom = require(Server.Modules.ServerRandom)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local RandomUtil = require(Shared.RandomUtil)
local GuiUtil = require(Shared.GuiUtil)
local Crates = require(Shared.Config.Crates)
local Ingredients = require(Shared.Config.Ingredients)
local Sticks = require(Shared.Config.Sticks)

-- Assets
local Assets = ReplicatedStorage.Assets
local ToolTemplate = Assets.Tools.CrateTool

-- Managers
local PlayerDataManager
local IngredientManager
local StickManager
local NotificationManager

--
local TOOL_TAG = "CrateTool"
local HELD_TAG = "HeldItem"
local CRATE_TAG = "Crate"
local SPAWNED_FOLDER_NAME = "SpawnedCrates"

-- The rings a batch's crates land in, and how many fit in the inner one before the rest spill outward.
local INNER_RADIUS = 10
local OUTER_RADIUS = 18
local PER_RING_MAX = 5

-- Seconds before the server forces an owner's crate visible, for a client that never unhid it
local REVEAL_DELAY = 2

-- How long past its animation a crate waits for its owner's claim before the server grants the rewards.
local CLAIM_FALLBACK_DELAY = 5

-- How long a granted crate waits for its batch; crates land THROW_STAGGER apart, so one window covers ten
local TALLY_WINDOW = 1

-- Owning, opening and paying out crates: rolls each payout server-side, lays the batch out, and grants on the client's claim or a fallback.

--
type SpawnCrateData = {
	Owner: number?, -- the UserId whose client throws and claims this one
	OpenIndex: number?, -- its place in the batch, which is how long its client waits before throwing
	OpenCount: number?,
	-- World-crate flags, unset today: for a crate that idles in place until something opens it
	AutoIdle: boolean?,
	TimeToOpen: number?,
}

type SpawnedCrate = {
	CrateId: string,
	Rewards: { Crates.Reward },
	Model: Model,
	Owner: number?,
	OpenIndex: number,
	SpawnedAt: number, -- workspace:GetServerTimeNow(), what the claim's time gate measures against
}

--
local CrateManager = {
	OpenCratesEvent = Network.Event("OpenCrates"), -- client -> server (crateId, count)
	ClaimCrateEvent = Network.Event("ClaimCrate"), -- client -> server (uniqueId)

	_spawned = {} :: { [string]: SpawnedCrate },
	_spawnedFolder = nil :: Folder?,
	_openCooldowns = {}, -- [player] = os.clock() their next open is allowed at
	_listeners = {}, -- [player] = the Crates data listener
	_pendingEquips = {}, -- [player] = the crate id to equip once its tool exists
	_pendingTallies = {}, -- [player] = what their in-flight batch has opened and paid out so far
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Equips a tool. A no-op mid-respawn, since the new character's reconcile rebuilds their tools.
local function equipTool(player: Player, tool: Tool)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:EquipTool(tool)
	end
end

-- The player's crate tools by id. Both containers, since an equipped tool sits in the character.
local function getCrateTools(player: Player): { [string]: Tool }
	local tools = {}
	local containers = { player:FindFirstChildOfClass("Backpack"), player.Character }

	for _, container in containers do
		if not container then
			continue
		end

		for _, child in container:GetChildren() do
			if not (child:IsA("Tool") and child:HasTag(TOOL_TAG)) then
				continue
			end

			local crateId = child:GetAttribute("CrateId")
			if crateId then
				tools[crateId] = child
			end
		end
	end

	return tools
end

-- Where a batch lands: a ring around the player, overflow in a wider second one, each facing them.
local function computeFormation(origin: CFrame, count: number, raycastParams: RaycastParams): { CFrame }
	local slots = {}

	local function addRing(ringCount: number, radius: number)
		for index = 0, ringCount - 1 do
			local angle = (index / ringCount) * math.pi * 2
			local position = (origin * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, -radius)).Position

			local result = workspace:Raycast(position + Vector3.new(0, 10, 0), Vector3.new(0, -200, 0), raycastParams)
			local groundY = if result then result.Position.Y else origin.Position.Y
			position = Vector3.new(position.X, groundY, position.Z)

			-- Level with the ground rather than pitched at the player, so the crate sits flat on its slot
			local facing = Vector3.new(origin.Position.X, position.Y, origin.Position.Z)
			table.insert(slots, CFrame.lookAt(position, facing))
		end
	end

	if count <= PER_RING_MAX then
		addRing(count, INNER_RADIUS)
	else
		addRing(PER_RING_MAX, INNER_RADIUS)
		addRing(count - PER_RING_MAX, OUTER_RADIUS)
	end

	return slots
end

-- An empty tagged tool carrying the crate's id and count; HeldItem draws the visual off these.
function CrateManager:_buildTool(crate: Crates.Crate, count: number): Tool
	local tool = ToolTemplate:Clone()

	tool.Name = crate.Name
	tool.ToolTip = GuiUtil.Colorize(crate.Name, crate.Color)
	tool:SetAttribute("CrateId", crate.Id)
	tool:SetAttribute("Count", count)

	-- Left on whatever the template carries until a crate authors its own icon
	if crate.Icon then
		tool.TextureId = crate.Icon
	end

	-- Tag last, against a fully assembled tool
	tool:AddTag(TOOL_TAG)
	tool:AddTag(HELD_TAG)
	return tool
end

-- Brings the player's crate tools in line with the crates they own.
function CrateManager:_reconcileTools(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or not player:IsDescendantOf(Players) then
		return
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end

	local owned = data.Crates
	local existing = getCrateTools(player)

	-- Drop the tools for anything they've run out of
	for crateId, tool in existing do
		if (owned[crateId] or 0) <= 0 then
			tool:Destroy()
		end
	end

	for crateId, count in owned do
		if count <= 0 then
			continue
		end

		-- Being given the same crate again stacks onto the tool that's already there
		local tool = existing[crateId]
		if tool then
			tool:SetAttribute("Count", count)
		else
			-- Data can name an id the config no longer has -- removed, or dropped at load for a missing model
			local crate = Crates.GetCrateFromId(crateId)
			if not crate then
				continue
			end

			tool = self:_buildTool(crate, count)
			tool.Parent = backpack
		end

		-- The crate they were just handed goes straight into their hands
		if self._pendingEquips[player] == crateId then
			self._pendingEquips[player] = nil
			equipTool(player, tool)
		end
	end
end

-- Adds to the player's owned count; the reconcile turns it into a tool or a higher Count, equipped.
function CrateManager:GrantCrate(player: Player, crateId: string, amount: number?)
	local crate = Crates.GetCrateFromId(crateId)
	if not crate then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- Flagged before the write, since that's what runs the reconcile that builds the tool to equip
	self._pendingEquips[player] = crateId

	local owned = data.Crates[crateId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "Crates", crateId }, owned + (amount or 1))
end

-- Takes from the player's owned count; the reconcile turns it into a lower Count or a destroyed tool.
function CrateManager:ConsumeCrate(player: Player, crateId: string, amount: number?)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local owned = data.Crates[crateId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "Crates", crateId }, math.max(0, owned - (amount or 1)))
end

-- Rolls a crate's payout in authored order, which is also the reveal's. One Random threads every slot.
function CrateManager:RollCrateContents(crate: Crates.Crate, rng: Random): { Crates.Reward }
	local rewards = {}

	for _, group in crate.Contents do
		local taken = {}

		for _ = 1, group.Count do
			-- Rebuilt per slot, not edited, since the config table is shared; entries are weighted, not ids
			local weighted = {}
			for _, entry in group.Rewards do
				if not (group.Distinct and taken[entry]) then
					table.insert(weighted, { entry, entry.Chance })
				end
			end

			-- Only nil once a Distinct group has exhausted its pool, which the config warns about at load
			local reward = RandomUtil.GetResultFromWeight(weighted, rng)
			if not reward then
				continue
			end

			taken[reward] = true
			table.insert(rewards, { Type = reward.Type, Id = reward.Id })
		end
	end

	return rewards
end

-- The workspace folder every spawned crate lives under, made on first use.
function CrateManager:_getSpawnedFolder(): Folder
	if not self._spawnedFolder then
		local folder = Instance.new("Folder")
		folder.Name = SPAWNED_FOLDER_NAME
		folder.Parent = workspace

		self._spawnedFolder = folder
	end

	return self._spawnedFolder
end

-- Grants one crate's payout in rolled order and folds it into the tally. Must run exactly once per crate.
function CrateManager:_grantCrateRewards(player: Player, spawnedCrate: SpawnedCrate)
	for _, reward in spawnedCrate.Rewards do
		if reward.Type == "Ingredient" then
			IngredientManager:GrantIngredient(player, reward.Id)
		else
			StickManager:GrantStick(player, reward.Id)
		end
	end

	self:_tallyCrateRewards(player, spawnedCrate)
end

-- Adds a payout to the tally and re-arms the batch summary, so a whole batch reports once.
function CrateManager:_tallyCrateRewards(player: Player, spawnedCrate: SpawnedCrate)
	local pending = self._pendingTallies[player]

	-- A tally speaks for one kind of crate, so a second kind mid-window flushes rather than folding in
	if pending and pending.CrateId ~= spawnedCrate.CrateId then
		self:_announceCrateTally(player)
		pending = nil
	end

	if not pending then
		pending = { CrateId = spawnedCrate.CrateId, Crates = 0, Rewards = {}, Counts = {}, Generation = 0 }
		self._pendingTallies[player] = pending
	end

	pending.Crates += 1

	-- Kept in first-rolled order, since that's the order the reveal laid the row out in
	for _, reward in spawnedCrate.Rewards do
		local key = `{reward.Type}:{reward.Id}`

		if pending.Counts[key] then
			pending.Counts[key] += 1
		else
			pending.Counts[key] = 1
			table.insert(pending.Rewards, reward)
		end
	end

	-- Bumped so only the last crate's timer announces; earlier ones find a newer generation and bail
	pending.Generation += 1
	local generation = pending.Generation

	task.delay(TALLY_WINDOW, function()
		if self._pendingTallies[player] == pending and pending.Generation == generation then
			self:_announceCrateTally(player)
		end
	end)
end

-- One line for the crates and one per distinct thing, rather than a toast per crate.
function CrateManager:_announceCrateTally(player: Player)
	local pending = self._pendingTallies[player]
	if not pending then
		return
	end

	self._pendingTallies[player] = nil

	-- The window is a delay, so they may well have left inside it
	if not validatePlayer(player) then
		return
	end

	local crate = Crates.GetCrateFromId(pending.CrateId)

	NotificationManager:NotifyNormal(player, {
		Text = `You opened {pending.Crates}x {GuiUtil.Colorize(crate.Name, crate.Color)}`,
		Duration = 5,
		Sound = "CollectedReward",
		Effect = "Success",
	})

	for _, reward in pending.Rewards do
		local count = pending.Counts[`{reward.Type}:{reward.Id}`]
		local name, color

		if reward.Type == "Ingredient" then
			local ingredient = Ingredients.GetIngredientFromId(reward.Id)
			name, color = ingredient.Name, ingredient.Color
		else
			local stick = Sticks.GetStickFromId(reward.Id)
			name, color = `{stick.Name} Stick`, stick.TextColor
		end

		NotificationManager:NotifyNormal(player, {
			Text = `You got {count}x {GuiUtil.Colorize(name, color)}`,
			Duration = 5,
			Sound = "CollectedReward",
			Effect = "Success",
		})
	end
end

-- Spawns one crate with its payout already rolled onto it, returning the id a claim names it by.
function CrateManager:SpawnCrate(crateId: string, cframe: CFrame, data: SpawnCrateData?): (Model?, string?)
	local crate = Crates.GetCrateFromId(crateId)
	if not crate then
		return nil, nil
	end

	local rewards = self:RollCrateContents(crate, ServerRandom.MakeRNG(`Crate:{crateId}`))

	local uniqueId = HttpService:GenerateGUID(false)
	local owner = data and data.Owner
	local openIndex = (data and data.OpenIndex) or 1
	local model = crate.Model:Clone()

	model.Name = crate.Name
	model:SetAttribute("UniqueId", uniqueId)
	model:SetAttribute("CrateId", crateId)

	-- An attribute, not a remote -- a remote naming a fresh model can beat the model to the client
	model:SetAttribute("Rewards", HttpService:JSONEncode(rewards))

	if owner then
		model:SetAttribute("Owner", owner)
		model:SetAttribute("OpenIndex", openIndex)
		model:SetAttribute("OpenCount", data and data.OpenCount)
	end

	if data and data.AutoIdle then
		model:SetAttribute("AutoIdle", true)
	end

	if data and data.TimeToOpen then
		model:SetAttribute("TimeToOpen", data.TimeToOpen)
	end

	-- Pivoted every frame, so nothing may be simulated -- an unanchored one would fall through the floor
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
		end
	end

	-- Hidden so it can't flash on its slot before the throw; this is the fallback for a client that never showed it
	if owner then
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant:SetAttribute("RevealTransparency", descendant.Transparency)
				descendant.Transparency = 1
			end
		end

		task.delay(REVEAL_DELAY, function()
			if not model.Parent then
				return
			end

			for _, descendant in model:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.Transparency = descendant:GetAttribute("RevealTransparency") or 0
				end
			end
		end)
	end

	model:PivotTo(cframe)
	model:AddTag(CRATE_TAG)
	model.Parent = self:_getSpawnedFolder()

	self._spawned[uniqueId] = {
		CrateId = crateId,
		Rewards = rewards,
		Model = model,
		Owner = owner,
		OpenIndex = openIndex,
		SpawnedAt = workspace:GetServerTimeNow(),
	}

	model.Destroying:Connect(function()
		self._spawned[uniqueId] = nil
	end)

	-- The rewards are already theirs, so the server hands them over rather than eating the crate
	if owner then
		task.delay(Crates.GetOpenDuration(crate, openIndex) + CLAIM_FALLBACK_DELAY, function()
			local spawnedCrate = self._spawned[uniqueId]
			if not spawnedCrate then
				return
			end

			self._spawned[uniqueId] = nil

			local ownerPlayer = Players:GetPlayerByUserId(owner)
			if ownerPlayer then
				self:_grantCrateRewards(ownerPlayer, spawnedCrate)
			end

			if model.Parent then
				model:Destroy()
			end
		end)
	end

	return model, uniqueId
end

-- Opens up to `count` crates: takes them from data and lays them out for the client to throw and open.
function CrateManager:RequestOpenCrates(player: Player, crateId: string, count: number)
	if not validatePlayer(player) then
		return
	end

	-- Straight off a remote, so neither argument can be trusted to be the right type
	if typeof(crateId) ~= "string" or typeof(count) ~= "number" then
		return
	end

	local crate = Crates.GetCrateFromId(crateId)
	if not crate then
		return
	end

	count = math.clamp(math.floor(count), 0, Crates.MAX_OPEN_AT_ONCE)
	if count <= 0 then
		return
	end

	-- The authoritative debounce, stamped before the read below yields or two requests would both pass
	if os.clock() < (self._openCooldowns[player] or 0) then
		NotificationManager:NotifyNormal(player, {
			Text = "You're opening crates too fast!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return
	end

	self._openCooldowns[player] = os.clock() + Crates.GetOpenCooldown(count)

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or not validatePlayer(player) then
		return
	end

	count = math.min(count, data.Crates[crateId] or 0)
	if count <= 0 then
		return
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	-- Taken before anything is spawned, so a second request can't open the same crates again
	self:ConsumeCrate(player, crateId, count)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character, self:_getSpawnedFolder() }
	raycastParams.IgnoreWater = true

	for index, slot in computeFormation(rootPart.CFrame, count, raycastParams) do
		self:SpawnCrate(crateId, slot, {
			Owner = player.UserId,
			OpenIndex = index,
			OpenCount = count,
		})
	end
end

-- Gives an ownerless crate an owner and arms its claim fallback, for one that crashed in unowned.
function CrateManager:BeginCrateOpen(uniqueId: string, player: Player): boolean
	local spawnedCrate = self._spawned[uniqueId]
	if not spawnedCrate or spawnedCrate.Owner then
		return false
	end

	spawnedCrate.Owner = player.UserId
	spawnedCrate.Model:SetAttribute("Owner", player.UserId)

	local crate = Crates.GetCrateFromId(spawnedCrate.CrateId)

	task.delay(Crates.GetOpenDuration(crate, spawnedCrate.OpenIndex) + CLAIM_FALLBACK_DELAY, function()
		if self._spawned[uniqueId] ~= spawnedCrate then
			return
		end

		self._spawned[uniqueId] = nil

		if player:IsDescendantOf(Players) then
			self:_grantCrateRewards(player, spawnedCrate)
		end

		if spawnedCrate.Model.Parent then
			spawnedCrate.Model:Destroy()
		end
	end)

	return true
end

-- Hands over one crate's payout, called by its owner's client once the reveal has flown into them.
function CrateManager:ClaimCrateRewards(player: Player, uniqueId: string)
	if not validatePlayer(player) or typeof(uniqueId) ~= "string" then
		return
	end

	local spawnedCrate = self._spawned[uniqueId]
	if not spawnedCrate then
		return
	end

	-- UniqueId is a replicated attribute, so every client can read every crate's -- only the owner claims
	if spawnedCrate.Owner ~= player.UserId then
		return
	end

	-- Enforced here too -- the elapsed check below can't cover it, a fifteen-minute crate passing trivially
	local timeToOpen = spawnedCrate.Model:GetAttribute("TimeToOpen")
	if timeToOpen and workspace:GetServerTimeNow() < timeToOpen then
		return
	end

	-- An early claim is ignored rather than refused for good -- the fallback still hands the rewards over
	local crate = Crates.GetCrateFromId(spawnedCrate.CrateId)
	local elapsed = workspace:GetServerTimeNow() - spawnedCrate.SpawnedAt
	if elapsed < Crates.GetOpenDuration(crate, spawnedCrate.OpenIndex) - Crates.CLAIM_GRACE then
		return
	end

	-- Dropped before the grant yields, so a duplicated claim can't pay out twice
	self._spawned[uniqueId] = nil

	self:_grantCrateRewards(player, spawnedCrate)

	if spawnedCrate.Model.Parent then
		spawnedCrate.Model:Destroy()
	end
end

function CrateManager:_setupPlayer(player: Player)
	-- The signal only reports the top-level key, but the reconcile re-diffs everything anyway
	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "Crates", function()
		self:_reconcileTools(player)
	end)

	-- Every respawn clears the backpack and runtime tools aren't in StarterGear, so they're rebuilt
	player.CharacterAdded:Connect(function()
		self:_reconcileTools(player)
	end)

	self:_reconcileTools(player)
end

function CrateManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	IngredientManager = require(script.Parent.IngredientManager)
	StickManager = require(script.Parent.StickManager)
	NotificationManager = require(script.Parent.NotificationManager)
end

function CrateManager:OnStart()
	self.OpenCratesEvent:OnServerEvent(function(player: Player, crateId: string, count: number)
		self:RequestOpenCrates(player, crateId, count)
	end)

	self.ClaimCrateEvent:OnServerEvent(function(player: Player, uniqueId: string)
		self:ClaimCrateRewards(player, uniqueId)
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		self:_setupPlayer(player)
	end)

	-- Reconciling yields on the player's data, so sweep existing players off the main thread
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_setupPlayer(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		local listener = self._listeners[player]
		if listener then
			listener:Disconnect()
			self._listeners[player] = nil
		end

		self._pendingEquips[player] = nil
		self._pendingTallies[player] = nil
		self._openCooldowns[player] = nil
	end)
end

return CrateManager
