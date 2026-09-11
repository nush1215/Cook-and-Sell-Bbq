-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local IngredientManager = require(Managers.IngredientManager)

-- Added to the owned count, as a claimed roll does it -- the reconcile builds the tool off player data
return function(context, ingredientId: string, amount: number?, player: Player?)
	local target = player or context.Executor
	local count = amount or 1

	IngredientManager:GrantIngredient(target, ingredientId, count)

	return `Gave {count} {ingredientId} to {target.Name}.`
end
