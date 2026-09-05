-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local StickManager = require(Managers.StickManager)

-- Added to the owned count, as the shop does it -- the reconcile builds the tool off player data
return function(context, stickId: string, amount: number?, player: Player?)
	local target = player or context.Executor
	local count = amount or 1

	StickManager:GrantStick(target, stickId, count)

	return `Gave {count} {stickId} to {target.Name}.`
end
