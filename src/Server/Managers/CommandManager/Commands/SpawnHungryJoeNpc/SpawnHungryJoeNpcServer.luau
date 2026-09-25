-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local HungryJoeNpcManager = require(Managers.HungryJoeNpcManager)

return function(context, player: Player?)
	local target = player or context.Executor

	local success, reason = HungryJoeNpcManager:ForceHungryJoeVisit(target)
	if not success then
		return reason or "Failed to send Hungry Joe."
	end

	return reason or `Sent Hungry Joe to {target.Name}.`
end
