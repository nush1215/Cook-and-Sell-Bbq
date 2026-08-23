--[[
	OnInitCallback: This function runs when the BadgeService is initialized.
	It is best to attach listeners in this function. (SHOULD ONLY BE CALLED ONCE!!!)
--]]

--[[
	toAwardCallback: This function should be called when the condition for awarding
	the badge is met on your listener. It will give the badge to the player.
--]]

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local PlayerDataManager = require(Managers.PlayerDataManager)
local SellNpcManager = require(Managers.SellNpcManager)

-- Shared
local Shared = ReplicatedStorage.Shared
local StickModel = require(Shared.StickModel)

type ToAwardCallback = (player: Player, badgeKey: string, dontAnnounce: boolean?) -> ()

export type Badge = {
	Name: string,
	Key: string,
	BadgeId: number,
	OnInitCallback: (toAwardCallback: ToAwardCallback) -> (),
}

-- Runs `check` against every player: as they join, and once for anyone already in (a server
-- hot-reload). Badges are wired up before any player is, so a listener alone would only ever see the
-- sales made from here on -- this is the other half, the one that catches up on what's already saved.
local function checkEveryPlayer(check: (player: Player) -> ())
	Players.PlayerAdded:Connect(check)

	for _, player in Players:GetPlayers() do
		check(player)
	end
end

-- Builds the listener for a milestone off the lifetime SkewersSold counter. Watched through
-- OnDataChanged rather than SellNpcManager.OnSaleCompleted so the count is read post-increment and any
-- future path that sells a skewer counts too. Also checked once when a player's data is up, so a player
-- who passed the mark before the badge existed still gets it without having to sell again.
local function onSkewersSold(badgeKey: string, threshold: number)
	return function(toAwardCallback: ToAwardCallback)
		PlayerDataManager.OnDataChanged:Connect(function(player: Player, key: string, newValue: any)
			if key == "SkewersSold" and newValue >= threshold then
				toAwardCallback(player, badgeKey)
			end
		end)

		checkEveryPlayer(function(player: Player)
			PlayerDataManager:GetPlayerDataKey(player, "SkewersSold"):andThen(function(skewersSold: number)
				if skewersSold >= threshold then
					toAwardCallback(player, badgeKey)
				end
			end)
		end)
	end
end

-- Builds the listener for the badge given for selling a skewer in one cook state. Nothing counts sales
-- per state the way SkewersSold counts them overall, so this reads the states off the sale itself. A
-- rich customer clearing the stand can carry several states at once and each one counts, so the haul is
-- walked rather than sampled.
--
-- The join check is best-effort by nature: RecentSales is the only lasting record of what a player has
-- sold and it only reaches StatsManager.RECENT_SALES skewers back, so a state last sold before that
-- window is picked up by selling it again rather than on the way in.
local function onCookStateSold(badgeKey: string, cookStateId: string)
	return function(toAwardCallback: ToAwardCallback)
		SellNpcManager.OnSaleCompleted:Connect(function(player: Player, _, skewerRecords)
			for _, skewerRecord in skewerRecords do
				if StickModel.GetCookStateId(skewerRecord) == cookStateId then
					toAwardCallback(player, badgeKey)
					break
				end
			end
		end)

		checkEveryPlayer(function(player: Player)
			PlayerDataManager:GetPlayerDataKey(player, "RecentSales"):andThen(function(recentSales: { any })
				for _, sale in recentSales do
					if sale.CookState == cookStateId then
						toAwardCallback(player, badgeKey)
						break
					end
				end
			end)
		end)
	end
end

local Badges = {}

Badges.Data = {
	{
		Name = "Sold your First BBQ",
		Key = "SoldFirstBbq",
		BadgeId = 4202608156635144,
		OnInitCallback = onSkewersSold("SoldFirstBbq", 1),
	},
	{
		Name = "Sold 10 BBQ",
		Key = "Sold10Bbq",
		BadgeId = 2471014596046371,
		OnInitCallback = onSkewersSold("Sold10Bbq", 10),
	},
	{
		Name = "Sold 50 BBQ",
		Key = "Sold50Bbq",
		BadgeId = 3041155699638842,
		OnInitCallback = onSkewersSold("Sold50Bbq", 50),
	},
	{
		Name = "Sold 100 BBQ",
		Key = "Sold100Bbq",
		BadgeId = 1031580123049311,
		OnInitCallback = onSkewersSold("Sold100Bbq", 100),
	},
	-- One per cook state, in the order they come up along the grill, so the set reads as the ladder it is.
	{
		Name = "Sell Raw BBQ",
		Key = "SellRawBbq",
		BadgeId = 3219202540782927,
		OnInitCallback = onCookStateSold("SellRawBbq", "Raw"),
	},
	{
		Name = "Sell Perfectly Cooked BBQ",
		Key = "SellPerfectBbq",
		BadgeId = 2400374755391062,
		OnInitCallback = onCookStateSold("SellPerfectBbq", "Perfect"),
	},
	{
		Name = "Sell Cooked BBQ",
		Key = "SellCookedBbq",
		BadgeId = 3970221877060767,
		OnInitCallback = onCookStateSold("SellCookedBbq", "Cooked"),
	},
	{
		Name = "Sell Overcooked BBQ",
		Key = "SellOvercookedBbq",
		BadgeId = 1309377698524692,
		OnInitCallback = onCookStateSold("SellOvercookedBbq", "Overcooked"),
	},
	{
		Name = "Sell Charred BBQ",
		Key = "SellCharredBbq",
		BadgeId = 1569963788552987,
		OnInitCallback = onCookStateSold("SellCharredBbq", "Charred"),
	},
} :: { Badge }

function Badges.GetBadgeFromKey(key: string): Badge
	for _, v in Badges.Data do
		if v.Key == key then
			return v
		end
	end

	return nil
end

function Badges.GetBadges()
	return Badges.Data
end

return Badges
