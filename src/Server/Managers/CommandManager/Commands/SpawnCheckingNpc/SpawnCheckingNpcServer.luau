-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local SellNpcManager = require(Managers.SellNpcManager)

return function(context, player: Player?)
	local target = player or context.Executor

	local success, message = SellNpcManager:ForceCheckingVisit(target)
	if not success then
		return message or "Failed to send a checking customer."
	end

	-- A stocked stand says so, since it buys on arrival rather than standing there asking
	return message or `Sent a checking customer to {target.Name}.`
end
