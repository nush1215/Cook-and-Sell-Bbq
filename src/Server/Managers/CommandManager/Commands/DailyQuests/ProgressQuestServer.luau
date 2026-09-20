-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local DailyQuestManager = require(Managers.DailyQuestManager)

return function(context, slot: number, amount: number, player: Player?)
	local target = player or context.Executor

	if not DailyQuestManager:DebugProgressDailyQuest(target, slot, amount) then
		return `{target.Name} has no quest on tile {slot}.`
	end

	return `Added {amount} to {target.Name}'s quest on tile {slot}.`
end
