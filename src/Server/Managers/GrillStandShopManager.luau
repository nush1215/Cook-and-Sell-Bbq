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

-- What the clock's window seed is multiplied by before the stock is rolled from it. The gap that opens
-- up underneath each window's seed is where bought restocks count, so a forced roll can never land on
-- the seed the next natural rollover is going to use -- which would leave that rollover re-rolling the
-- identical stock and skipping everyone's Bought reset. 999 forced restocks per window of headroom.
local RESTOCK_SEED_STRIDE = 1_000

--
local GrillStandShopToken = Replica.Token("GrillStandShop")

-- The shop that sells structures -- grillers and stick stands -- on the same timed-restock model as the
-- Stick Shop, split into category tabs on the client. What it sells is Config.Structures, filtered to
-- the Restockable ones, and a purchase lands in OwnedStructures via BuildManager:GrantStructure, whose
-- reconcile turns the owned count into a stacking build tool.
--
-- The stock table is deterministic per window: every server rolls the same seed, so all show the same
-- stock. Buying is decremented per-player (in player data), never off this shared stock.
-- The one thing that breaks that agreement is the Restock dev product, which re-rolls this server's
-- stock early -- so the seed the stock was rolled from is tracked here (_stockSeed) rather than read
-- back off the clock, and everything that gates on "which window is this" reads that one field.
local GrillStandShopManager = {
	PurchaseStructureEvent = Network.Event("PurchaseStructure"), -- client -> server (structureId)
	StructurePurchaseResultEvent = Network.Event("StructurePurchaseResult"), -- server -> client (success, structureId)

	-- (player, structureId, price, method) once a structure is granted. method is "Currency" or "Robux";
	-- price is the currency paid, 0 on a Robux buy.
	OnStructurePurchased = Signal.new(),

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
-- shared Random is drawn through every structure (never the raw seed per call, which would re-seed and
-- make every structure roll identically), and structures are iterated in fixed config order so the draw
-- sequence matches across servers.
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

-- Rolls a fresh stock from the given seed and puts it on the replica, which is what every client draws
-- the shop from. Writing the seed alongside it is what resets the per-player Bought counts: both this
-- manager and the client compare their stored seed against it, and a mismatch reads as zero bought.
function GrillStandShopManager:_applyStock(seed: number)
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
function GrillStandShopManager:RestockShop(player: Player)
	-- A step into the window's own gap (see RESTOCK_SEED_STRIDE) rather than anything off the clock,
	-- which would roll the exact same stock the shop is already showing.
	self:_applyStock(self._stockSeed + 1)

	NotificationManager:NotifyNormalAll({
		Text = `<font color="#ffd400">{player.Name}</font> restocked the Grill & Stand Shop!`,
		Duration = 5,
		Sound = "Restocked",
		Effect = "Success",
	})
end

-- Buys one of a structure from the shop: server-authoritative on stock, currency and the grant. The
-- stock is shared, but each player has their own per-window Bought count, so one player buying never
-- lowers what another sees. GrantStructure's reconcile turns the owned count into a backpack build tool.
function GrillStandShopManager:PurchaseStructure(player: Player, structureId: string): boolean
	if not validatePlayer(player) then
		return false
	end

	-- CanAfford yields, so without this guard two rapid buys could both pass before either deducts.
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

	-- Reset the per-player counts when the stock has rolled over, so a stale Bought from a previous
	-- window doesn't eat into this window's stock.
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

-- Grants a structure when its Robux dev product is purchased (fired by ShopManager once the receipt
-- clears). Robux buys bypass the window stock and the per-player Bought count -- it's a premium
-- instant-grant. Gamepass and other product ids simply don't resolve to a structure, so they're ignored.
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

	-- One global replica holding the current window's seed and rolled stock, subscribed to every
	-- present and future player.
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

	-- Re-roll the stock when the window rolls over. This shop runs the same interval as the Stick Shop
	-- off the same wall clock, so the two announcements land on the same second -- the client collapses
	-- the duplicate sound (see NotificationController), leaving both toasts and one chime.
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
