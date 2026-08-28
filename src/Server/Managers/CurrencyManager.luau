-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
}

-- What `amount` becomes once the player's boosts are folded in: the gamepasses they hold, how many
-- friends are in the server with them, and the head start a new player's income gets. Every one is
-- figured on the base amount rather than stacking on each other, so a brand-new player holding x2Bux
-- gets 1 + 1 + 0.5 rather than 2 x 1.5.
--
-- Split out of IncrementCurrency rather than left inline because the sell stand has to show this number
-- before it pays it: an offer that quotes the plain figure and then banks a bigger one is the display
-- disagreeing with the payout in front of the player. Both go through here, so the number shown is the
-- number banked by construction rather than by two places agreeing to round the same way.
--
-- Doesn't yield, and mustn't start: this runs on every sale and on every reward grant, and a yield would
-- change the contract of every caller.
function CurrencyManager:GetBoostedAmount(player: Player, amount: number): number
	-- These tags are gamepass ids -- ShopManager tags an owner with the Id of every pass they hold -- so
	-- the strings have to match Config.Gamepasses exactly.
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

	-- The head start a new player's income gets, on the base amount like the two above it. Read off the
	-- data as it stands rather than awaited, for the no-yielding reason above. A profile that hasn't
	-- loaded yet earns no bonus: there's no lifetime figure to decay it against, and assuming zero
	-- earned would hand the full boost to whoever it is -- established player or not.
	local playerData = PlayerDataManager:GetLoadedPlayerData(player)
	if playerData then
		addition += math.round(amount * EarlyBoost.GetBonus(playerData.TotalEarned))
	end

	return amount + addition
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

return CurrencyManager
