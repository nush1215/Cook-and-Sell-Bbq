-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local OfflineEarningManager = require(Managers.OfflineEarningManager)

return function(context, seconds: number, player: Player?)
	local target = player or context.Executor

	local report = OfflineEarningManager:DebugSimulate(target, seconds)
	if not report then
		return `{target.Name}'s data isn't loaded.`
	end

	return `{target.Name}'s workers made {report.Made}, cooked {report.Cooked} and sold {report.Sold} BBQ for ${report.Earned} `
		.. `over {math.floor(report.WorkedSeconds)}s, stopped by {report.Stopped or "nothing"}.`
end
