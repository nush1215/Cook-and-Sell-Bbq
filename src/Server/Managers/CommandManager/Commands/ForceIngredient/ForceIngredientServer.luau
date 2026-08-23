-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local IngredientRollingManager = require(Managers.IngredientRollingManager)

return function(context, ingredientId: string, player: Player?)
	local target = player or context.Executor

	IngredientRollingManager:ForceNextIngredient(target, ingredientId)

	return `{target.Name}'s next roll will land {ingredientId} on stand 1.`
end
