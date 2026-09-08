-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local BuildManager = require(Managers.BuildManager)

-- Handed over as owned, not placed -- where it goes is the player's call, and GrantStructure is the shop's path too
return function(context, structureId: string, amount: number?, player: Player?)
	local target = player or context.Executor
	local count = amount or 1

	BuildManager:GrantStructure(target, structureId, count)

	return `Gave {count} {structureId} to {target.Name}.`
end
