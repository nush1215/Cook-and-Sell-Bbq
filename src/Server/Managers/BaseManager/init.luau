-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local BaseUnlocks = require(Shared.Config.BaseUnlocks)
local Plots = require(Shared.Config.Plots)
local Structures = require(Shared.Config.Structures)

-- Managers
local StickStandManager = require(script.Parent.StickStandManager)
local GrillerManager = require(script.Parent.GrillerManager)

-- Modules
local Base = require(script.Base)

--
local PlayerDataManager
local CurrencyManager
local NotificationManager
local ShopManager
local BuildManager

-- Per category: the data key holding a structure's contents and the manager that hands them back on pickup
local STRUCTURE_CONTENTS = {
	Grillers = { Key = "Grillers", Manager = GrillerManager },
	StickStands = { Key = "StickStands", Manager = StickStandManager },
}

--
local BaseManager = {
	PurchaseUnlockUpgradeEvent = Network.Event("PurchaseUnlockUpgrade"),
	PurchasePlotEvent = Network.Event("PurchasePlot"),
	RequestPlotProductEvent = Network.Event("RequestPlotProduct"),

	OnBaseAssigned = Signal.new(),
	-- (player, unlockId, newLevel, cost, method) on an unlock buy; newLevel 1 is a first unlock
	OnUnlockPurchased = Signal.new(),
	-- (player, plotId, newCount, cost, method) on a plot buy; newCount prices the next one
	OnPlotPurchased = Signal.new(),
	-- (player, structureType) on a place or pickup. No price -- a structure was paid for when it was bought
	OnStructurePlaced = Signal.new(),
	OnStructureRemoved = Signal.new(),

	_bases = {},
	_listeners = {}, -- [player] = { the Unlocks, Plots and Structures data listeners }
	_purchasing = {}, -- [player] = true, held across the data read -> DeductCurrency window
	_pendingPlot = {}, -- [player] = the plot their open plot Robux prompt was raised from
}

-- Returns the base the player currently owns, if they have one.
function BaseManager:GetBaseFromPlayer(player: Player)
	for _, base in self._bases do
		if base:GetOwner() == player then
			return base
		end
	end

	return nil
end

-- Gives the player the first free base and spawns them on it.
function BaseManager:AssignBaseToPlayer(player: Player)
	-- Read first, since the base needs their unlocks; the guard sits after it because this yields
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return nil
	end

	-- A player joining between the connect and the sweep in OnInit reaches here twice.
	local ownedBase = self:GetBaseFromPlayer(player)
	if ownedBase then
		return ownedBase
	end

	for _, base in self._bases do
		if base:GetOwner() then
			continue
		end

		-- Before assigning, since AssignOwner yields; `data` is the live replica table it reads below
		self._listeners[player] = {
			PlayerDataManager:ListenForChanges(player, "Unlocks", function()
				self:RefreshBaseUnlocksForPlayer(player)
			end),
			PlayerDataManager:ListenForChanges(player, "Plots", function()
				self:RefreshBasePlotsForPlayer(player)
			end),
			PlayerDataManager:ListenForChanges(player, "Structures", function()
				self:RefreshBaseStructuresForPlayer(player)
			end),
		}

		base:AssignOwner(player, data.Unlocks, data.Plots, data.Structures)
		self.OnBaseAssigned:Fire(player, base)

		return base
	end

	warn(`[BaseManager] No free base available for {player.Name}`)
	return nil
end

-- Re-renders at the owner's unlock levels. Only off an actual change, so it animates.
function BaseManager:RefreshBaseUnlocksForPlayer(player: Player)
	local base = self:GetBaseFromPlayer(player)
	if not base then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	base:ApplyUnlocks(data.Unlocks, true)
end

-- Re-renders the owner's plots. Only off an actual change, so the bought plot burns its overgrowth back.
function BaseManager:RefreshBasePlotsForPlayer(player: Player)
	local base = self:GetBaseFromPlayer(player)
	if not base then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	base:ApplyPlots(data.Plots, true)
