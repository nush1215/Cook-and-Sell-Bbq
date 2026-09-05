-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Boosts = require(Shared.Config.Boosts)
local GuiUtil = require(Shared.GuiUtil)

--
local PlayerDataManager
local NotificationManager

-- Timed boosts: several stack, the biggest applies, and player data is the whole state -- see docs/balance.md.

--
local BoostManager = {}

-- The biggest live `boostId` multiplier, or 1 when they have none. Doesn't yield, so a roll can read it inline.
function BoostManager:GetBoostMultiplier(player: Player, boostId: string): number
	local playerData = PlayerDataManager:GetLoadedPlayerData(player)
	if not playerData then
		return 1
	end

	-- Expiry is re-checked here rather than trusted to the sweep, which a roll can land between
	local now = workspace:GetServerTimeNow()
	local highest = 1

	-- The max is the whole stacking rule: it falls to the next one on its own as the biggest runs out
	for _, boost in playerData.Boosts do
		if boost.Type == boostId and boost.ExpiresAt > now then
			highest = math.max(highest, boost.Amount)
		end
	end

	return highest
end

-- Drops every boost past its expiry, then the weakest of whatever is left over MAX_ACTIVE.
function BoostManager:_pruneExpired(player: Player)
	local playerData = PlayerDataManager:GetLoadedPlayerData(player)
	if not playerData then
		return
	end

	local now = workspace:GetServerTimeNow()
	local live = {}
	local total = 0

	for uid, boost in playerData.Boosts do
		total += 1

		if boost.ExpiresAt > now then
			table.insert(live, { Uid = uid, Boost = boost })
		end
	end

	-- What every sweep but the interesting one finds, so it costs a walk rather than a write
	if #live == total and total <= Boosts.MAX_ACTIVE then
		return
	end

	-- Strongest first, so whatever the cap trims is what was contributing least
	table.sort(live, function(a, b)
		if a.Boost.Amount == b.Boost.Amount then
			return a.Boost.ExpiresAt > b.Boost.ExpiresAt
		end

		return a.Boost.Amount > b.Boost.Amount
	end)

	local kept = {}
	for index = 1, math.min(#live, Boosts.MAX_ACTIVE) do
		kept[live[index].Uid] = live[index].Boost
	end

	PlayerDataManager:SetPlayerDataKey(player, "Boosts", kept)
end

-- Gives the player a boost of `amount` for `duration` seconds. Stacks -- it only applies while it's their biggest.
function BoostManager:GrantBoost(player: Player, boostId: string, amount: number, duration: number)
	if not Boosts.GetBoostFromId(boostId) then
		warn(`No boost called {boostId}, nothing granted`)
		return
	end

	local uid = HttpService:GenerateGUID(false)

	-- Absolute and on the synced clock, so it runs down offline and a client can count it without a server tick
	PlayerDataManager:SetPlayerDataKey(player, { "Boosts", uid }, {
		Type = boostId,
		Amount = amount,
		ExpiresAt = workspace:GetServerTimeNow() + duration,
	})

	-- Run here too, so a grant onto a full stack trims immediately rather than flashing an extra icon
	self:_pruneExpired(player)

	-- Trimmed straight back off as the weakest of a full stack, so there's nothing to announce
	local playerData = PlayerDataManager:GetLoadedPlayerData(player)
	if playerData and not playerData.Boosts[uid] then
		return
	end

	NotificationManager:NotifyNormal(player, {
		Text = `{Boosts.GetLabel(boostId, amount)} for {GuiUtil.ConvertSecondsToDHMS(duration)}`,
		Effect = "Success",
	})
end

function BoostManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	NotificationManager = require(script.Parent.NotificationManager)
end

function BoostManager:OnStart()
	-- One pass over every player rather than a timer per boost -- the cost is the walk, not how many they hold
	task.spawn(function()
		while true do
			task.wait(Boosts.SWEEP_INTERVAL)

			for _, player in Players:GetPlayers() do
				self:_pruneExpired(player)
			end
		end
	end)
end

return BoostManager
