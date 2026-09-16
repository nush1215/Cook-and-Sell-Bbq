-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local DailyQuestManager = require(Managers.DailyQuestManager)

return function(context, slot: number, player: Player?)
	local target = player or context.Executor

	if not DailyQuestManager:DebugProgressDailyQuest(target, slot) then
		return `{target.Name} has no quest on tile {slot}.`
	end

	return `{target.Name}'s quest on tile {slot} is finished.`
end
