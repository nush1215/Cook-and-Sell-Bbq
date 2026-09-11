-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local EmployeeManager = require(Managers.EmployeeManager)

return function(context, player: Player?)
	local target = player or context.Executor

	local fired = EmployeeManager:FireAllEmployees(target)

	return `Fired {fired} employee(s) for {target.Name}.`
end