end

-- Buys one plot; the data write re-renders the base. Priced off how many they own, so the only choice is where.
function BaseManager:PurchasePlot(player: Player, plotId: string, skipCurrencyCost: boolean?): boolean
	-- The id comes off a remote, so it can be anything.
	if not Plots.IsPlot(plotId) then
		return false
	end

	-- Shared with the unlock purchase: both read then spend, so interleaving could double-spend one balance
	if self._purchasing[player] then
		if not skipCurrencyCost then
			return false
		end

		-- Leaving is checked too, so a guard stranded by an error can't spin this thread past its session.
		repeat
			task.wait()
		until not self._purchasing[player] or not player:IsDescendantOf(Players)

		if not player:IsDescendantOf(Players) then
			return false
		end
	end
	self._purchasing[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._purchasing[player] = nil
		return false
	end

	-- Re-checked, or a crafted call could name a far corner at the opening price
	if not Plots.IsAvailable(plotId, data.Plots) then
		self._purchasing[player] = nil
		return false
	end

	local unlockedCount = Plots.GetUnlockedCount(data.Plots)
	local cost = Plots.GetCost(unlockedCount)
	if not cost then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = "You already own every plot!",
			Duration = 3,
			Sound = "Reject",
		})
		return false
	end

	if not skipCurrencyCost then
		-- Read off the data already fetched, since TutorialManager is awaiting the same key
		if not data.TutorialCompleted then
			self._purchasing[player] = nil
			NotificationManager:NotifyNormal(player, {
				Text = "Finish the tutorial first!",
				Effect = "Error",
				Duration = 3,
				Sound = "Reject",
			})
			return false
		end

		local canAfford = CurrencyManager:CanAfford(player, cost)
		if not canAfford then
			self._purchasing[player] = nil
			NotificationManager:NotifyNormal(player, {
				Text = "You can't afford this plot!",
				Effect = "Error",
				Duration = 3,
				Sound = "Reject",
			})
			return false
		end

		CurrencyManager:DeductCurrency(player, cost, "PlotUnlock")
	end

	PlayerDataManager:SetPlayerDataKey(player, { "Plots", plotId }, true)

	-- Off the two reads rather than re-counted, so it doesn't depend on when the write lands
	self.OnPlotPurchased:Fire(
		player,
		plotId,
		unlockedCount + 1,
		if skipCurrencyCost then 0 else cost,
		if skipCurrencyCost then "Robux" else "Currency"
	)

	self._purchasing[player] = nil

	NotificationManager:NotifyNormal(player, {
		Text = "Plot Unlocked!",
		Duration = 3,
		Sound = "BasePurchase",
		Effect = "Success",
	})

	return true
end

-- Raises the Robux prompt for a reachable plot, remembering which here since the receipt names only the buyer.
function BaseManager:PromptPlotProduct(player: Player, plotId: string)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	if not Plots.IsAvailable(plotId, data.Plots) then
		return
	end

	local count = Plots.GetUnlockedCount(data.Plots)
	if not Plots.GetCost(count) then
		NotificationManager:NotifyNormal(player, {
			Text = "You already own every plot!",
			Duration = 3,
			Sound = "Reject",
		})
		return
	end

	self._pendingPlot[player] = plotId
	ShopManager:AttemptProductPurchase(player, Plots.GetProductStringId(count + 1))
end

-- Grants a plot once its product clears, falling back to whatever is reachable now rather than dropping a paid purchase.
function BaseManager:GrantPlotFromProduct(player: Player)
	local plotId = self._pendingPlot[player]
	self._pendingPlot[player] = nil

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	if not plotId or not Plots.IsAvailable(plotId, data.Plots) then
		plotId = nil

		-- Lowest-numbered first, so a fallback is at least predictable to a player watching it land
		for _, row in Plots.Grid do
			for _, candidateId in row do
				if not Plots.IsAvailable(candidateId, data.Plots) then
					continue
				end

				if not plotId or tonumber(candidateId) < tonumber(plotId) then
					plotId = candidateId
				end
			end
		end

		if not plotId then
			warn(`[BaseManager] {player.Name} bought a plot with none left to spend it on`)
			return
		end
	end

	self:PurchasePlot(player, plotId, true)
