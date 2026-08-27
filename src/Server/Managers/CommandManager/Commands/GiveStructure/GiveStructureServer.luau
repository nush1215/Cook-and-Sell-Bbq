-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local BuildManager = require(Managers.BuildManager)

-- Handed over as owned rather than placed: where a structure goes is the player's call, and there's no
-- cell to put one on from a chat bar. It lands in the backpack as a build tool the same way a shop
-- purchase does, since GrantStructure is what the shop calls too.
return function(context, structureId: string, amount: number?, player: Player?)
	local target = player or context.Executor
	local count = amount or 1

	BuildManager:GrantStructure(target, structureId, count)

	return `Gave {count} {structureId} to {target.Name}.`
end
