-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Modules
local NpcRig = require(script.Parent.Parent.Modules.NpcRig)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local FreeWorkers = require(Shared.Config.FreeWorkers)
local Keywords = require(Shared.Config.Keywords)

-- Managers
local PlayerDataManager
local EmployeeManager
local NotificationManager
local BaseManager

-- Assets
local EmployeeFolder = ServerStorage.Assets:FindFirstChild("Employees")

-- The three workers given away on the first open of a repaired hut. Nothing about them is written down: they're
-- rolled off the player's own UserId, so the same three come back every session until one is claimed, and
-- claiming is the one thing stored. The client draws the cards off the same roll and sends back a slot number.

--
local FreeWorkersManager = {
	ClaimFreeWorkerEvent = Network.Event("ClaimFreeWorker"), -- client -> server (slotIndex)
	ClaimFreeWorkerResultEvent = Network.Event("ClaimFreeWorkerResult"), -- server -> client (success, slotIndex)

	-- Opening carries nothing and a look carries only which card: whether the three are still theirs to take
	-- is read back off their data here, not taken from the client
	FreeWorkersOpenedEvent = Network.Event("FreeWorkersOpened", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 2 },
	}),
	FreeWorkerLookedAtEvent = Network.Event("FreeWorkerLookedAt", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 5 },
	}), -- client -> server (slotIndex)

	OnFreeWorkerClaimed = Signal.new(), -- (player, slotIndex, candidate)
	OnFreeWorkersOpened = Signal.new(), -- (player)
	OnFreeWorkerLookedAt = Signal.new(), -- (player, seen, total)

	_claiming = {}, -- [player] = true, held across the read -> write yield window
	_lookedAt = {}, -- [player] = { [slot] = true }, the cards turned over, so the count is the server's own
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Announces that the player was shown the three, which is the funnel's first step. Read without waiting, since the remote can land before their data has.
function FreeWorkersManager:RecordPanelOpened(player: Player)
	local data = PlayerDataManager:GetLoadedPlayerData(player)
	if not data or data.FreeWorkersClaimed then
		return
	end

	self.OnFreeWorkersOpened:Fire(player)
end

