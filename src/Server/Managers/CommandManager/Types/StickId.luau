-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Sticks = require(Shared.Config.Sticks)

return function(registry)
	-- Data is an array of entries rather than a map, so the id comes off the value. It's already been
	-- pruned of anything missing its model by the time this runs, so the enum only offers sticks that
	-- can actually be granted.
	--
	-- Every stick and not just the ones the shop stocks: the diamond has no currency row on purpose
	-- (see Config.Sticks), and handing one over for testing is exactly what a staff command is for.
	local stickIds = {}
	for _, stick in Sticks.GetAllSticks() do
		table.insert(stickIds, stick.Id)
	end
	table.sort(stickIds)

	registry:RegisterType("stickId", registry.Cmdr.Util.MakeEnumType("stickId", stickIds))
end
