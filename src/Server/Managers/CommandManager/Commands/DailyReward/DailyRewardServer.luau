-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local DailyRewardManager = require(Managers.DailyRewardManager)

return function(context, day: number, secondsLeft: number, player: Player?)
	local target = player or context.Executor

	if not DailyRewardManager:DebugSetDailyReward(target, day, secondsLeft) then
		return `{target.Name}'s data isn't loaded.`
	end

	return `{target.Name} is on daily reward day {day}, unlocking in {secondsLeft}s.`
end
