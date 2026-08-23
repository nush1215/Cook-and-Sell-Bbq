-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local SellNpcManager = require(Managers.SellNpcManager)

return function(context, player: Player?)
	local target = player or context.Executor

	local success, reason = SellNpcManager:ForceRichVisit(target)
	if not success then
		return reason or "Failed to send a rich customer."
	end

	return `Sent a rich customer to {target.Name}.`
end
