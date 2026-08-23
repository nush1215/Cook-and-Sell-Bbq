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

-- Modules
local Base = require(script.Base)

--
local PlayerDataManager
local CurrencyManager
local NotificationManager
local ShopManager
local BuildManager

-- The player-data key holding whatever sits on a structure of each kind, keyed by category. Both are
-- keyed by the structure's uid, so taking a structure down has to take its contents with it. A
-- category that can't hold anything simply isn't listed.
local STRUCTURE_CONTENTS = {
	Grillers = "Grillers",
	StickStands = "StickStands",
}

--
local BaseManager = {
	PurchaseUnlockUpgradeEvent = Network.Event("PurchaseUnlockUpgrade"),
	PurchasePlotEvent = Network.Event("PurchasePlot"),
	RequestPlotProductEvent = Network.Event("RequestPlotProduct"),

	--
	OnBaseAssigned = Signal.new(),
	-- (player, unlockId, newLevel, cost, method) when a slot of an unlock group is bought. newLevel 1 is
	-- a first unlock, anything higher an upgrade. method is "Currency" or "Robux"; cost is the currency
	-- paid, 0 on a Robux buy.
	OnUnlockPurchased = Signal.new(),
	-- (player, plotId, newCount, cost, method) when a plot is bought. newCount is how many they own
	-- after it, which is what the next one is priced off. method is "Currency" or "Robux"; cost is the
	-- currency paid, 0 on a Robux buy.
	OnPlotPurchased = Signal.new(),
	-- (player, structureType) when a structure is put down, and again when one is taken back up.
	-- Unlike the two above neither carries a level, a count or a price: a build is a set of things in
	-- places rather than a rung on a ladder, and the structure was paid for when it was bought rather
	-- than when it was placed -- so how many of a thing someone has is only ever read off their data.
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
	-- The base has to know their unlocks before it goes up, so the owner never watches their stands
	-- pop in. Read before claiming anything: this yields, and the guard below has to sit after it or
	-- two calls both pass it and take a base each.
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

		-- Listen before assigning: AssignOwner yields on LoadCharacterAsync. An upgrade, a plot bought or
		-- a structure placed in that window still lands, since data is the live replica table AssignOwner
		-- reads below.
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

-- Re-renders the base the player owns from their current unlock levels. This only runs off an actual
-- change to Unlocks, so the render animates -- a slot bought here plants its sign rather than popping
-- it in, while the render a base does on assignment stays instant.
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

-- Re-renders the plots on the base the player owns from their current set. Like the unlocks above
-- this only runs off an actual change, so the render animates -- the plot bought here burns its
-- overgrowth back, while the render a base does on assignment stays instant.
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

-- Buys one plot on the player's base, clearing its overgrowth and opening up whatever it touches.
-- Nothing here moves anything: the data write re-renders the base through the listener
-- AssignBaseToPlayer set up.
--
-- Which plot is the player's choice, but the price isn't -- it comes off how many they already own,
-- so every plot on offer costs the same and the decision is only where to expand.
-- @param skipCurrencyCost Grant the plot without charging for it, for one already paid for in Robux
-- (see the plot products in Config/Products). Everything else -- the reachability check, the data
-- write, the signal and the notification -- is wanted on both paths, so only the charge differs.
function BaseManager:PurchasePlot(player: Player, plotId: string, skipCurrencyCost: boolean?): boolean
	-- The id comes off a remote, so it can be anything.
	if not Plots.IsPlot(plotId) then
		return false
	end

	-- Shared with the unlock purchase below on purpose: both read the player's data and then spend
	-- against it, so letting the two interleave across their yields could double-spend one balance.
	if self._purchasing[player] then
		if not skipCurrencyCost then
			return false
		end

		-- Leaving is checked as well as the guard clearing, so a guard stranded by an error can't hold
		-- this thread spinning past the session it belongs to.
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

	-- Reachability is re-checked rather than trusted: the sign is the only way to raise this, but the
	-- remote takes an id, so nothing stops a crafted call naming a far corner at the opening price.
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

	-- Counted off the read above plus this one rather than re-counted, so it says how many they own
	-- now without depending on when the write lands in the replica table.
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

-- Raises the Robux prompt for one of the player's reachable plots. Which plot it was is remembered
-- here rather than carried on the product, since a plot product is priced by how many they've bought
-- and its receipt arrives with nothing on it but the buyer.
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

-- Grants a plot once one of the plot products clears (fired by ShopManager from the product's
-- callback). It goes to the plot the prompt was raised from.
--
-- A receipt Roblox never got an answer for is re-processed on a later join, where nothing raised a
-- prompt and there's no pending plot to read -- and a plot that was reachable when the prompt went up
-- can have been bought by the time it's answered. Either way it falls back to whatever is reachable
-- now rather than dropping a purchase the player has already been charged for.
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

-- Re-renders the build on the base the player owns from their current structures. Like the unlocks
-- above this only runs off an actual change, so the render animates -- a structure placed here rises
-- into its spot rather than popping in, while the render a base does on assignment stays instant.
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

-- Puts one of the structures the player owns down on the given cell of the given plot. Nothing here
-- touches the world: the data write renders it through the listener AssignBaseToPlayer set up.
--
-- Spends from their inventory rather than their balance -- a structure is paid for once, when it's
-- bought, and moves between the backpack and the base freely after that (see BuildManager).
--
-- Every argument comes off a remote, so none of it is trusted: the type has to name a structure they
-- actually own, the plot has to be ground they own, and the cells have to be free and on the floor.
-- Only the cells are stored, which is exactly what was checked -- so a build can never come back on a
-- rejoin somewhere it wouldn't have been allowed to go.
function BaseManager:PlaceStructureOnBase(
	player: Player,
	structureType: string,
	plotId: string,
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

	-- Shared with the plot and unlock purchases rather than a guard of its own: all of them read the
	-- player's data and then spend against it, so letting them interleave across their yields could
	-- spend the same thing twice. A placement that loses the race simply isn't made -- unlike a Robux
	-- purchase there's nothing already paid for to wait its turn.
	if self._purchasing[player] then
		return false
	end
	self._purchasing[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._purchasing[player] = nil
		return false
	end

	-- Owning one is what makes this a placement rather than a way to conjure structures: the tool only
	-- exists while the count is above zero, so a client sending this without one is a forged request.
	if (data.OwnedStructures[structureType] or 0) <= 0 then
		self._purchasing[player] = nil
		return false
	end

	rotation = math.floor(rotation) % 4
	local footprintX, footprintZ = Structures.GetFootprint(structure, rotation)

	if not base:IsBlockFree(plotId, cellX, cellZ, footprintX, footprintZ, data.Structures, data.Plots) then
		self._purchasing[player] = nil
		return false
	end

	BuildManager:ConsumeStructure(player, structureType)

	-- Minted here and never again: it's what the structure and everything sitting on it are keyed by,
	-- so it has to outlive the model being rebuilt on a rejoin.
	local uid = HttpService:GenerateGUID(false)

	PlayerDataManager:SetPlayerDataKey(player, { "Structures", uid }, {
		Type = structureType,
		PlotId = plotId,
		CellX = cellX,
		CellZ = cellZ,
		Rotation = rotation,
	})

	self._purchasing[player] = nil

	self.OnStructurePlaced:Fire(player, structureType)

	return true
end

-- Takes one of the player's structures back off their base, along with whatever was sitting on it,
-- and returns the structure itself to their inventory. Clearing that second record is the point: a
-- griller removed with a BBQ on it would otherwise leave the record behind forever, keyed by a uid
-- nothing can reach any more.
--
-- The structure comes back but its contents don't, so demolishing is how a base gets rearranged
-- rather than a way to lose what you paid for -- while a griller mid-cook still costs you the skewer.
function BaseManager:RemoveStructureFromBase(player: Player, uid: string): boolean
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return false
	end

	-- The uid comes off a remote, so it can be anything. Reading it off their build rather than the
	-- world proves the structure exists and is theirs in one.
	local structure = data.Structures[uid]
	if not structure then
		return false
	end

	PlayerDataManager:SetPlayerDataKey(player, { "Structures", uid }, nil)

	local config = Structures.GetStructureFromId(structure.Type)
	local contentsKey = config and STRUCTURE_CONTENTS[config.Category]
	if contentsKey then
		PlayerDataManager:SetPlayerDataKey(player, { contentsKey, uid }, nil)
	end

	-- Back into the backpack for them to put down somewhere else. Only for a structure the config still
	-- has: one whose model went missing can't be re-placed, so handing it back would be an item that
	-- does nothing.
	if config then
		BuildManager:GrantStructure(player, structure.Type)
	end

	self.OnStructureRemoved:Fire(player, structure.Type)

	return true
end

-- Buys the next slot of one unlock group for the player. Nothing here touches the world: the data
-- write re-renders the base through the listener AssignBaseToPlayer set up.
-- @param skipCurrencyCost Grant the level without charging for it, for a slot already paid for in
-- Robux (see the base-unlock products in Config/Products). Everything else -- the limit check, the
-- data write, the signal and the notification -- is wanted on both paths, so only the charge differs.
function BaseManager:PurchaseUnlockUpgrade(player: Player, unlockId: string, skipCurrencyCost: boolean?): boolean
	-- The id comes off a remote, so it can be anything.
	local unlock = BaseUnlocks.GetUnlockFromId(unlockId)
	if not unlock then
		return false
	end

	-- The reads below yield, so without this guard two purchases landing together could both read the
	-- same level and write the same next one. A currency buy that loses the race simply isn't made; a
	-- Robux one has already been charged, so it waits its turn rather than being dropped on the floor.
	if self._purchasing[player] then
		if not skipCurrencyCost then
			return false
		end

		-- Leaving is checked as well as the guard clearing, so a guard stranded by an error can't hold
		-- this thread spinning past the session it belongs to.
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

	-- Only the Sauce Dispenser starts at level 0, so a first purchase is a genuine unlock rather than
	-- an upgrade of something the player already owned.
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
