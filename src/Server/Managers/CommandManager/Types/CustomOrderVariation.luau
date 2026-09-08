-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local CustomOrderNpc = require(Shared.Config.CustomOrderNpc)

return function(registry)
	-- Built from the config so a variation added there needs no edit here
	local variations = {}
	for variation in CustomOrderNpc.VARIATIONS do
		table.insert(variations, variation)
	end
	table.sort(variations)

	registry:RegisterType(
		"customOrderVariation",
		registry.Cmdr.Util.MakeEnumType("customOrderVariation", variations)
	)
end
