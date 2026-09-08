-- OnInitCallback: runs once as BadgeService initializes. Attach listeners here.

-- toAwardCallback: call from your listener once the badge's condition is met, to award it.

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

-- Runs `check` on join and once for anyone already in, so a badge catches up on what's already saved.
local function checkEveryPlayer(check: (player: Player) -> ())
	Players.PlayerAdded:Connect(check)

	for _, player in Players:GetPlayers() do
		check(player)
	end
end

-- A SkewersSold milestone listener, through OnDataChanged so it reads post-increment and covers future sale paths.
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

-- A per-cook-state sale listener, walking the haul since a rich customer carries several states. The join check is best-effort -- RecentSales only reaches so far back.
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
	-- One per cook state, in grill order, so the set reads as the ladder it is
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
