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
local CosmeticShop = require(Shared.Config.CosmeticShop)
local EmployeeHut = require(Shared.Config.EmployeeHut)

-- Managers
local PlayerDataManager = require(script.Parent.PlayerDataManager)
local CurrencyManager = require(script.Parent.CurrencyManager)
local BuildManager = require(script.Parent.BuildManager)
local NotificationManager = require(script.Parent.NotificationManager)

--
local ROTATION_INTERVAL = 60 * 60 -- seconds per rotation; the seed (and so the offers) is shared across servers
local TIME_LEFT_ATTRIBUTE = "CosmeticShopTimeLeft" -- ReplicatedStorage attribute the client reads for the countdown

--
local CosmeticShopToken = Replica.Token("CosmeticShop")

-- Sells Config.CosmeticShop's offers for Gems, a few drawn from each tier every rotation. The draw is deterministic per window so every server agrees, and Bought is per-player, so one buyer never takes stock from another.
local CosmeticShopManager = {
	-- No result event back: the toast and the Bought write already tell the client everything it shows
	PurchaseCosmeticEvent = Network.Event("PurchaseCosmetic", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 4 },
	}), -- client -> server (structureId)

	-- (player, structureId, price, tierId) on a grant
	OnCosmeticPurchased = Signal.new(),

	_purchasing = {}, -- [player] = true, held across the CanAfford -> DeductGems yield window
}

-- Draws a rotation's offers from its seed, each tier's Slots without repeats. One shared Random across tiers in config order, so every server draws the same.
function CosmeticShopManager:_rollOffers(seed: number): { [string]: { string } }
	local rng = Random.new(seed)
	local offers = {}

	for _, tier in CosmeticShop.Tiers do
		local drawn = {}

		for _ = 1, tier.Slots do
			local weighted = {}
			for _, offer in tier.Offers do
				if not table.find(drawn, offer.Id) then
					table.insert(weighted, { offer, offer.Weight })
				end
			end

			-- Only nil once the tier has run out of offers, which the config warns about at load
			local offer = RandomUtil.GetResultFromWeight(weighted, rng)
			if not offer then
				break
			end

			table.insert(drawn, offer.Id)
		end

		offers[tier.Id] = drawn
	end

	return offers
end

-- Rolls a fresh rotation onto the replica. Writing the seed alongside is what resets the per-player Bought counts.
function CosmeticShopManager:_applyOffers(seed: number)
	self._replica:Set({ "Seed" }, seed)
	self._replica:Set({ "Offers" }, self:_rollOffers(seed))
end

-- Buys one offer from this rotation for Gems, authoritative on what's on sale, stock, the hut rules and the grant.
function CosmeticShopManager:PurchaseCosmetic(player: Player, structureId: string): boolean
	if not player:IsDescendantOf(Players) then
		return false
	end

	-- CanAfford yields, so without this guard two rapid buys could both pass before either deducts
	if self._purchasing[player] then
		return false
	end
	self._purchasing[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._purchasing[player] = nil
		return false
	end

	-- Refused without a toast: anything not on sale is stale or forged. Checked after the data read, so a rollover during it can't slip past
	local offer, tier = CosmeticShop.GetOffer(structureId)
	if not offer or not table.find(self._replica.Data.Offers[tier.Id], structureId) then
		self._purchasing[player] = nil
		return false
	end

	-- Reset per-player counts on a rollover, so a stale Bought can't eat into this rotation's stock
	local currentSeed = self._replica.Data.Seed
	if data.CosmeticShop.Seed ~= currentSeed then
		PlayerDataManager:SetPlayerDataKey(player, "CosmeticShop", { Seed = currentSeed, Bought = {} })
	end

	-- "x3 Medium Dirt Path" reads fine bare, a single one needs its article
	local offerName = CosmeticShop.GetOfferName(offer)
	local shownName = if (offer.Amount or 1) > 1 then offerName else `a {offerName}`

	local bought = data.CosmeticShop.Bought[structureId] or 0
	if bought >= CosmeticShop.STOCK then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = `{offerName} is out of stock`,
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	-- The repaired hut is always one of the MAX_HUTS, so the shop only ever sells the ones after it
	if structureId == EmployeeHut.STRUCTURE_ID then
		local refusal = if not data.HutRepaired
			then "Repair your Worker Hut first"
			elseif EmployeeHut.CountOwnedHuts(data) >= EmployeeHut.MAX_HUTS
				then `You already have {EmployeeHut.MAX_HUTS} Worker Huts`
			else nil

		if refusal then
			self._purchasing[player] = nil
			NotificationManager:NotifyNormal(player, {
				Text = refusal,
				Duration = 3,
				Sound = "Reject",
				Effect = "Error",
			})
			return false
		end
	end

	local canAfford = CurrencyManager:CanAfford(player, offer.Price, "Gems")
	if not canAfford then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = `You can't afford {shownName}`,
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	CurrencyManager:DeductGems(player, offer.Price, "CosmeticPurchase")
	BuildManager:GrantStructure(player, structureId, offer.Amount)
	PlayerDataManager:SetPlayerDataKey(player, { "CosmeticShop", "Bought", structureId }, bought + 1)
	self.OnCosmeticPurchased:Fire(player, structureId, offer.Price, tier.Id)

	self._purchasing[player] = nil

	NotificationManager:NotifyNormal(player, {
		Text = `Bought {shownName}`,
		Duration = 3,
		Sound = "Purchase",
		Effect = "Success",
	})

	return true
end

function CosmeticShopManager:OnStart()
	local clock = Clock.new(ROTATION_INTERVAL)

	-- One global replica of the rotation, subscribed to every present and future player
	self._replica = Replica.New({
		Token = CosmeticShopToken,
		Data = {
			Seed = clock.CurrentSeed,
			Offers = self:_rollOffers(clock.CurrentSeed),
		},
	})
	self._replica:Replicate()

	-- Countdown for the client UI: mirror the time left onto a ReplicatedStorage attribute each second.
	ReplicatedStorage:SetAttribute(TIME_LEFT_ATTRIBUTE, clock.CurrentTime)
	clock.OnTimeChanged:Connect(function(timeLeft: number)
		ReplicatedStorage:SetAttribute(TIME_LEFT_ATTRIBUTE, timeLeft)
	end)

	-- Lands on the hour with the other shops' five-minute clocks, and the client collapses the duplicate chime
	clock.Reached:Connect(function(seed: number)
		self:_applyOffers(seed)

		NotificationManager:NotifyNormalAll({
			Text = "The Cosmetic Shop has restocked",
			Duration = 5,
			Sound = "Restocked",
			Effect = "Success",
		})
	end)

	self.PurchaseCosmeticEvent:OnServerEvent(function(player: Player, structureId: string)
		self:PurchaseCosmetic(player, structureId)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._purchasing[player] = nil
	end)
end

return CosmeticShopManager
