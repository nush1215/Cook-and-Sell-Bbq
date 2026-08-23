-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)

return function(registry)
	-- Data is an array of entries rather than a map, so the id comes off the value. It's already been
	-- pruned of anything missing its models by the time this runs, so the enum only offers ingredients
	-- that can actually be rolled.
	local ingredientIds = {}
	for _, ingredient in Ingredients.Data do
		table.insert(ingredientIds, ingredient.Id)
	end
	table.sort(ingredientIds)

	registry:RegisterType("ingredientId", registry.Cmdr.Util.MakeEnumType("ingredientId", ingredientIds))
end
