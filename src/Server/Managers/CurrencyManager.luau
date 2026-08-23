-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

--
local PlayerDataManager

--
local CurrencyManager = {
	-- (player, amount, source, isGain) after every currency change. `source` is the caller's label for
	-- what earned or spent it (e.g. "SkewerSale", "StickPurchase"); nil for admin grants that shouldn't
	-- count as part of the economy. `amount` is what actually landed, boosts included.
	OnCurrencyChanged = Signal.new(),
}

-- Grants currency, folding in the player's boosts unless told not to. `source` names what paid it out
-- and rides on OnCurrencyChanged; leave it nil for grants that shouldn't count in the economy.
function CurrencyManager:IncrementCurrency(player: Player, amount: number?, source: string?, ignoreBoosts: boolean?)
	amount = amount or 1

	-- TotalEarned tracks income rather than balance, so it's bumped by whatever actually lands -- boosts
	-- included -- and never comes back down the way Currency does when the player spends.
	if ignoreBoosts then
		PlayerDataManager:IncrementDataKey(player, "TotalEarned", amount)
		PlayerDataManager:IncrementDataKey(player, "Currency", amount)
		self.OnCurrencyChanged:Fire(player, amount, source, true)
		return
	end

	-- Add the additional currency from boosts. These tags are gamepass ids -- ShopManager tags an owner
	-- with the Id of every pass they hold -- so the strings have to match Config.Gamepasses exactly.
	local addition = 0
	if player:HasTag("x2Bux") then
		addition += amount
	end

	if player:HasTag("VIP") then
		addition += math.round(amount * 0.25)
	end

	-- Friends pay out on the base amount rather than on the gamepass subtotal, so the boost still
	-- lands for players who own neither pass -- which is what the HUD's "+N0%" label promises.
	local friendsAmount = player:GetAttribute("FriendsAmount") or 0
	addition += math.round(amount * (friendsAmount / 10))

	-- Add the additional currency from boosts
	amount += addition
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

return CurrencyManager
