-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local DailyQuestManager = require(Managers.DailyQuestManager)

return function(context, secondsLeft: number, player: Player?)
	local target = player or context.Executor

	if not DailyQuestManager:DebugSetDailyQuestReset(target, secondsLeft) then
		return `{target.Name} has no daily quest board yet.`
	end

	return `{target.Name}'s daily quests reset in {secondsLeft}s.`
end
