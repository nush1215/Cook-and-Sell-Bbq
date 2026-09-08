-- Services
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Managers
local Managers = ServerScriptService.Server.Managers
local IngredientRollingManager = require(Managers.IngredientRollingManager)
local CurrencyManager = require(Managers.CurrencyManager)

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)
local GuiUtil = require(Shared.GuiUtil)

return function(context, tierId: string, count: number?, player: Player?)
	local target = player or context.Executor
	local tier = Ingredients.GetTierFromId(tierId)

	-- No count means fast-forward to the payout; the thresholds move on a rebalance, so typing one goes stale
	local rolls = count or tier.PityThreshold

	IngredientRollingManager:SetPlayerPityCount(target, tierId, rolls)

	if rolls < tier.PityThreshold then
		return `{target.Name} is {rolls} rolls into {tierId} pity, {tier.PityThreshold - rolls} short of the {tier.PityThreshold} that forces one.`
	end

	-- What the tier can pay out, and the least of it they'd need to actually buy one.
	local names = {}
	local cheapest

	for _, entry in tier.PityWeights do
		local ingredient = Ingredients.GetIngredientFromId(entry[1])

		table.insert(names, ingredient.Name)

		if not cheapest or ingredient.Price < cheapest.Price then
			cheapest = ingredient
		end
	end

	-- Roll, not pull: the counter is spent by the pull's first roll, so a wide base rolls the rest normally
	local armed = `{target.Name}'s next roll is a guaranteed {tierId}: {table.concat(names, ", ")}.`

	-- A heads-up, not a refusal -- the stand will hold something unaffordable, and the next pull overwrites it
	local canAfford, shortfall = CurrencyManager:CanAfford(target, cheapest.Price)
	if not canAfford then
		return `{armed} They can't afford one yet though -- ${GuiUtil.ConvertNumberWithCommas(shortfall)} short of {cheapest.Name}, so it'll sit unbought and their next pull will replace it.`
	end

	return armed
end
