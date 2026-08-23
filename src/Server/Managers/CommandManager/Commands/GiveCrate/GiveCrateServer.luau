-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local CrateManager = require(Managers.CrateManager)

return function(context, crateId: string, amount: number?, player: Player?)
	local target = player or context.Executor
	local count = amount or 1

	CrateManager:GrantCrate(target, crateId, count)

	return `Gave {count} {crateId} to {target.Name}.`
end
