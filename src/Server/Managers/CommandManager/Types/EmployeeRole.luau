-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Employees = require(Shared.Config.Employees)

return function(registry)
	-- A dictionary, so the id comes off the value. Sorted, since its iteration order isn't stable
	local roleIds = {}
	for _, role in Employees.ROLES do
		table.insert(roleIds, role)
	end
	table.sort(roleIds)

	registry:RegisterType("employeeRole", registry.Cmdr.Util.MakeEnumType("employeeRole", roleIds))
end