end

-- Re-renders the owner's build. Only off an actual change, so a placement drops in rather than popping.
function BaseManager:RefreshBaseStructuresForPlayer(player: Player)
	local base = self:GetBaseFromPlayer(player)
	if not base then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	base:RenderStructures(data.Structures, true)
end

-- Places one of the player's structures on `cell`. Every argument comes off a remote; only the checked cells are stored.
function BaseManager:PlaceStructureOnBase(
	player: Player,
	structureType: string,
	cellX: number,
	cellZ: number,
	rotation: number
): boolean
	local structure = Structures.GetStructureFromId(structureType)
	if not structure then
		return false
	end

	local base = self:GetBaseFromPlayer(player)
	if not base then
		return false
	end

	-- Shared with the purchases, since all three read then spend. A losing placement is simply dropped
	if self._purchasing[player] then
		return false
	end
	self._purchasing[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._purchasing[player] = nil
		return false
	end

	-- The tool only exists while the count is above zero, so a request without one is forged
	if (data.OwnedStructures[structureType] or 0) <= 0 then
		self._purchasing[player] = nil
		return false
	end

	rotation = math.floor(rotation) % 4
	local footprintX, footprintZ = Structures.GetFootprint(structure, rotation)

	if not base:IsBlockFree(cellX, cellZ, footprintX, footprintZ, data.Structures, data.Plots) then
		self._purchasing[player] = nil
		return false
	end

	BuildManager:ConsumeStructure(player, structureType)

	-- Minted once -- it keys the structure and its contents, so it must outlive a rejoin's rebuild
	local uid = HttpService:GenerateGUID(false)

	PlayerDataManager:SetPlayerDataKey(player, { "Structures", uid }, {
		Type = structureType,
		CellX = cellX,
		CellZ = cellZ,
		Rotation = rotation,
	})

	self._purchasing[player] = nil

	self.OnStructurePlaced:Fire(player, structureType)

	return true
end

-- Takes a structure back, returning it and its contents. The owning manager is asked first, since it can refuse.
function BaseManager:RemoveStructureFromBase(player: Player, uid: string): boolean
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return false
	end

	-- Read off their build rather than the world, which proves the structure exists and is theirs in one
	local structure = data.Structures[uid]
	if not structure then
		return false
	end

	local config = Structures.GetStructureFromId(structure.Type)
	local contents = config and STRUCTURE_CONTENTS[config.Category]

	-- Read before the write, which tears the model down. A legacy string entry reads as empty
	local record = contents and data[contents.Key][uid]
	if type(record) ~= "table" then
		record = nil
	end

	-- Handed back first, being the one step that can turn the pickup down
	if record and not contents.Manager:ReturnContentsToPlayer(player, data, uid, record, true) then
		return false
	end

	PlayerDataManager:SetPlayerDataKey(player, { "Structures", uid }, nil)

	if contents then
		PlayerDataManager:SetPlayerDataKey(player, { contents.Key, uid }, nil)
	end

	-- Only for a structure the config still has -- one that's gone would be an item that does nothing
	if config then
		BuildManager:GrantStructure(player, structure.Type)
	end

	self.OnStructureRemoved:Fire(player, structure.Type)

	return true
end

-- Buys the next slot of an unlock group; the data write re-renders the base through the listener.
function BaseManager:PurchaseUnlockUpgrade(player: Player, unlockId: string, skipCurrencyCost: boolean?): boolean
	-- The id comes off a remote, so it can be anything.
	local unlock = BaseUnlocks.GetUnlockFromId(unlockId)
	if not unlock then
		return false
	end

	-- The reads yield, so two purchases could read the same level. A Robux one waits rather than dropping
	if self._purchasing[player] then
		if not skipCurrencyCost then
			return false
		end

		-- Leaving is checked too, so a guard stranded by an error can't spin this thread past its session.
		repeat
			task.wait()
		until not self._purchasing[player] or not player:IsDescendantOf(Players)

		if not player:IsDescendantOf(Players) then
			return false
		end
	end
	self._purchasing[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._purchasing[player] = nil
		return false
	end

	-- Past the limit, or the last cost, is fully upgraded
	local nextLevel = (data.Unlocks[unlockId] or 0) + 1
	local cost = unlock.Costs[nextLevel]
	if nextLevel > unlock.Limit or not cost then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = "That's already fully upgraded!",
			Duration = 3,
			Sound = "Reject",
		})
		return false
	end

	if not skipCurrencyCost then
		-- Held through the tutorial, whose beats are timed against these levels
		if unlock.TutorialLocked and not data.TutorialCompleted then
			self._purchasing[player] = nil
			NotificationManager:NotifyNormal(player, {
				Text = "Finish the tutorial first!",
				Effect = "Error",
				Duration = 3,
				Sound = "Reject",
			})
			return false
		end

		local canAfford = CurrencyManager:CanAfford(player, cost)
		if not canAfford then
			self._purchasing[player] = nil
			NotificationManager:NotifyNormal(player, {
				Text = "You can't afford this upgrade!",
				Effect = "Error",
				Duration = 3,
				Sound = "Reject",
			})
			return false
		end

		CurrencyManager:DeductCurrency(player, cost, "BaseUnlock")
	end

	PlayerDataManager:SetPlayerDataKey(player, { "Unlocks", unlockId }, nextLevel)
	self.OnUnlockPurchased:Fire(
		player,
		unlockId,
		nextLevel,
		if skipCurrencyCost then 0 else cost,
		if skipCurrencyCost then "Robux" else "Currency"
	)

	self._purchasing[player] = nil

	-- Only the Sauce Dispenser starts at level 0, so its first purchase is a genuine unlock
	NotificationManager:NotifyNormal(player, {
		Text = if nextLevel == 1 then `{unlock.Name} Unlocked!` else `{unlock.Name} Upgraded!`,
		Duration = 3,
		Sound = unlock.Sound,
		Effect = "Success",
	})

	return true
