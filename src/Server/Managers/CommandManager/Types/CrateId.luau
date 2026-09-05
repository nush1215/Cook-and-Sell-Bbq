-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Crates = require(Shared.Config.Crates)

return function(registry)
	-- An array, so the id comes off the value. Already pruned of missing models, so the enum only offers real crates
	local crateIds = {}
	for _, crate in Crates.Data do
		table.insert(crateIds, crate.Id)
	end
	table.sort(crateIds)

	registry:RegisterType("crateId", registry.Cmdr.Util.MakeEnumType("crateId", crateIds))
end
