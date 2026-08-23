-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Crates = require(Shared.Config.Crates)

return function(registry)
	-- Data is an array of entries rather than a map, so the id comes off the value. It's already been
	-- pruned of anything missing its model by the time this runs, so the enum only offers crates that
	-- can actually be given.
	local crateIds = {}
	for _, crate in Crates.Data do
		table.insert(crateIds, crate.Id)
	end
	table.sort(crateIds)

	registry:RegisterType("crateId", registry.Cmdr.Util.MakeEnumType("crateId", crateIds))
end
