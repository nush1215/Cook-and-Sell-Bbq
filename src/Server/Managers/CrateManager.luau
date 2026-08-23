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

-- The ring the crates of one batch land in, and how many fit in the inner one before the rest spill
-- out to the outer.
local INNER_RADIUS = 10
local OUTER_RADIUS = 18
local PER_RING_MAX = 5

-- Seconds an owner's crate stays hidden before the server forces it visible. Its own client unhides
-- it the moment it picks it up to throw, so this only ever fires for a client that never got there.
local REVEAL_DELAY = 2

-- How long past its own animation a crate waits for its owner's claim before the server grants the
-- rewards itself.
local CLAIM_FALLBACK_DELAY = 5

--[[
    Crates: stacking backpack items that pay out several things at once.

    The inventory half is the same shape as every other stacking item in the game (see
    IngredientManager): player data is the only source of truth, nothing grants a tool directly, and
    any write to Crates re-runs a reconcile that diffs what the player owns against what's in their
    backpack. Stacking, respawn and rejoin all fall out of that one path.

    The open half is the interesting one. Opening consumes the crates up front and spawns one model
    per crate in a ring around the player, each carrying its already-rolled contents as a replicated
    attribute. Every client animates every crate off those attributes -- the throw, the twitch, the
    pop and the reveal are all local -- and the owner's client fires a claim once its animation is
    done, which is what actually grants.

    Rolling on spawn rather than on claim means the outcome is settled before a single frame of the
    show plays, so nothing a client does can change it. The trade is that the contents are readable
    early; that costs nothing here, since the count is already spent and there's no reroll to buy.

    A claim that never arrives doesn't cost the player anything either: every spawned crate carries a
    server-side fallback that hands the rewards over once its animation window has passed.
]]

--
type SpawnCrateData = {
	Owner: number?, -- the UserId whose client throws and claims this one
	OpenIndex: number?, -- its place in the batch, which is how long its client waits before throwing
	OpenCount: number?,
	-- The world-crate flags. Nothing sets these yet -- they're what the post-tutorial playtime crate
	-- needs: one that idles in place until something opens it, rather than being thrown and opened on
	-- arrival.
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
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Puts a tool straight into the player's hands, swapping out whatever they were holding. Nothing to
-- do if they're mid-respawn -- the reconcile the new character kicks off rebuilds their tools anyway.
local function equipTool(player: Player, tool: Tool)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:EquipTool(tool)
	end
end

-- Collects the player's crate tools, keyed by crate id. An equipped tool sits in the character rather
-- than the backpack, so both get scanned.
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

-- Where the crates of one batch land: a ring of up to PER_RING_MAX around the player, with the
-- overflow in a second, wider one. Every slot is dropped onto whatever ground is beneath it and
-- turned to face the player, so the row of rewards each crate reveals reads left to right across
-- their view rather than edge-on.
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

-- Builds the tool for one crate: an empty tagged tool carrying its id + count. The held visual is
-- drawn client-side by the HeldItem component off these attributes, and the backpack slot pops up a
-- tooltip in the crate's own colour.
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
			-- Data can hold an id the config no longer has, either removed outright or dropped at load
			-- because its model went missing from Assets.
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

-- Adds some of a crate to the player's owned count (default one), which the reconcile turns into a
-- backpack tool or a higher Count, equipped.
function CrateManager:GrantCrate(player: Player, crateId: string, amount: number?)
	local crate = Crates.GetCrateFromId(crateId)
	if not crate then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- Flagged before the write, since that's what runs the reconcile that builds the tool to equip.
	self._pendingEquips[player] = crateId

	local owned = data.Crates[crateId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "Crates", crateId }, owned + (amount or 1))
end

-- Takes some of the player's owned crates of a kind (default one), which the reconcile turns into a
-- lower Count or a destroyed tool.
function CrateManager:ConsumeCrate(player: Player, crateId: string, amount: number?)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local owned = data.Crates[crateId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "Crates", crateId }, math.max(0, owned - (amount or 1)))
end

-- Rolls one crate's whole payout, in the order its groups are authored -- which is the order the
-- reveal lays them out in, so the stick ends up on the end of the row and is the last thing granted.
-- One Random is drawn through every slot; passing a raw seed per call would re-seed and make every
-- draw come out the same.
function CrateManager:RollCrateContents(crate: Crates.Crate, rng: Random): { Crates.Reward }
	local rewards = {}

	for _, group in crate.Contents do
		local taken = {}

		for _ = 1, group.Count do
			-- A Distinct group draws without replacement, so its pool is rebuilt for each slot with what
			-- it has already given left out. Rebuilt rather than edited because the config's own table is
			-- shared by every crate ever opened. The entry itself is what's weighted, not its id, because
			-- a mixed group's entries carry their own Type and an id alone couldn't say which config it
			-- came from -- which is also what makes taken safe to key on across the two rosters.
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

