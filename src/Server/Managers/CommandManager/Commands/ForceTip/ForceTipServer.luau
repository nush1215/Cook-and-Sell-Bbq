-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local CustomerTipManager = require(Managers.CustomerTipManager)
local PlayerDataManager = require(Managers.PlayerDataManager)

return function(context, player: Player?)
	local target = player or context.Executor

	CustomerTipManager:ForceNextCustomerTip(target)

	local armed = `{target.Name}'s next paying customer will tip. A wizard won't spend it, since it pays in luck.`

	-- Tips are held off through the tutorial, so an arming set now waits rather than firing
	local hasData, data = PlayerDataManager:GetPlayerData(target):await()
	if hasData and not data.TutorialCompleted then
		return `{armed} Not until they've finished the tutorial though, so this will sit armed until then.`
	end

	return armed
end
