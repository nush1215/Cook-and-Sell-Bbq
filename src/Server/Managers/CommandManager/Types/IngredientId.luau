-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)

return function(registry)
	-- An array, so the id comes off the value. Already pruned of missing models, so the enum only offers rollable ones
	local ingredientIds = {}
	for _, ingredient in Ingredients.Data do
		table.insert(ingredientIds, ingredient.Id)
	end
	table.sort(ingredientIds)

	registry:RegisterType("ingredientId", registry.Cmdr.Util.MakeEnumType("ingredientId", ingredientIds))
end
