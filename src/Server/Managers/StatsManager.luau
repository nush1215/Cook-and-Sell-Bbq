-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local StickModel = require(Shared.StickModel)

----
local PlayerDataManager

--[[
	The player's lifetime record: how much they've cooked, bought and sold, and how well. Distinct from
	the inventories those actions move around -- those rise and fall, these only ever climb, so this is
	the source of truth for "how much has this player ever done" the way IndexManager is for "has this
	player ever seen this ingredient".

	Recorded per gameplay event rather than per counter -- one call when a cook settles, one when a sale
	closes -- so a hook site in GrillerManager or SellNpcManager is a single line, and what a finished
	sale actually bumps is answered once, here, instead of at every caller.

	RecentSales is the odd one out and the reason this exists now rather than later: a stall reputation
	has to be read off a rolling window of what the player has lately been serving, and a window can only
	be averaged over sales it was already collecting. It stores the facts of each skewer sold rather than
	a quality score, so the rating stays a pure function of them and can be retuned without rewriting
	anything already saved.
]]
local StatsManager = {}

-- How many skewers back the rolling sale window reaches. Sized to a few sessions of selling: long enough
-- that one bad haul doesn't tank a reputation, short enough that a run of them does.
StatsManager.RECENT_SALES = 50

-- Records a cook settling at a griller, whatever state it landed in. Bumps the lifetime total and the
-- per-state tally, so how much a player cooks and how well they cook it are both readable.
function StatsManager:RecordCookCompleted(player: Player, cookStateId: string)
	PlayerDataManager:IncrementDataKey(player, "SkewersCooked")

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local count = data.CookStateCounts[cookStateId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "CookStateCounts", cookStateId }, count + 1)
end

-- Records ingredients claimed off a rolling stand (default one). Purchases only -- a granted or
-- code-rewarded ingredient isn't something the player spent on, and IngredientIndex already counts every
-- obtain however it arrived.
function StatsManager:RecordIngredientsBought(player: Player, amount: number?)
	PlayerDataManager:IncrementDataKey(player, "IngredientsBought", amount)
end

-- Records sticks bought from the stick shop (default one), whether paid for in currency or Robux.
function StatsManager:RecordSticksBought(player: Player, amount: number?)
	PlayerDataManager:IncrementDataKey(player, "SticksBought", amount)
end

-- Records a skewer coming off a dispenser with a flavour on it.
function StatsManager:RecordSkewerSauced(player: Player)
	PlayerDataManager:IncrementDataKey(player, "SkewersSauced")
end

-- Records a customer leaving with skewers: the sale and skewer counts, the lifetime per-state tally of what
-- was served, plus one entry per skewer onto the rolling window a stall reputation is read off. A rich
-- customer clearing the stand is one sale and one entry per skewer in the haul, so a bulk sale of burnt
-- skewers costs a reputation as much as it should.
function StatsManager:RecordSaleCompleted(player: Player, skewerRecords: { StickModel.StickRecord })
	PlayerDataManager:IncrementDataKey(player, "SalesCompleted")
	PlayerDataManager:IncrementDataKey(player, "SkewersSold", #skewerRecords)

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- Both tallied in one pass and written whole rather than a write per skewer: a six-skewer haul would
	-- otherwise be a dozen replica round trips in the middle of a sale. Same reason RecentSales isn't built
	-- with InsertCappedPlayerDataKey, which re-reads the profile per value.
	local soldCookStateCounts = table.clone(data.SoldCookStateCounts)
	local recentSales = table.clone(data.RecentSales)
	for _, skewerRecord in skewerRecords do
		local cookStateId = StickModel.GetCookStateId(skewerRecord)
		soldCookStateCounts[cookStateId] = (soldCookStateCounts[cookStateId] or 0) + 1

		table.insert(recentSales, {
			CookState = cookStateId,
			Sauce = skewerRecord.Sauce,
			Mutation = skewerRecord.Mutation,
			Value = StickModel.GetSellValue(skewerRecord),
		})
	end

	-- Oldest first, so trimming the front is what ages entries out of the window.
	local overflow = #recentSales - self.RECENT_SALES
	if overflow > 0 then
		recentSales = table.move(recentSales, overflow + 1, #recentSales, 1, {})
	end

	PlayerDataManager:SetPlayerDataKey(player, "SoldCookStateCounts", soldCookStateCounts)
	PlayerDataManager:SetPlayerDataKey(player, "RecentSales", recentSales)
end

-- Records a customer leaving empty-handed, whether the offer was turned down or left to lapse. Nothing
-- was served, so this stays off the sale window -- it's a count of custom lost, not of quality.
function StatsManager:RecordSaleDeclined(player: Player)
	PlayerDataManager:IncrementDataKey(player, "SalesDeclined")
end

function StatsManager:OnInit()
	--
	PlayerDataManager = require(script.Parent.PlayerDataManager)
end

return StatsManager
