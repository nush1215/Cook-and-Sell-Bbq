-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Structures = require(Shared.Config.Structures)

return function(registry)
	-- Data is an array of entries rather than a map, so the id comes off the value. It's already been
	-- pruned of anything missing its model by the time this runs, so the enum only offers structures
	-- that can actually be built.
	--
	-- Every structure and not just the grillers: the ids read as what they are (IronGrill, GasGrill,
	-- WoodenStickStand), so Cmdr's own autocomplete does the filtering -- typing "Grill" narrows to the
	-- grills on its own, and a stand is a keystroke away rather than a second command.
	local structureIds = {}
	for _, structure in Structures.Data do
		table.insert(structureIds, structure.Id)
	end
	table.sort(structureIds)

	registry:RegisterType("structureId", registry.Cmdr.Util.MakeEnumType("structureId", structureIds))
end
