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
local Structures = require(Shared.Config.Structures)

-- Managers
local PlayerDataManager
local CurrencyManager
local BuildManager
local NotificationManager
local ShopManager

--
local RESTOCK_INTERVAL = 5 * 60 -- seconds per restock window; the seed (and so the stock) is shared across servers
local TIME_LEFT_ATTRIBUTE = "GrillStandShopTimeLeft" -- ReplicatedStorage attribute the client reads for the countdown

-- Stride between window seeds, leaving a gap for bought restocks so a forced roll can't land on the next natural one. 999 per window of headroom
local RESTOCK_SEED_STRIDE = 1_000

--
local GrillStandShopToken = Replica.Token("GrillStandShop")

-- Sells Restockable structures on a timed restock. Stock is deterministic per window so every server agrees; the Restock product is the one thing that steps this server off it, which is why _stockSeed is tracked here.
local GrillStandShopManager = {
	PurchaseStructureEvent = Network.Event("PurchaseStructure"), -- client -> server (structureId)
	StructurePurchaseResultEvent = Network.Event("StructurePurchaseResult"), -- server -> client (success, structureId)

	-- (player, structureId, price, method) on a grant; price is 0 on a Robux buy
	OnStructurePurchased = Signal.new(),

	_purchasing = {}, -- [player] = true, held across the CanAfford -> DeductCurrency yield window
	_stockSeed = 0, -- the seed the stock on the replica was rolled from: the clock's window seed strided
	-- out on a natural rollover, a step above it after a bought restock
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Rolls a window's stock from its seed. One shared Random across structures in fixed config order, so every server draws the same sequence.
function GrillStandShopManager:_rollStock(seed: number): { [string]: number }
	local rng = Random.new(seed)
	local stock = {}

	for _, structure in Structures.GetRestockableStructures() do
		if RandomUtil.RollChance(structure.RestockChance, rng) then
			stock[structure.Id] =
				RandomUtil.GetRandomIntFromMinMax(structure.RestockAmount.Min, structure.RestockAmount.Max, rng)
		else
			stock[structure.Id] = 0
		end
	end

	return stock
end

-- Rolls a fresh stock onto the replica. Writing the seed alongside is what resets the per-player Bought counts.
function GrillStandShopManager:_applyStock(seed: number)
	self._stockSeed = seed
	self._replica:Set({ "Seed" }, seed)
	self._replica:Set({ "Stock" }, self:_rollStock(seed))
end

-- Re-rolls this server's stock now, off the Restock product, leaving the window's countdown alone. The one thing that makes a server diverge until the next rollover.
function GrillStandShopManager:RestockShop(player: Player)
	-- A step into the window's own gap, since anything off the clock would roll the same stock again
	self:_applyStock(self._stockSeed + 1)

	NotificationManager:NotifyNormalAll({
		Text = `<font color="#ffd400">{player.Name}</font> restocked the Grill & Stand Shop!`,
		Duration = 5,
		Sound = "Restocked",
		Effect = "Success",
	})
end

-- Buys one structure, authoritative on stock, currency and the grant. Bought is per-player, so one buyer never lowers what another sees.
function GrillStandShopManager:PurchaseStructure(player: Player, structureId: string): boolean
	if not validatePlayer(player) then
		return false
	end

	-- CanAfford yields, so without this guard two rapid buys could both pass before either deducts
	if self._purchasing[player] then
		return false
	end
	self._purchasing[player] = true

	local structure = Structures.GetStructureFromId(structureId)
	if not structure or not structure.Restockable then
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
	if data.GrillStandShop.Seed ~= currentSeed then
		PlayerDataManager:SetPlayerDataKey(player, "GrillStandShop", { Seed = currentSeed, Bought = {} })
	end

	local bought = data.GrillStandShop.Bought[structureId] or 0
	local remaining = (self._replica.Data.Stock[structureId] or 0) - bought
	if remaining <= 0 then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = `{structure.Name}s are out of stock`,
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	local canAfford = CurrencyManager:CanAfford(player, structure.Cost)
	if not canAfford then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = `You can't afford a {structure.Name}`,
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	CurrencyManager:DeductCurrency(player, structure.Cost, "StructurePurchase")
	BuildManager:GrantStructure(player, structureId)
	PlayerDataManager:SetPlayerDataKey(player, { "GrillStandShop", "Bought", structureId }, bought + 1)
	self.OnStructurePurchased:Fire(player, structureId, structure.Cost, "Currency")

	self._purchasing[player] = nil

	NotificationManager:NotifyNormal(player, {
		Text = `Bought a {structure.Name}`,
		Duration = 3,
		Sound = "Purchase",
		Effect = "Success",
	})

	return true
end

-- Grants a structure once its Robux product clears. Robux bypasses the window stock and Bought count.
function GrillStandShopManager:GrantStructureFromProduct(player: Player, productId: string)
	local structure = Structures.GetStructureFromId(productId)
	if not structure then
		return
	end

	BuildManager:GrantStructure(player, productId)
	self.OnStructurePurchased:Fire(player, productId, 0, "Robux")
end

function GrillStandShopManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	BuildManager = require(script.Parent.BuildManager)
	NotificationManager = require(script.Parent.NotificationManager)
	ShopManager = require(script.Parent.ShopManager)
end

function GrillStandShopManager:OnStart()
	self._clock = Clock.new(RESTOCK_INTERVAL)

	-- One global replica of the window's seed and stock, subscribed to every present and future player
	self._stockSeed = self._clock.CurrentSeed * RESTOCK_SEED_STRIDE
	self._replica = Replica.New({
		Token = GrillStandShopToken,
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

	-- Both shops run the same clock, so their announcements land together and the client collapses the duplicate chime
	self._clock.Reached:Connect(function(seed: number)
		self:_applyStock(seed * RESTOCK_SEED_STRIDE)

		NotificationManager:NotifyNormalAll({
			Text = "The Grill & Stand Shop has restocked",
			Duration = 5,
			Sound = "Restocked",
			Effect = "Success",
		})
	end)

	self.PurchaseStructureEvent:OnServerEvent(function(player: Player, structureId: string)
		local success = self:PurchaseStructure(player, structureId)
		self.StructurePurchaseResultEvent:FireClient(player, success, structureId)
	end)

	ShopManager.PlayerPurchased:Connect(function(player: Player, productId: string)
		self:GrantStructureFromProduct(player, productId)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._purchasing[player] = nil
	end)
end

return GrillStandShopManager
