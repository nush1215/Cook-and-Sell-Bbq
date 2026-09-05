-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Sticks = require(Shared.Config.Sticks)

return function(registry)
	-- An array, so the id comes off the value. Already pruned of missing models, so the enum only offers grantable ones
	local stickIds = {}
	for _, stick in Sticks.GetAllSticks() do
		table.insert(stickIds, stick.Id)
	end
	table.sort(stickIds)

	registry:RegisterType("stickId", registry.Cmdr.Util.MakeEnumType("stickId", stickIds))
end
