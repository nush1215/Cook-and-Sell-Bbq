-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Rating = require(Shared.Config.Rating)

----
local PlayerDataManager
local SellNpcManager
local GrillerManager

-- The player's star reputation, scored off the rolling windows and the build they've put up. Nothing here is saved: the rating is derived, so retuning Config.Rating re-rates everyone's existing history rather than leaving old entries priced by old rules.
local RatingManager = {
	-- Carries nothing: the rating it reports is read back off the player here, not taken from the client
	StatsPanelOpenedEvent = Network.Event("StatsPanelOpened", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 2 },
	}),

	OnStatsPanelOpened = Signal.new(), -- (player, stars?)
}

-- The data keys that move a trait. Anything else writing to a profile doesn't need a re-score
local WATCHED_KEYS = {
	RecentSales = true,
	CustomOrderHistory = true,
	SaleRefusals = true,
	Structures = true,
	Unlocks = true,
	Plots = true,
}

-- Every trait's stars and the headline, with nil for a trait too little has happened for. Yields on the refusal read.
function RatingManager:GetPlayerRating(player: Player)
	local data = PlayerDataManager:GetLoadedPlayerData(player)
	if not data then
		return nil
	end

	-- Read through SellNpcManager rather than off SaleRefusals here, so the decay is only written down once
	local refusals = SellNpcManager:GetStandingSaleRefusals(player)

	local scores = {
		Cooking = Rating.ScoreCooking(data.RecentSales),
		Satisfaction = Rating.ScoreSatisfaction(data.CustomOrderHistory, refusals),
		Menu = Rating.ScoreMenu(data.RecentSales),
		Kitchen = Rating.ScoreKitchen(data, GrillerManager:CountPlacedGrillers(data)),
	}

	local rating = { Overall = Rating.ToStars(Rating.CombineTraits(scores)) }
	for _, traitId in Rating.TRAITS do
		rating[traitId] = Rating.ToStars(scores[traitId])
	end

	return rating
end

-- Mirrors the rating onto the player, so any client can draw it -- the channel BoostFraction already uses.
function RatingManager:RefreshPlayerRating(player: Player)
	local rating = self:GetPlayerRating(player)

	-- Re-checked after the read, which yields: they may have left in the gap
	if not rating or not player:IsDescendantOf(Players) then
		return
	end

	player:SetAttribute(Rating.OVERALL_ATTRIBUTE, rating.Overall)

	-- A trait with nothing behind it clears rather than publishing a zero, so the UI can show it as pending
	for _, traitId in Rating.TRAITS do
		player:SetAttribute(Rating.GetTraitAttribute(traitId), rating[traitId])
	end
end

-- Announces that the player opened their stats panel, with what they were rated at the time.
function RatingManager:RecordStatsPanelOpened(player: Player)
	self.OnStatsPanelOpened:Fire(player, player:GetAttribute(Rating.OVERALL_ATTRIBUTE))
end

function RatingManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	SellNpcManager = require(script.Parent.SellNpcManager)
	GrillerManager = require(script.Parent.GrillerManager)
end

function RatingManager:OnStart()
	self.StatsPanelOpenedEvent:OnServerEvent(function(player: Player)
		self:RecordStatsPanelOpened(player)
	end)

	-- Hooked on the data rather than each system's own signal, so a command-bar write re-scores like a sale
	PlayerDataManager.OnDataChanged:Connect(function(player: Player, key: string)
		if not WATCHED_KEYS[key] then
			return
		end

		task.spawn(function()
			self:RefreshPlayerRating(player)
		end)
	end)

	local function watchPlayer(player: Player)
		-- Seeded off the loaded profile; spawned so a slow load doesn't hold up startup
		task.spawn(function()
			local hasData = PlayerDataManager:GetPlayerData(player):await()
			if hasData and player:IsDescendantOf(Players) then
				self:RefreshPlayerRating(player)
			end
		end)
	end

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
end

return RatingManager
