-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local StickModel = require(Shared.StickModel)

----
local PlayerDataManager

-- The player's lifetime record, recorded per gameplay event rather than per counter. RecentSales stores the facts of each sale rather than a score, so a reputation can be retuned without rewriting saved data.
local StatsManager = {}

-- How far back the rolling sale window reaches: long enough that one bad haul doesn't tank a reputation
StatsManager.RECENT_SALES = 50

-- Records a cook settling, bumping the lifetime total and the per-state tally.
function StatsManager:RecordCookCompleted(player: Player, cookStateId: string)
	PlayerDataManager:IncrementDataKey(player, "SkewersCooked")

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local count = data.CookStateCounts[cookStateId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "CookStateCounts", cookStateId }, count + 1)
end

-- Records ingredients claimed off a stand. Purchases only -- IngredientIndex counts every obtain.
function StatsManager:RecordIngredientsBought(player: Player, amount: number?)
	PlayerDataManager:IncrementDataKey(player, "IngredientsBought", amount)
end

-- Records sticks bought from the stick shop, in currency or Robux.
function StatsManager:RecordSticksBought(player: Player, amount: number?)
	PlayerDataManager:IncrementDataKey(player, "SticksBought", amount)
end

-- Records a skewer coming off a dispenser with a flavour on it.
function StatsManager:RecordSkewerSauced(player: Player)
	PlayerDataManager:IncrementDataKey(player, "SkewersSauced")
end

-- Records a sale: the counts, the per-state tally, and one window entry per skewer -- so a bulk sale of burnt ones costs a reputation properly.
function StatsManager:RecordSaleCompleted(player: Player, skewerRecords: { StickModel.StickRecord })
	PlayerDataManager:IncrementDataKey(player, "SalesCompleted")
	PlayerDataManager:IncrementDataKey(player, "SkewersSold", #skewerRecords)

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- Written whole, or a six-skewer haul would be a dozen replica round trips mid-sale
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

	-- Oldest first, so trimming the front is what ages entries out of the window
	local overflow = #recentSales - self.RECENT_SALES
	if overflow > 0 then
		recentSales = table.move(recentSales, overflow + 1, #recentSales, 1, {})
	end

	PlayerDataManager:SetPlayerDataKey(player, "SoldCookStateCounts", soldCookStateCounts)
	PlayerDataManager:SetPlayerDataKey(player, "RecentSales", recentSales)
end

-- Records a customer leaving empty-handed. Off the sale window -- it counts custom lost, not quality.
function StatsManager:RecordSaleDeclined(player: Player)
	PlayerDataManager:IncrementDataKey(player, "SalesDeclined")
end

function StatsManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
end

return StatsManager
