-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)

return function(registry)
	-- Only tiers carrying a counter, built from PITY_TIERS so the ladder changing needs no edit here
	local pityTierIds = {}
	for _, tier in Ingredients.PITY_TIERS do
		table.insert(pityTierIds, tier.Id)
	end
	table.sort(pityTierIds)

	registry:RegisterType("pityTierId", registry.Cmdr.Util.MakeEnumType("pityTierId", pityTierIds))
end