end

-- Releases the player's base back into the free pool.
function BaseManager:UnassignBaseFromPlayer(player: Player)
	local base = self:GetBaseFromPlayer(player)
	if not base then
		return
	end

	-- Owning a base is what registers the listeners, so there are always some to drop here
	for _, listener in self._listeners[player] do
		listener:Disconnect()
	end
	self._listeners[player] = nil

	base:ClearOwner()
end

function BaseManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	NotificationManager = require(script.Parent.NotificationManager)
	ShopManager = require(script.Parent.ShopManager)
	-- Required here because BuildManager requires this manager back
	BuildManager = require(script.Parent.BuildManager)

	for _, model in workspace.Base:GetChildren() do
		table.insert(self._bases, Base.new(model))
	end

	Players.PlayerAdded:Connect(function(player: Player)
		self:AssignBaseToPlayer(player)
	end)

	-- Assigning yields, so sweep existing players off the main thread rather than stalling the loader
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:AssignBaseToPlayer(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		self:UnassignBaseFromPlayer(player)
		self._purchasing[player] = nil
		self._pendingPlot[player] = nil
	end)
end

function BaseManager:OnStart()
	self.PurchaseUnlockUpgradeEvent:OnServerEvent(function(player: Player, unlockId: string)
		self:PurchaseUnlockUpgrade(player, unlockId)
	end)

	self.PurchasePlotEvent:OnServerEvent(function(player: Player, plotId: string)
		self:PurchasePlot(player, plotId)
	end)

	self.RequestPlotProductEvent:OnServerEvent(function(player: Player, plotId: string)
		self:PromptPlotProduct(player, plotId)
	end)
end

return BaseManager
