-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local UpdateLogManager = require(Managers.UpdateLogManager)

return function(context, player: Player?)
	local target = player or context.Executor

	if not UpdateLogManager:DebugResetUpdateLog(target) then
		return `{target.Name}'s data isn't loaded.`
	end

	return `{target.Name} will be shown the update log on their next join.`
end
