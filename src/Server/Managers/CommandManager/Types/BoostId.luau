-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Boosts = require(Shared.Config.Boosts)

return function(registry)
	-- Built from the config, so a boost added there needs no edit here
	local boostIds = {}
	for _, boost in Boosts.GetAllBoosts() do
		table.insert(boostIds, boost.Id)
	end
	table.sort(boostIds)

	registry:RegisterType("boostId", registry.Cmdr.Util.MakeEnumType("boostId", boostIds))
end
