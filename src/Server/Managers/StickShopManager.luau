-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Replica = require(Packages.Replica)
local Signal = require(Packages.Signal)

-- Server
local Server = script.Parent.Parent
local Clock = require(Server.Modules.Clock)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local RandomUtil = require(Shared.RandomUtil)
local Sticks = require(Shared.Config.Sticks)

-- Managers
local PlayerDataManager
local CurrencyManager
local StickManager
local NotificationManager
local ShopManager
local StatsManager

--
local RESTOCK_INTERVAL = 5 * 60 -- seconds per restock window; the seed (and so the stock) is shared across servers
local TIME_LEFT_ATTRIBUTE = "StickShopTimeLeft" -- ReplicatedStorage attribute the client reads for the countdown

-- What the clock's window seed is multiplied by before the stock is rolled from it. The gap that opens
-- up underneath each window's seed is where bought restocks count, so a forced roll can never land on
-- the seed the next natural rollover is going to use -- which would leave that rollover re-rolling the
-- identical stock and skipping everyone's Bought reset. 999 forced restocks per window of headroom.
local RESTOCK_SEED_STRIDE = 1_000

--
local StickShopToken = Replica.Token("StickShop")

-- The stock table is deterministic per window: every server rolls the same seed, so all show the same
-- stock. Buying is decremented per-player (in player data), never off this shared stock.
-- The one thing that breaks that agreement is the Restock dev product, which re-rolls this server's
-- stock early -- so the seed the stock was rolled from is tracked here (_stockSeed) rather than read
-- back off the clock, and everything that gates on "which window is this" reads that one field.
local StickShopManager = {
	PurchaseStickEvent = Network.Event("PurchaseStick"), -- client -> server (stickId)
	StickPurchaseResultEvent = Network.Event("StickPurchaseResult"), -- server -> client (success, stickId)

	-- (player, stickId, price, method) once a stick is granted. method is "Currency" or "Robux"; price is
	-- the currency paid, 0 on a Robux buy.
	OnStickPurchased = Signal.new(),

	_purchasing = {}, -- [player] = true, held across the CanAfford -> DeductCurrency yield window
	_stockSeed = 0, -- the seed the stock on the replica was rolled from: the clock's window seed strided
	-- out on a natural rollover, a step above it after a bought restock
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Rolls the shop's stock for a restock window from its seed. Because a window's seed is a pure function
-- of wall-clock time, every server arrives at the same stock without any cross-server messaging (a
-- bought restock is the one thing that steps a single server off it, see RestockShop). One
-- shared Random is drawn through every stick (never the raw seed per call, which would re-seed and make
-- every stick roll identically), and sticks are iterated in fixed tier order so the draw sequence
-- matches across servers.
function StickShopManager:_rollStock(seed: number): { [string]: number }
	local rng = Random.new(seed)
	local stock = {}

	for _, stick in Sticks.GetRestockableSticks() do
		if RandomUtil.RollChance(stick.RestockChance, rng) then
			stock[stick.Id] = RandomUtil.GetRandomIntFromMinMax(stick.RestockAmount.Min, stick.RestockAmount.Max, rng)
		else
			stock[stick.Id] = 0
		end
	end

	return stock
end

-- Rolls a fresh stock from the given seed and puts it on the replica, which is what every client draws
-- the shop from. Writing the seed alongside it is what resets the per-player Bought counts: both this
-- manager and the client compare their stored seed against it, and a mismatch reads as zero bought.
function StickShopManager:_applyStock(seed: number)
	self._stockSeed = seed
	self._replica:Set({ "Seed" }, seed)
	self._replica:Set({ "Stock" }, self:_rollStock(seed))
end

-- Re-rolls the shop's stock for everyone in this server right now, off the Restock dev product. The
-- restock window itself is left alone -- the countdown keeps running to the end of the window it was
-- already on -- so this is an extra roll rather than a reset of the schedule.
-- Note that the shared seed is what normally keeps every server showing identical stock; this is the
-- one thing that makes a server diverge from the others until the next natural rollover.
-- @param player The player whose purchase paid for it, named in the announcement
function StickShopManager:RestockShop(player: Player)
	-- A step into the window's own gap (see RESTOCK_SEED_STRIDE) rather than anything off the clock,
	-- which would roll the exact same stock the shop is already showing.
	self:_applyStock(self._stockSeed + 1)

	NotificationManager:NotifyNormalAll({
		Text = `<font color="#ffd400">{player.Name}</font> restocked the Stick Shop!`,
		Duration = 5,
		Sound = "Restocked",
		Effect = "Success",
	})
end

-- Buys one of a stick from the shop: server-authoritative on stock, currency and the grant. The stock
-- is shared, but each player has their own per-window Bought count, so one player buying never lowers
-- what another sees. GrantStick's reconcile turns the owned count into an equipped backpack tool.
function StickShopManager:PurchaseStick(player: Player, stickId: string): boolean
	if not validatePlayer(player) then
		return false
	end

	-- CanAfford yields, so without this guard two rapid buys could both pass before either deducts.
	if self._purchasing[player] then
		return false
	end
	self._purchasing[player] = true

	local stick = Sticks.GetStickFromId(stickId)
	if not stick or not stick.Restockable then
		self._purchasing[player] = nil
		return false
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._purchasing[player] = nil
		return false
	end

	-- Reset the per-player counts when the stock has rolled over, so a stale Bought from a previous
	-- window doesn't eat into this window's stock.
	local currentSeed = self._stockSeed
	if data.StickShop.Seed ~= currentSeed then
		PlayerDataManager:SetPlayerDataKey(player, "StickShop", { Seed = currentSeed, Bought = {} })
	end

	local bought = data.StickShop.Bought[stickId] or 0
	local remaining = (self._replica.Data.Stock[stickId] or 0) - bought
	if remaining <= 0 then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = `{stick.Name} Sticks are out of stock`,
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	local canAfford = CurrencyManager:CanAfford(player, stick.Price)
	if not canAfford then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = `You can't afford a {stick.Name} Stick`,
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	CurrencyManager:DeductCurrency(player, stick.Price, "StickPurchase")
	StickManager:GrantStick(player, stickId)
	PlayerDataManager:SetPlayerDataKey(player, { "StickShop", "Bought", stickId }, bought + 1)
	StatsManager:RecordSticksBought(player)
	self.OnStickPurchased:Fire(player, stickId, stick.Price, "Currency")

	self._purchasing[player] = nil

	NotificationManager:NotifyNormal(player, {
		Text = `Bought a {stick.Name} Stick`,
		Duration = 3,
		Sound = "Purchase",
		Effect = "Success",
	})

	return true
end

-- Grants a stick when its Robux dev product is purchased (fired by ShopManager once the receipt clears).
-- Robux buys bypass the window stock and the per-player Bought count -- it's a premium instant-grant.
-- Gamepass and other product ids simply don't resolve to a stick, so they're ignored.
-- Restockable isn't checked here the way the currency path checks it: the diamond has no shop row and
-- no currency price precisely because its dev product is the only way to get one.
function StickShopManager:GrantStickFromProduct(player: Player, productId: string)
	local stick = Sticks.GetStickFromId(productId)
	if not stick then
		return
	end

	StickManager:GrantStick(player, productId)
	StatsManager:RecordSticksBought(player)
	self.OnStickPurchased:Fire(player, productId, 0, "Robux")
end

function StickShopManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	StickManager = require(script.Parent.StickManager)
	NotificationManager = require(script.Parent.NotificationManager)
	ShopManager = require(script.Parent.ShopManager)
	StatsManager = require(script.Parent.StatsManager)
end

function StickShopManager:OnStart()
	self._clock = Clock.new(RESTOCK_INTERVAL)

	-- One global replica holding the current window's seed and rolled stock, subscribed to every
	-- present and future player.
	self._stockSeed = self._clock.CurrentSeed * RESTOCK_SEED_STRIDE
	self._replica = Replica.New({
		Token = StickShopToken,
		Data = {
			Seed = self._stockSeed,
			Stock = self:_rollStock(self._stockSeed),
		},
	})
	self._replica:Replicate()

	-- Countdown for the client UI: mirror the time left onto a ReplicatedStorage attribute each second.
	ReplicatedStorage:SetAttribute(TIME_LEFT_ATTRIBUTE, self._clock.CurrentTime)
	self._clock.OnTimeChanged:Connect(function(timeLeft: number)
		ReplicatedStorage:SetAttribute(TIME_LEFT_ATTRIBUTE, timeLeft)
	end)

	-- Re-roll the stock when the window rolls over.
	self._clock.Reached:Connect(function(seed: number)
		self:_applyStock(seed * RESTOCK_SEED_STRIDE)

		NotificationManager:NotifyNormalAll({
			Text = "The Stick Shop has restocked",
			Duration = 5,
			Sound = "Restocked",
			Effect = "Success",
		})
	end)

	self.PurchaseStickEvent:OnServerEvent(function(player: Player, stickId: string)
		local success = self:PurchaseStick(player, stickId)
		self.StickPurchaseResultEvent:FireClient(player, success, stickId)
	end)

	ShopManager.PlayerPurchased:Connect(function(player: Player, productId: string)
		self:GrantStickFromProduct(player, productId)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._purchasing[player] = nil
	end)
end

return StickShopManager
