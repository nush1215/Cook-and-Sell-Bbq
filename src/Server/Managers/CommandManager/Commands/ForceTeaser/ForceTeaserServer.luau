-- Services
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Managers
local Managers = ServerScriptService.Server.Managers
local IngredientRollingManager = require(Managers.IngredientRollingManager)
local PlayerDataManager = require(Managers.PlayerDataManager)

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)
local GuiUtil = require(Shared.GuiUtil)

return function(context, player: Player?)
	local target = player or context.Executor

	IngredientRollingManager:ForceNextTeaser(target)

	local armed = `{target.Name}'s next pull will tease on a random stand.`

	local hasData, data = PlayerDataManager:GetPlayerData(target):await()
	if not hasData then
		return armed
	end

	-- The teaser is held off until onboarding is done, so an arming set now waits rather than firing
	if not data.TutorialCompleted then
		return `{armed} Not until they've finished the tutorial though -- it pins their first stand, so this will sit armed until then.`
	end

	-- Forcing skips the roll but can't conjure a pool, so a rich enough player still teases nothing
	local candidates = IngredientRollingManager:GetTeaserCandidates(data.Currency)
	if #candidates == 0 then
		return `{armed} Nothing's out of reach at ${GuiUtil.ConvertNumberWithCommas(data.Currency)} in hand though, so it'll draw an empty pool and the arming will be spent on nothing.`
	end

	-- The dearest of them, being the last thing to leave the pool as their balance climbs
	local dearest

	for _, ingredientId in candidates do
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)

		if not dearest or ingredient.Price > dearest.Price then
			dearest = ingredient
		end
	end

	return `{armed} {#candidates} to draw from, up to {dearest.Name} at ${GuiUtil.ConvertNumberWithCommas(dearest.Price)}.`
end
