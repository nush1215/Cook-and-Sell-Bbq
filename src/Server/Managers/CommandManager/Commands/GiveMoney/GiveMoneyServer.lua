-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local CurrencyManager = require(Managers.CurrencyManager)

return function(context, amount: number, player: Player?)
	local target = player or context.Executor

	-- No source: an admin grant isn't part of the economy, so it stays out of the analytics.
	CurrencyManager:IncrementCurrency(target, amount, nil, true)

	return `Gave {amount} currency to {target.Name}.`
end
