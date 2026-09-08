-- Services
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Managers
local Managers = ServerScriptService.Server.Managers
local BoostManager = require(Managers.BoostManager)

-- Shared
local Shared = ReplicatedStorage.Shared
local Boosts = require(Shared.Config.Boosts)
local GuiUtil = require(Shared.GuiUtil)

return function(context, boostId: string, amount: number, duration: number, player: Player?)
	local target = player or context.Executor

	-- Read either side of the grant, since what a roll ends up reading isn't always what was just given
	local before = BoostManager:GetBoostMultiplier(target, boostId)
	BoostManager:GrantBoost(target, boostId, amount, duration)
	local after = BoostManager:GetBoostMultiplier(target, boostId)

	local granted = `{target.Name} has {Boosts.GetLabel(boostId, amount)} for {GuiUtil.ConvertSecondsToDHMS(duration)}.`

	if after > amount then
		return `{granted} It's stacked under their {Boosts.GetLabel(boostId, after)} though, so nothing changes until that one runs out.`
	end

	-- Clamped where it's read, so a bigger number than this is stored and shown but never reaches a roll
	if boostId == "Luck" and amount > Boosts.MAX_LUCK then
		return `{granted} Luck is clamped at {Boosts.MAX_LUCK}x when it's read though, so the roll only sees {Boosts.MAX_LUCK}x.`
	end

	if before > 1 then
		return `{granted} It takes over from {Boosts.GetLabel(boostId, before)}, which keeps counting down underneath it.`
	end

	return granted
end
