-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local CurrencyManager = require(Managers.CurrencyManager)

return function(context, enabled: boolean, player: Player?)
	local target = player or context.Executor

	CurrencyManager:SetPlayerEarlyBoostEnabled(target, enabled)

	return `Early boost is now {if enabled then "on" else "off"} for {target.Name}.`
end
