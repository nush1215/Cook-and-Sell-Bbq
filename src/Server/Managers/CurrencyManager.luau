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
	-- (player, amount, source, isGain) after every change; `source` is nil for grants outside the economy
	OnCurrencyChanged = Signal.new(),

	_earlyBoostDisabled = {}, -- [player] = true while an admin has their early boost switched off
}

-- Lifetime earnings for the early boost. THRESHOLD stands for "no head start", covering an unloaded profile and an admin switch-off. Doesn't yield.
function CurrencyManager:GetEarlyBoostEarnings(player: Player): number
	if self._earlyBoostDisabled[player] then
		return EarlyBoost.THRESHOLD
	end

	local playerData = PlayerDataManager:GetLoadedPlayerData(player)
	return if playerData then playerData.TotalEarned else EarlyBoost.THRESHOLD
end

-- Switches a player's early boost off or on for the session, for testing established pacing. Not saved.
function CurrencyManager:SetPlayerEarlyBoostEnabled(player: Player, enabled: boolean)
	-- Only the exceptions are held, so an untouched player is a plain nil lookup
	self._earlyBoostDisabled[player] = if enabled then nil else true
	self:RefreshPlayerBoostFraction(player)
end

-- The share the player's boosts add: gamepasses, friends in-server, and the early boost. All on the base amount, so they add rather than compound. Doesn't yield.
function CurrencyManager:GetPlayerBoostFraction(player: Player): number
	-- These tags are gamepass ids, so the strings have to match Config.Gamepasses exactly
	local fraction = 0
	if player:HasTag("x2Bux") then
		fraction += 1
	end

	if player:HasTag("VIP") then
		fraction += 0.25
	end

	-- On the base amount, so the boost still lands for players owning neither pass -- as the HUD promises
	local friendsAmount = player:GetAttribute("FriendsAmount") or 0
	fraction += friendsAmount / 10

	-- The head start a new player's income gets, on the base amount like the two above it
	fraction += EarlyBoost.GetBonus(self:GetEarlyBoostEarnings(player))

	return fraction
end

-- What `amount` becomes with the player's boosts folded in. Split out so the sell stand can quote the figure it will bank.
function CurrencyManager:GetBoostedAmount(player: Player, amount: number): number
	return amount + math.round(amount * self:GetPlayerBoostFraction(player))
end

-- Mirrors the fraction onto the player, so a held skewer's billboard can quote the boosted figure to whoever is looking.
function CurrencyManager:RefreshPlayerBoostFraction(player: Player)
	player:SetAttribute("BoostFraction", self:GetPlayerBoostFraction(player))
end

-- Grants currency, boosting it here. Takes the plain amount -- passing a boosted one back in would boost twice.
function CurrencyManager:IncrementCurrency(player: Player, amount: number?, source: string?, ignoreBoosts: boolean?)
	amount = amount or 1

	if not ignoreBoosts then
		amount = self:GetBoostedAmount(player, amount)
	end

	-- TotalEarned tracks income, not balance, so it takes what landed and never comes back down
	PlayerDataManager:IncrementDataKey(player, "TotalEarned", amount)
	PlayerDataManager:IncrementDataKey(player, "Currency", amount)
	self.OnCurrencyChanged:Fire(player, amount, source, true)
end

-- Spends currency. `source` names what it went on and rides on OnCurrencyChanged.
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
	PlayerDataManager = require(script.Parent.PlayerDataManager)
end

function CurrencyManager:OnStart()
	-- Every input can move mid-session, and a stale mirror quotes a number the sale won't pay

	-- Hooked on the data rather than IncrementCurrency, so anything moving TotalEarned is covered
	PlayerDataManager.OnDataChanged:Connect(function(player: Player, key: string)
		if key == "TotalEarned" then
			self:RefreshPlayerBoostFraction(player)
		end
	end)

	-- Gamepass tags land after the web ownership check, which can be well after the player joined
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

		-- Seeded off the loaded profile; spawned so a slow load doesn't hold up startup
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
