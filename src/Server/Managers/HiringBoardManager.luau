-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Replica = require(Packages.Replica)
local Signal = require(Packages.Signal)

-- Server
local Server = script.Parent.Parent
local Clock = require(Server.Modules.Clock)
local NpcRig = require(Server.Modules.NpcRig)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local RandomUtil = require(Shared.RandomUtil)
local GuiUtil = require(Shared.GuiUtil)
local Employees = require(Shared.Config.Employees)
local HiringBoard = require(Shared.Config.HiringBoard)
local Keywords = require(Shared.Config.Keywords)

-- Managers
local PlayerDataManager
local CurrencyManager
local EmployeeManager
local NotificationManager

-- Assets
local EmployeeFolder = ServerStorage.Assets:FindFirstChild("Employees")

--
local HiringBoardToken = Replica.Token("HiringBoard")

-- The tiers as the weighted draw wants them. Built once from the config's own order, since a dictionary's
-- order differs between servers and the whole point of the seed is that they agree
local TIER_WEIGHTS = {}

for _, tier in HiringBoard.TIERS do
	table.insert(TIER_WEIGHTS, { tier.Id, tier.Weight })
end

-- The worker board: four candidates rolled from the window's seed, so every server offers the same four, rotating on the same clock the shops rotate on. Nothing about a candidate is written down until someone hires them, at which point the roll is copied onto their record and is theirs for good.

