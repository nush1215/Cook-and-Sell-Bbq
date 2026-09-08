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

-- Stride between window seeds, leaving a gap for bought restocks so a forced roll can't land on the next natural one. 999 per window of headroom
local RESTOCK_SEED_STRIDE = 1_000

--
local StickShopToken = Replica.Token("StickShop")

-- Stock is deterministic per window so every server agrees; the Restock product is the one thing that steps this server off it, which is why _stockSeed is tracked here.
local StickShopManager = {
	PurchaseStickEvent = Network.Event("PurchaseStick"), -- client -> server (stickId)
	StickPurchaseResultEvent = Network.Event("StickPurchaseResult"), -- server -> client (success, stickId)

	-- (player, stickId, price, method) on a grant; price is 0 on a Robux buy
	OnStickPurchased = Signal.new(),

	_purchasing = {}, -- [player] = true, held across the CanAfford -> DeductCurrency yield window
	_stockSeed = 0, -- the seed the stock on the replica was rolled from: the clock's window seed strided
	-- out on a natural rollover, a step above it after a bought restock
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Rolls a window's stock from its seed. One shared Random across sticks in fixed tier order, so every server draws the same sequence.
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

-- Rolls a fresh stock onto the replica. Writing the seed alongside is what resets the per-player Bought counts.
function StickShopManager:_applyStock(seed: number)
	self._stockSeed = seed
	self._replica:Set({ "Seed" }, seed)
	self._replica:Set({ "Stock" }, self:_rollStock(seed))
end

-- Re-rolls this server's stock now, off the Restock product, leaving the window's countdown alone. The one thing that makes a server diverge until the next rollover.
function StickShopManager:RestockShop(player: Player)
	-- A step into the window's own gap, since anything off the clock would roll the same stock again
	self:_applyStock(self._stockSeed + 1)

	NotificationManager:NotifyNormalAll({
		Text = `<font color="#ffd400">{player.Name}</font> restocked the Stick Shop!`,
		Duration = 5,
		Sound = "Restocked",
		Effect = "Success",
	})
end

-- Buys one stick, authoritative on stock, currency and the grant. Bought is per-player, so one buyer never lowers what another sees.
function StickShopManager:PurchaseStick(player: Player, stickId: string): boolean
	if not validatePlayer(player) then
		return false
	end

	-- CanAfford yields, so without this guard two rapid buys could both pass before either deducts
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

	-- Reset per-player counts on a rollover, so a stale Bought can't eat into this window's stock
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

-- Grants a stick once its Robux product clears. Restockable isn't checked -- the diamond's product is the only way to get one.
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

	-- One global replica of the window's seed and stock, subscribed to every present and future player
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
