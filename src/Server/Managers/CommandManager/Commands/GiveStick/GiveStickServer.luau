-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local StickManager = require(Managers.StickManager)

-- Added to the owned count rather than put anywhere, the same as the stick shop does it: sticks are a
-- stacking backpack tool the reconcile builds off player data, so granting one is a write and nothing
-- else. GrantStick is what the shop, the crates and the starter pack all call too.
return function(context, stickId: string, amount: number?, player: Player?)
	local target = player or context.Executor
	local count = amount or 1

	StickManager:GrantStick(target, stickId, count)

	return `Gave {count} {stickId} to {target.Name}.`
end
