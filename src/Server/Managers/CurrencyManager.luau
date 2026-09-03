-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local EarlyBoost = require(Shared.Config.EarlyBoost)

--
local PlayerDataManager

--
local CurrencyManager = {
	-- (player, amount, source, isGain) after every currency change. `source` is the caller's label for
	-- what earned or spent it (e.g. "SkewerSale", "StickPurchase"); nil for admin grants that shouldn't
	-- count as part of the economy. `amount` is what actually landed, boosts included.
	OnCurrencyChanged = Signal.new(),

	_earlyBoostDisabled = {}, -- [player] = true while an admin has their early boost switched off
}

-- The lifetime earnings the early boost should be figured against, for every dial that runs off it --
-- the payout bonus here, and SellNpc's spawn delay and walk-off chance.
--
-- THRESHOLD stands for "no head start", since every EarlyBoost getter reads neutral at and past it. That
-- covers both cases where there's none to give: a profile that hasn't loaded yet, where assuming zero
-- earned would hand the full boost to whoever it is -- established player or not -- and one an admin has
-- switched off. Doesn't yield, for the reason on GetPlayerBoostFraction below.
function CurrencyManager:GetEarlyBoostEarnings(player: Player): number
	if self._earlyBoostDisabled[player] then
		return EarlyBoost.THRESHOLD
	end

	local playerData = PlayerDataManager:GetLoadedPlayerData(player)
	return if playerData then playerData.TotalEarned else EarlyBoost.THRESHOLD
end

-- Switches a player's early boost off or back on for the rest of their session, for testing the game at
-- an established player's pacing. Not saved, so a rejoin brings it back.
function CurrencyManager:SetPlayerEarlyBoostEnabled(player: Player, enabled: boolean)
	-- Only the exceptions are held, so an untouched player is a plain nil lookup.
	self._earlyBoostDisabled[player] = if enabled then nil else true
	self:RefreshPlayerBoostFraction(player)
end

-- The share of a base amount the player's boosts add on top of it: the gamepasses they hold, how many
-- friends are in the server with them, and the head start a new player's income gets. Every one is
-- figured on the base amount rather than stacking on each other, so a brand-new player holding x2Bux
-- gets 1 + 1 + 0.5 rather than 2 x 1.5.
--
-- A fraction rather than a finished amount because two surfaces need it without an amount in hand: the
-- payout below, and the estimate on a held skewer, which every client prices off the mirrored attribute
-- (see RefreshPlayerBoostFraction).
--
-- Doesn't yield, and mustn't start: this runs on every sale and on every reward grant, and a yield would
-- change the contract of every caller.
function CurrencyManager:GetPlayerBoostFraction(player: Player): number
	-- These tags are gamepass ids -- ShopManager tags an owner with the Id of every pass they hold -- so
	-- the strings have to match Config.Gamepasses exactly.
	local fraction = 0
	if player:HasTag("x2Bux") then
		fraction += 1
	end

	if player:HasTag("VIP") then
		fraction += 0.25
	end

	-- Friends pay out on the base amount rather than on the gamepass subtotal, so the boost still
	-- lands for players who own neither pass -- which is what the HUD's "+N0%" label promises.
	local friendsAmount = player:GetAttribute("FriendsAmount") or 0
	fraction += friendsAmount / 10

	-- The head start a new player's income gets, on the base amount like the two above it.
	fraction += EarlyBoost.GetBonus(self:GetEarlyBoostEarnings(player))

	return fraction
end

-- What `amount` becomes once the player's boosts are folded in.
--
-- Split out of IncrementCurrency rather than left inline because the sell stand has to show this number
-- before it pays it: an offer that quotes the plain figure and then banks a bigger one is the display
-- disagreeing with the payout in front of the player. Both go through here, so the number shown is the
-- number banked by construction rather than by two places agreeing to round the same way.
function CurrencyManager:GetBoostedAmount(player: Player, amount: number): number
	return amount + math.round(amount * self:GetPlayerBoostFraction(player))
