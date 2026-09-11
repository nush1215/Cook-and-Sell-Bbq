-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Employees = require(Shared.Config.Employees)

return function(registry)
	-- Straight off the config array, so a third body only has to be added there
	registry:RegisterType("employeeBody", registry.Cmdr.Util.MakeEnumType("employeeBody", Employees.BODIES))
end