-- Hands the player everything one crate rolled and tells them what they got in a single line, rather
-- than one toast per reward. Reached from the owner's claim and from the fallback below, so it must
-- stay safe to reach exactly once per crate -- both callers drop the crate from _spawned first.
--
-- Granted in the order the rewards were rolled, which is the order the config authors them and the
-- order the reveal laid them out. Every grant equips what it handed over, so the player ends up
-- holding the last of them: on a crate authored as a group per kind that's the last group's reward,
-- and on a mixed pool there's no such last group to lean on, so it's whatever its final slot rolled.
function CrateManager:_grantCrateRewards(player: Player, spawnedCrate: SpawnedCrate)
	local crate = Crates.GetCrateFromId(spawnedCrate.CrateId)
	local names = {}

	for _, reward in spawnedCrate.Rewards do
		if reward.Type == "Ingredient" then
			local ingredient = Ingredients.GetIngredientFromId(reward.Id)
			IngredientManager:GrantIngredient(player, reward.Id)
			table.insert(names, GuiUtil.Colorize(ingredient.Name, ingredient.Color))
		else
			local stick = Sticks.GetStickFromId(reward.Id)
			StickManager:GrantStick(player, reward.Id)
			table.insert(names, GuiUtil.Colorize(`{stick.Name} Stick`, stick.TextColor))
		end
	end

	NotificationManager:NotifyNormal(player, {
		Text = `Opened a {GuiUtil.Colorize(crate.Name, crate.Color)} and got {table.concat(names, ", ")}`,
		Duration = 5,
		Sound = "CollectedReward",
		Effect = "Success",
	})
end

-- Puts one crate into the world with its payout already rolled and stamped onto it, and returns the
-- id a claim names it by.
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

	-- Shipped as an attribute rather than over a remote, the same way a stand's placed skewers are: a
	-- remote naming a freshly-parented model can beat the model itself to the client, and every client
	-- needs the contents to draw the reveal.
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

	-- The crate is moved by pivoting it every frame, so nothing here may be simulated -- an unanchored
	-- one would fight the animation and fall through the floor between beats.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
		end
	end

	-- An owner's crate is thrown out of their hands, so it must not flash on its ground slot first.
	-- Their client unhides it the moment it takes it to the throw start; this is the fallback for a
	-- client that never got there.
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

	-- The rewards are already the player's -- the crate came out of their data before any of this ran.
	-- If their own client never claims (it crashed, it never loaded the model, its claim landed early
	-- and was ignored) the server hands them over anyway rather than eating the crate.
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

-- Opens up to `count` of the player's crates: takes them out of their data and lays that many out in
-- a ring around them for their client to throw and open.
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

	-- Debounced on the client too, for the instant feedback; this is the authoritative one. Both the
	-- check and the stamp happen before the data read below, since that yields -- two requests either
	-- side of it would otherwise both pass.
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

-- Hands a crate that was spawned without an owner over to one, and starts the clock on its claim.
-- A crate thrown out of someone's hands has an owner from the moment it exists; one that crashed in
-- and waited to be opened only gets one when somebody opens it -- which is also the first moment it's
-- worth arming the fallback, since until then it isn't going anywhere.
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

	-- UniqueId rides on the model as a replicated attribute, so every client can read every crate's.
	-- Only the owner gets to claim theirs.
	if spawnedCrate.Owner ~= player.UserId then
		return
	end

	-- A crate that crashed in holds out until its countdown is up, and the countdown is the whole
	-- point of it -- so it's enforced here as well as at the open request. The elapsed check below
	-- can't cover this: by the time a fifteen-minute crate is opened it passes that trivially.
	local timeToOpen = spawnedCrate.Model:GetAttribute("TimeToOpen")
	if timeToOpen and workspace:GetServerTimeNow() < timeToOpen then
		return
	end

	-- A claim can't beat the animation it's supposed to be the end of. An early one is left where it
	-- is rather than turned away for good -- the fallback still hands the rewards over.
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
	-- The signal only reports the top-level key, so it can't say which crate moved. The reconcile
	-- re-diffs everything anyway, so it doesn't need to know.
	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "Crates", function()
		self:_reconcileTools(player)
	end)

	-- CharacterAutoLoads is off and Base drives every respawn through LoadCharacterAsync, which clears
	-- the backpack. Runtime tools aren't in StarterGear, so rebuild them on each spawn.
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
		self._openCooldowns[player] = nil
	end)
end

return CrateManager
