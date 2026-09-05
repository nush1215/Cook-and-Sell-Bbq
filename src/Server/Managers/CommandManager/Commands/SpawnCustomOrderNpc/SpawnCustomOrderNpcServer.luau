-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local CustomOrderNpcManager = require(Managers.CustomOrderNpcManager)

return function(context, player: Player?, variation: string?)
	local target = player or context.Executor

	local success, message = CustomOrderNpcManager:ForceCustomOrderVisit(target, variation)
	if not success then
		return message or "Failed to send a custom order customer."
	end

	-- A queued visit says so, since nothing walks in until they stock the stand
	return message or `Sent a custom order customer to {target.Name}.`
end