--
local HiringBoardManager = {
	HireWorkerEvent = Network.Event("HireWorker"), -- client -> server (slotIndex)
	HireWorkerResultEvent = Network.Event("HireWorkerResult"), -- server -> client (success, slotIndex)

	OnWorkerHired = Signal.new(), -- (player, slotIndex, worker)

	_hiring = {}, -- [player] = true, held across the CanAfford -> DeductCurrency yield window
	_boardSeed = 0, -- the seed this window's four were rolled from: the clock's window seed strided
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Rolls a window's four candidates from its seed. One shared Random walked in a fixed order, so every server draws the same four in the same slots.
function HiringBoardManager:_rollWorkers(seed: number): { HiringBoard.Worker }
	local rng = Random.new(seed)
	local workers = {}

	-- No two on one board share a name, though each draws from the pool that suits its own body
	local used = {}

	for _ = 1, HiringBoard.ENTRY_COUNT do
		local role = Employees.ROLE_ORDER[rng:NextInteger(1, #Employees.ROLE_ORDER)]
		local tier = HiringBoard.GetTierFromId(RandomUtil.GetResultFromWeight(TIER_WEIGHTS, rng))
		local stars = HiringBoard.RollStars(tier, rng)
		local body = Employees.BODIES[rng:NextInteger(1, #Employees.BODIES)]

		-- Filtered rather than taken from one shared list, since each body has its own pool. Walked in the
		-- config's order, so the same seed lands on the same name wherever it's rolled
		local available = {}
		for _, candidate in Employees.GetNames(body) do
			if not used[candidate] then
				table.insert(available, candidate)
			end
		end

		local name = available[rng:NextInteger(1, #available)]
		used[name] = true

		-- One or the other, never both: a bonnet sitting on top of a fringe reads as a bug
		local hair, hat
		if RandomUtil.RollChance(Employees.HAT_CHANCE, rng) then
			hat = Employees.Cosmetics.Hats[rng:NextInteger(1, #Employees.Cosmetics.Hats)]
		else
			local styles = Employees.Cosmetics.Hair[body]
			hair = styles[rng:NextInteger(1, #styles)]
		end

		local heads = Employees.Cosmetics.Heads
		local tones = Employees.SKIN_TONES

		table.insert(workers, {
			Role = role,
			Tier = tier.Id,
			Stars = stars,
			Body = body,
			Name = name,
			Hair = hair,
			Hat = hat,
			Head = heads[rng:NextInteger(1, #heads)],
			Skin = tones[rng:NextInteger(1, #tones)],
			Price = HiringBoard.GetPrice(stars),
		})
	end

	return workers
end

-- Bakes one candidate's portrait, named for its slot so the client can match it to the entry it belongs on.
function HiringBoardManager:_bakePreview(worker: HiringBoard.Worker, index: number, seed: number): Model?
	local template = EmployeeFolder and EmployeeFolder:FindFirstChild(worker.Body)
	if not template then
		warn(`Assets.Employees.{worker.Body} is missing, worker {index} gets no portrait`)
		return nil
	end

	-- The roll carries its look at the top level, which is the same shape a hired record's Cosmetics takes
	local baked, err = NpcRig.BakePortrait(template, worker)

	if err then
		warn(`[HiringBoard] worker {index} couldn't be dressed: {err}`)
	end

	if not baked then
		return nil
	end

	baked.Name = tostring(index)

	-- Stamped before it's parented, so the seed lands on the client alongside the rig rather than behind it
	baked:SetAttribute(HiringBoard.SEED_ATTRIBUTE, seed)

	return baked
end

-- Rebuilds the four portraits for a window. Yields on every dress, so it's kept off the roll itself.
function HiringBoardManager:_publishPreviews(workers: { HiringBoard.Worker }, seed: number)
	self._previewFolder:ClearAllChildren()

	for index, worker in workers do
		local baked = self:_bakePreview(worker, index, seed)
		if not baked then
			continue
		end

		-- The window can have rolled over while the dress above yielded, and these are already stale
		if self._boardSeed ~= seed then
			baked:Destroy()
			return
		end

		baked.Parent = self._previewFolder
	end
end

-- Rolls a fresh board onto the replica. Writing the seed alongside is what resets the per-player Hired flags.
function HiringBoardManager:_applyBoard(seed: number)
	self._boardSeed = seed

	local workers = self:_rollWorkers(seed)

	self._replica:Set({ "Seed" }, seed)
	self._replica:Set({ "Workers" }, workers)

	-- Off the write, since dressing four rigs yields and the board's text shouldn't wait on their faces
	task.spawn(function()
		self:_publishPreviews(workers, seed)
	end)
end

-- This window's four, as the board is offering them.
function HiringBoardManager:GetWorkers(): { HiringBoard.Worker }
	return self._replica.Data.Workers
end

-- Hires the candidate in `slotIndex`, authoritative on the price, the hut and who's already taken it. The worker is read off the server's own roll -- the client sends a slot number and nothing else.
function HiringBoardManager:HireWorker(player: Player, slotIndex: number): boolean
	if not validatePlayer(player) then
		return false
	end

	-- CanAfford yields, so without this guard two rapid presses could both pass before either deducts
	if self._hiring[player] then
		return false
	end
	self._hiring[player] = true

	local worker = if type(slotIndex) == "number" then self:GetWorkers()[slotIndex] else nil
	if not worker then
		self._hiring[player] = nil
		return false
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._hiring[player] = nil
		return false
	end

	-- Reset the ledger on a rollover, so last window's hires can't lock this window's slots
	local currentSeed = self._boardSeed
	if data.HiringBoard.Seed ~= currentSeed then
		PlayerDataManager:SetPlayerDataKey(player, "HiringBoard", {
			Seed = currentSeed,
			Hired = table.create(HiringBoard.ENTRY_COUNT, false),
		})
	end

	if data.HiringBoard.Hired[slotIndex] then
		self._hiring[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = `You already hired {worker.Name}`,
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	-- Somewhere to put them first: the hut is what houses staff, so hiring without one buys nothing
	if not data.HutRepaired then
		self._hiring[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = "Repair your Worker Hut first!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	if not CurrencyManager:CanAfford(player, worker.Price) then
		self._hiring[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = `You can't afford {worker.Name}`,
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	CurrencyManager:DeductCurrency(player, worker.Price, "WorkerHire")

	EmployeeManager:HireEmployee(player, worker.Role, worker.Body, worker.Stars, {
		Name = worker.Name,
		Cosmetics = { Hair = worker.Hair, Hat = worker.Hat, Head = worker.Head, Skin = worker.Skin },
	})

	PlayerDataManager:SetPlayerDataKey(player, { "HiringBoard", "Hired", slotIndex }, true)
	self.OnWorkerHired:Fire(player, slotIndex, worker)

	self._hiring[player] = nil

	-- Every hire starts unequipped, so a hire with nothing to show for it would read as nothing happened
	NotificationManager:NotifyNormal(player, {
		-- The name takes the Workers keyword's colour, so it reads as one of them
		Text = `Hired {GuiUtil.Colorize(worker.Name, Keywords.Colors.Workers)}! Equip them at your Worker Hut`,
		Duration = 3,
		Sound = "Purchase",
		Effect = "Success",
	})

	return true
end

function HiringBoardManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	EmployeeManager = require(script.Parent.EmployeeManager)
	NotificationManager = require(script.Parent.NotificationManager)
end

function HiringBoardManager:OnStart()
	-- Where the dressed portraits are published. ReplicatedStorage rather than workspace, so they don't
	-- stream and a player joining halfway through a window still sees four faces
	self._previewFolder = Instance.new("Folder")
	self._previewFolder.Name = HiringBoard.PREVIEW_FOLDER
	self._previewFolder.Parent = ReplicatedStorage

	self._clock = Clock.new(HiringBoard.ROTATE_INTERVAL)

	-- One global replica of the window's seed and its four, subscribed to every present and future player
	self._boardSeed = self._clock.CurrentSeed * HiringBoard.SEED_STRIDE
	self._replica = Replica.New({
		Token = HiringBoardToken,
		Data = {
			Seed = self._boardSeed,
			Workers = self:_rollWorkers(self._boardSeed),
		},
	})
	self._replica:Replicate()

	task.spawn(function()
		self:_publishPreviews(self:GetWorkers(), self._boardSeed)
	end)

	-- Countdown for the board's own billboard: mirror the time left onto an attribute each second
	ReplicatedStorage:SetAttribute(HiringBoard.TIME_LEFT_ATTRIBUTE, self._clock.CurrentTime)
	self._clock.OnTimeChanged:Connect(function(timeLeft: number)
		ReplicatedStorage:SetAttribute(HiringBoard.TIME_LEFT_ATTRIBUTE, timeLeft)
	end)

	self._clock.Reached:Connect(function(seed: number)
		self:_applyBoard(seed * HiringBoard.SEED_STRIDE)

		NotificationManager:NotifyNormalAll({
			Text = "New Workers are looking for a job!",
			Duration = 5,
			Sound = "Restocked",
			Effect = "Success",
		})
	end)

	self.HireWorkerEvent:OnServerEvent(function(player: Player, slotIndex: number)
		local success = self:HireWorker(player, slotIndex)
		self.HireWorkerResultEvent:FireClient(player, success, slotIndex)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._hiring[player] = nil
	end)
end

return HiringBoardManager
