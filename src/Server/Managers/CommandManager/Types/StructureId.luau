-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Structures = require(Shared.Config.Structures)

return function(registry)
	-- An array, so the id comes off the value. Already pruned of missing models, so the enum only offers buildable ones
	local structureIds = {}
	for _, structure in Structures.Data do
		table.insert(structureIds, structure.Id)
	end
	table.sort(structureIds)

	registry:RegisterType("structureId", registry.Cmdr.Util.MakeEnumType("structureId", structureIds))
end
