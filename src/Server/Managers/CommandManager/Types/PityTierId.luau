-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)

return function(registry)
	-- Only the tiers that actually carry a counter, so the enum can't offer a Common whose pity would never
	-- fire. Built from PITY_TIERS rather than Tiers, which means a tier added to the ladder shows up here
	-- and one that loses its multiplier drops out, without this file being touched.
	local pityTierIds = {}
	for _, tier in Ingredients.PITY_TIERS do
		table.insert(pityTierIds, tier.Id)
	end
	table.sort(pityTierIds)

	registry:RegisterType("pityTierId", registry.Cmdr.Util.MakeEnumType("pityTierId", pityTierIds))
end
