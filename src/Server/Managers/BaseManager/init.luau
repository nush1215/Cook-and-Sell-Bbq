-- Services
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local BaseUnlocks = require(Shared.Config.BaseUnlocks)

-- Modules
local Base = require(script.Base)

--
local PlayerDataManager
local CurrencyManager
local NotificationManager

--
local BaseManager = {
	PurchaseUnlockUpgradeEvent = Network.Event("PurchaseUnlockUpgrade"),

	--
	OnBaseAssigned = Signal.new(),
	-- (player, unlockId, newLevel, cost, method) when a slot of an unlock group is bought. newLevel 1 is
	-- a first unlock, anything higher an upgrade. method is "Currency" or "Robux"; cost is the currency
	-- paid, 0 on a Robux buy.
	OnUnlockPurchased = Signal.new(),

	--
	_bases = {},
	_listeners = {}, -- [player] = the Unlocks data listener
	_purchasing = {}, -- [player] = true, held across the data read -> DeductCurrency window
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

		-- Listen before assigning: AssignOwner yields on LoadCharacterAsync. An upgrade landing in
		-- that window still lands, since data is the live replica table AssignOwner reads below.
		self._listeners[player] = PlayerDataManager:ListenForChanges(player, "Unlocks", function()
			self:RefreshBaseUnlocksForPlayer(player)
		end)

		base:AssignOwner(player, data.Unlocks)
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

-- Watches the passes that own a gamepass slot, so a base re-renders when its owner turns out to hold
-- one. This is a tag rather than a data key, and ShopManager adds it on both paths -- the purchase, and
-- the ownership sweep on join, which can easily land after the base has already gone up -- so following
-- the tag covers a mid-session buy and a rejoin with one connection either way.
function BaseManager:_watchGamepassSlots()
	local watched = {}

	for _, unlock in BaseUnlocks.Data do
		if not unlock.GamepassSlots then
			continue
		end

		for _, gamepassSlot in unlock.GamepassSlots do
			if watched[gamepassSlot.Gamepass] then
				continue
			end
			watched[gamepassSlot.Gamepass] = true

			-- Nothing but a Player is meant to wear a gamepass id, but a tag is a global namespace and
			-- this signal reports whatever picks one up, so it's checked rather than assumed.
			CollectionService:GetInstanceAddedSignal(gamepassSlot.Gamepass):Connect(function(instance)
				if instance:IsA("Player") then
					self:RefreshBaseUnlocksForPlayer(instance)
				end
			end)
		end
	end
end

-- Releases the player's base back into the free pool.
function BaseManager:UnassignBaseFromPlayer(player: Player)
	local base = self:GetBaseFromPlayer(player)
	if not base then
		return
	end

	-- Owning a base is what registers the listener, so there's always one to drop here.
	self._listeners[player]:Disconnect()
	self._listeners[player] = nil

	base:ClearOwner()
end

function BaseManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	NotificationManager = require(script.Parent.NotificationManager)

	for _, model in workspace.Base:GetChildren() do
		table.insert(self._bases, Base.new(model))
	end

	self:_watchGamepassSlots()

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
	end)
end

function BaseManager:OnStart()
	self.PurchaseUnlockUpgradeEvent:OnServerEvent(function(player: Player, unlockId: string)
		self:PurchaseUnlockUpgrade(player, unlockId)
	end)
end

return BaseManager