-- Marks one card as turned over and announces how many of the three they have seen. Counted here rather than sent, so the figure a funnel reads off it cannot be inflated from the client.
function FreeWorkersManager:RecordWorkerLookedAt(player: Player, slotIndex: number)
	if type(slotIndex) ~= "number" or not FreeWorkers.SLOT_ROLES[slotIndex] then
		return
	end

	local data = PlayerDataManager:GetLoadedPlayerData(player)
	if not data or data.FreeWorkersClaimed then
		return
	end

	local looked = self._lookedAt[player]
	if not looked then
		looked = {}
		self._lookedAt[player] = looked
	end

	-- A card turned over twice is the panel being reopened, and the funnel wants how many they have seen
	if looked[slotIndex] then
		return
	end
	looked[slotIndex] = true

	local seen = 0
	for _ in looked do
		seen += 1
	end

	self.OnFreeWorkerLookedAt:Fire(player, seen, #FreeWorkers.SLOT_ROLES)
end

-- Takes the free worker in `slotIndex`, authoritative on whether they may and on who that slot is. The candidate is re-rolled here off their UserId -- the client sends a slot number and nothing else.
function FreeWorkersManager:ClaimFreeWorker(player: Player, slotIndex: number): boolean
	if not validatePlayer(player) then
		return false
	end

	-- Reading their data yields, so without this guard two rapid presses could both pass before either writes
	if self._claiming[player] then
		return false
	end
	self._claiming[player] = true

	-- Anything can arrive over a remote, so the slot has to be one the panel actually offers
	if type(slotIndex) ~= "number" or not FreeWorkers.SLOT_ROLES[slotIndex] then
		self._claiming[player] = nil
		return false
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._claiming[player] = nil
		return false
	end

	-- Both are states the panel already prevents: it's only ever shown on a repaired hut, and a claim closes it
	-- for good. Reaching them means a forged call, so it's refused without a toast
	if not data.HutRepaired or data.FreeWorkersClaimed then
		self._claiming[player] = nil
		return false
	end

	local candidate = FreeWorkers.RollCandidates(player.UserId)[slotIndex]

	EmployeeManager:HireEmployee(player, candidate.Role, candidate.Body, candidate.Stars, {
		Name = candidate.Name,
		Cosmetics = candidate.Cosmetics,
	})

	PlayerDataManager:SetPlayerDataKey(player, "FreeWorkersClaimed", true)

	-- Nothing is ever drawn off them again, so the three faces go rather than sit in their PlayerGui
	local portraits = player.PlayerGui:FindFirstChild(FreeWorkers.PORTRAIT_FOLDER)
	if portraits then
		portraits:Destroy()
	end

	self.OnFreeWorkerClaimed:Fire(player, slotIndex, candidate)

	self._claiming[player] = nil

	-- Every hire starts unequipped, so a hire with nothing to show for it would read as nothing happened
	NotificationManager:NotifyNormal(player, {
		-- The name takes the Workers keyword's colour, so it reads as one of them
		Text = `Hired {GuiUtil.Colorize(candidate.Name, Keywords.Colors.Workers)}! Equip them at your Worker Hut`,
		Duration = 3,
		Sound = "Purchase",
		Effect = "Success",
	})

	return true
end

-- Dresses one candidate's portrait into its owner's PlayerGui, named for the card it belongs on. Yields on the dress, so callers spawn it.
function FreeWorkersManager:BakeCandidatePortrait(player: Player, slotIndex: number, candidate: FreeWorkers.Candidate)
	local template = EmployeeFolder and EmployeeFolder:FindFirstChild(candidate.Body)
	if not template then
		warn(`Assets.Employees.{candidate.Body} is missing, free worker {slotIndex} gets no portrait`)
		return
	end

	local baked, err = NpcRig.BakePortrait(template, candidate.Cosmetics)

	if err then
		warn(`[FreeWorkers] {candidate.Name}'s portrait couldn't be dressed: {err}`)
	end

	if not baked then
		return
	end

	-- The dress yields, and they can have left or claimed one in the meantime
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or data.FreeWorkersClaimed or not player.Parent then
		baked:Destroy()
		return
	end

	local folder = player.PlayerGui:FindFirstChild(FreeWorkers.PORTRAIT_FOLDER)
	if not folder then
		-- A ScreenGui rather than a Folder, so ResetOnSpawn can keep the portraits through a respawn
		folder = Instance.new("ScreenGui")
		folder.Name = FreeWorkers.PORTRAIT_FOLDER
		folder.ResetOnSpawn = false
		folder.Enabled = false
		folder.Parent = player.PlayerGui
	end

	-- Two bakes racing past the check in ResumePortraits both land here, so the later one replaces rather than doubles
	local stale = folder:FindFirstChild(tostring(slotIndex))
	if stale then
		stale:Destroy()
	end

	baked.Name = tostring(slotIndex)
	baked.Parent = folder
end

-- Dresses all three for a player still owed them, so the cards have faces waiting by the time the hut is opened.
function FreeWorkersManager:ResumePortraits(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or data.FreeWorkersClaimed then
		return
	end

	-- A second base handover bakes again, and one portrait per card is all the panel needs
	local existing = player.PlayerGui:FindFirstChild(FreeWorkers.PORTRAIT_FOLDER)

	for slotIndex, candidate in FreeWorkers.RollCandidates(player.UserId) do
		if existing and existing:FindFirstChild(tostring(slotIndex)) then
			continue
		end

		self:BakeCandidatePortrait(player, slotIndex, candidate)
	end
end

function FreeWorkersManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	EmployeeManager = require(script.Parent.EmployeeManager)
	NotificationManager = require(script.Parent.NotificationManager)
	BaseManager = require(script.Parent.BaseManager)
end

function FreeWorkersManager:OnStart()
	self.ClaimFreeWorkerEvent:OnServerEvent(function(player: Player, slotIndex: number)
		local success = self:ClaimFreeWorker(player, slotIndex)
		self.ClaimFreeWorkerResultEvent:FireClient(player, success, slotIndex)
	end)

	self.FreeWorkersOpenedEvent:OnServerEvent(function(player: Player)
		self:RecordPanelOpened(player)
	end)

	self.FreeWorkerLookedAtEvent:OnServerEvent(function(player: Player, slotIndex: number)
		self:RecordWorkerLookedAt(player, slotIndex)
	end)

	-- Off the handover rather than PlayerAdded, so the bake waits behind the load the rest of the hut waits on
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		task.spawn(function()
			self:ResumePortraits(player)
		end)
	end)

	-- This manager can load after a player is already on a base, so sweep whoever is here
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:ResumePortraits(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		self._claiming[player] = nil
		self._lookedAt[player] = nil
	end)
end

return FreeWorkersManager
