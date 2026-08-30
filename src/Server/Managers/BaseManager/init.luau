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

-- Per category: the data key holding whatever sits on that kind of structure, and the manager that hands
-- it back. Both are keyed by the structure's uid, so taking one down must return its contents rather than
-- bin them. Delegating to the manager keeps this file from having to know what a stand or griller holds.
-- A category that can't hold anything simply isn't listed.
local STRUCTURE_CONTENTS = {
	Grillers = { Key = "Grillers", Manager = GrillerManager },
	StickStands = { Key = "StickStands", Manager = StickStandManager },
}

--
local BaseManager = {
	PurchaseUnlockUpgradeEvent = Network.Event("PurchaseUnlockUpgrade"),
	PurchasePlotEvent = Network.Event("PurchasePlot"),
	RequestPlotProductEvent = Network.Event("RequestPlotProduct"),

	--
	OnBaseAssigned = Signal.new(),
	-- (player, unlockId, newLevel, cost, method) when an unlock slot is bought. newLevel 1 is a first
	-- unlock. method is "Currency" or "Robux"; cost is 0 on a Robux buy.
	OnUnlockPurchased = Signal.new(),
	-- (player, plotId, newCount, cost, method) when a plot is bought. newCount is what the next one is
	-- priced off. method is "Currency" or "Robux"; cost is 0 on a Robux buy.
	OnPlotPurchased = Signal.new(),
	-- (player, structureType) when a structure is put down or taken back up. No level, count or price:
	-- a build is a set of things in places, and a structure was paid for when it was bought.
	OnStructurePlaced = Signal.new(),
	OnStructureRemoved = Signal.new(),

	--
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
	-- Read before claiming anything: the base needs their unlocks before it goes up, and since this yields
	-- the guard below has to sit after it or two calls each take a base.
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

		-- Before assigning, since AssignOwner yields on LoadCharacterAsync. Anything bought in that window
		-- still lands: `data` is the live replica table AssignOwner reads below.
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

-- Re-renders the owner's base at their current unlock levels. Only runs off an actual change, so it
-- animates -- unlike the instant render a base does on assignment.
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

-- Re-renders the owner's plots. Like the unlocks above, only off an actual change, so it animates --
-- the plot bought here burns its overgrowth back.
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

-- Buys one plot, clearing its overgrowth. Nothing here moves anything: the data write re-renders the base
-- through the listener AssignBaseToPlayer set up. The price comes off how many they already own, so every
-- plot on offer costs the same and the only decision is where to expand.
-- @param skipCurrencyCost Grant without charging, for a plot already paid for in Robux. Everything else
-- -- the reachability check, the write, the signal, the toast -- is wanted on both paths.
function BaseManager:PurchasePlot(player: Player, plotId: string, skipCurrencyCost: boolean?): boolean
	-- The id comes off a remote, so it can be anything.
	if not Plots.IsPlot(plotId) then
		return false
	end

	-- Shared with the unlock purchase below: both read data then spend against it, so interleaving them
	-- across their yields could double-spend one balance.
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

	-- Re-checked rather than trusted: the remote takes an id, so nothing stops a crafted call naming a
	-- far corner at the opening price.
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
		-- The tutorial spends against this same balance beat by beat, and a plot bought part-way through
		-- can leave it short of the ingredient it's about to ask for. Read off the data already fetched
		-- above rather than asked of TutorialManager, which is awaiting the same key.
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

	-- Off the read above plus this one rather than re-counted, so it doesn't depend on when the write
	-- lands in the replica table.
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

-- Raises the Robux prompt for one of the player's reachable plots. Which plot is remembered here rather
-- than carried on the product: it's priced by how many they own, and the receipt names only the buyer.
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

-- Grants a plot once a plot product clears (fired by ShopManager), to the plot the prompt was raised from.
-- An unanswered receipt is re-processed on a later join with no pending plot, and a reachable plot can be
-- bought before the answer lands -- either way it falls back to whatever is reachable now, rather than
-- dropping a purchase already charged for.
function BaseManager:GrantPlotFromProduct(player: Player)
	local plotId = self._pendingPlot[player]
	self._pendingPlot[player] = nil

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	if not plotId or not Plots.IsAvailable(plotId, data.Plots) then
		plotId = nil

		-- Lowest-numbered first, so a fallback is at least predictable to a player watching it land.
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

-- Re-renders the owner's build. Like the unlocks above, only off an actual change, so it animates --
-- a structure placed here drops into its spot rather than popping in.
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

-- Puts one of the player's structures on the given cell. Nothing here touches the world: the data write
-- renders it through the listener AssignBaseToPlayer set up. Spends from their inventory rather than their
-- balance -- a structure is paid for once and moves freely after (see BuildManager).
--
-- Every argument comes off a remote, so none is trusted. Only the cells are stored, which is exactly what
-- was checked, so a build can never come back on a rejoin somewhere it wouldn't have been allowed.
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

	-- Shared with the plot and unlock purchases: all three read data then spend against it, so
	-- interleaving could spend the same thing twice. A placement that loses the race is simply dropped --
	-- unlike a Robux purchase there's nothing already paid for to wait its turn.
	if self._purchasing[player] then
		return false
	end
	self._purchasing[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._purchasing[player] = nil
		return false
	end

	-- What makes this a placement rather than a way to conjure structures: the tool only exists while the
	-- count is above zero, so a client sending this without one is forging the request.
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

	-- Minted once: it keys the structure and everything sitting on it, so it has to outlive the model
	-- being rebuilt on a rejoin.
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

-- Takes a structure back off the base, returning both it and whatever sat on it to the inventory. Clearing
-- that second record is what stops a griller taken down with a BBQ on it stranding the record under a uid
-- nothing can reach; handing the contents back first is what stops that losing what they paid for.
--
-- A lit griller settles its cook where it had got to, so a pickup never dodges a burn nor loses a cook.
-- The owning manager can refuse (a cook already being stopped by hand), and it's asked before anything is
-- written -- otherwise the pickup would be left half done, structure gone and cook nowhere.
function BaseManager:RemoveStructureFromBase(player: Player, uid: string): boolean
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return false
	end

	-- The uid comes off a remote. Reading it off their build rather than the world proves the structure
	-- exists and is theirs in one.
	local structure = data.Structures[uid]
	if not structure then
		return false
	end

	local config = Structures.GetStructureFromId(structure.Type)
	local contents = config and STRUCTURE_CONTENTS[config.Category]

	-- Read before anything is written, since clearing the structure below tears its model down. A legacy
	-- string-shaped entry (from before ingredients existed) reads as empty rather than erroring.
	local record = contents and data[contents.Key][uid]
	if type(record) ~= "table" then
		record = nil
	end

	-- Handed back first because it's the one step that can turn the pickup down.
	if record and not contents.Manager:ReturnContentsToPlayer(player, data, uid, record, true) then
		return false
	end

	PlayerDataManager:SetPlayerDataKey(player, { "Structures", uid }, nil)

	if contents then
		PlayerDataManager:SetPlayerDataKey(player, { contents.Key, uid }, nil)
	end

	-- Only for a structure the config still has: one whose model went missing can't be re-placed, so
	-- handing it back would be an item that does nothing.
	if config then
		BuildManager:GrantStructure(player, structure.Type)
	end

	self.OnStructureRemoved:Fire(player, structure.Type)

	return true
end

-- Buys the next slot of one unlock group. Nothing here touches the world: the data write re-renders the
-- base through the listener AssignBaseToPlayer set up.
-- @param skipCurrencyCost Grant without charging, for a slot already paid for in Robux. Everything else
-- -- the limit check, the write, the signal, the toast -- is wanted on both paths.
function BaseManager:PurchaseUnlockUpgrade(player: Player, unlockId: string, skipCurrencyCost: boolean?): boolean
	-- The id comes off a remote, so it can be anything.
	local unlock = BaseUnlocks.GetUnlockFromId(unlockId)
	if not unlock then
		return false
	end

	-- The reads below yield, so without this two purchases landing together would read the same level and
	-- write the same next one. A currency buy that loses the race is dropped; a Robux one has already been
	-- charged, so it waits its turn.
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

	-- Past the limit (or the last cost) is fully upgraded.
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
		-- Held until the run is done: the tutorial's own beats are timed against these levels -- the settle
		-- window step 6 waits out is read off the roll speed -- so upgrading mid-run moves the goalposts
		-- under a beat that's already waiting on them.
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

	-- Only the Sauce Dispenser starts at level 0, so its first purchase is a genuine unlock.
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

	-- Owning a base is what registers the listeners, so there are always some to drop here.
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
	-- Required here rather than at the top because BuildManager requires this manager back: it owns the
	-- structures a player is carrying, and this owns where they go once they're put down.
	BuildManager = require(script.Parent.BuildManager)

	for _, model in workspace.Base:GetChildren() do
		table.insert(self._bases, Base.new(model))
	end

	Players.PlayerAdded:Connect(function(player: Player)
		self:AssignBaseToPlayer(player)
	end)

	-- Assigning yields on the player's data and on their character loading, so sweep existing
	-- players off the main thread rather than stalling the rest of the loader behind them.
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