end

-- Mirrors the fraction onto the player as an attribute, which replicates to every client for every
-- player. That's what lets a held skewer's billboard quote what the sale will actually bank -- the
-- estimate is drawn by whoever is looking at the holder, and TotalEarned only replicates to its owner,
-- so the fraction has to come across ready-made rather than be worked out client-side.
function CurrencyManager:RefreshPlayerBoostFraction(player: Player)
	player:SetAttribute("BoostFraction", self:GetPlayerBoostFraction(player))
end

-- Grants currency, folding in the player's boosts unless told not to. `source` names what paid it out
-- and rides on OnCurrencyChanged; leave it nil for grants that shouldn't count in the economy.
--
-- Takes the plain amount and boosts it here rather than being handed a boosted one -- a caller that
-- showed the player GetBoostedAmount and then passed that back in would boost the same sale twice.
function CurrencyManager:IncrementCurrency(player: Player, amount: number?, source: string?, ignoreBoosts: boolean?)
	amount = amount or 1

	if not ignoreBoosts then
		amount = self:GetBoostedAmount(player, amount)
	end

	-- TotalEarned tracks income rather than balance, so it's bumped by whatever actually lands -- boosts
	-- included -- and never comes back down the way Currency does when the player spends.
	PlayerDataManager:IncrementDataKey(player, "TotalEarned", amount)
	PlayerDataManager:IncrementDataKey(player, "Currency", amount)
	self.OnCurrencyChanged:Fire(player, amount, source, true)
end

-- Spends currency. `source` names what it was spent on and rides on OnCurrencyChanged.
function CurrencyManager:DeductCurrency(player: Player, amount: number?, source: string?)
	amount = amount or 1
	PlayerDataManager:DecrementDataKey(player, "Currency", amount)
	self.OnCurrencyChanged:Fire(player, amount, source, false)
end

function CurrencyManager:CanAfford(player: Player, amount: number): (boolean, number)
	local hasData, playerCurrency = PlayerDataManager:GetPlayerDataKey(player, "Currency"):await()
	if not hasData then
		return false
	end

	return playerCurrency >= amount, amount - playerCurrency
end

function CurrencyManager:OnInit()
	--
	PlayerDataManager = require(script.Parent.PlayerDataManager)
end

function CurrencyManager:OnStart()
	-- Every input to the fraction can move mid-session, and a stale mirror is a billboard quoting a
	-- number the sale won't pay -- so each one gets a listener rather than the attribute being written
	-- once on join.

	-- EarlyBoost decays as the player earns, so the fraction shifts on every sale. Hooked on the data
	-- rather than inside IncrementCurrency so anything else that moves TotalEarned is covered too.
	PlayerDataManager.OnDataChanged:Connect(function(player: Player, key: string)
		if key == "TotalEarned" then
			self:RefreshPlayerBoostFraction(player)
		end
	end)

	-- Gamepass tags land after ShopManager's ownership check comes back from the web, which can be well
	-- after the player joined.
	for _, tag in { "x2Bux", "VIP" } do
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance: Instance)
			if instance:IsA("Player") then
				self:RefreshPlayerBoostFraction(instance)
			end
		end)
	end

	local function watchPlayer(player: Player)
		player:GetAttributeChangedSignal("FriendsAmount"):Connect(function()
			self:RefreshPlayerBoostFraction(player)
		end)

		-- Seeded off the loaded profile, since EarlyBoost has nothing to read until then. Spawned so a
		-- slow load doesn't hold up startup, and the player may have left across that wait.
		task.spawn(function()
			local hasData = PlayerDataManager:GetPlayerData(player):await()
			if hasData and player:IsDescendantOf(Players) then
				self:RefreshPlayerBoostFraction(player)
			end
		end)
	end

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		self._earlyBoostDisabled[player] = nil
	end)
end

return CurrencyManager
