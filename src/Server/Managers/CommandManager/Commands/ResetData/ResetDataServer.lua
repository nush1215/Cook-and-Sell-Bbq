-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local PlayerDataManager = require(Managers.PlayerDataManager)

return function(context, player: Player)
	local success, error = PlayerDataManager:ResetPlayerData(player)
	if not success then
		return error or "Failed to reset player data."
	end

	player:Kick("Your data was reset. Please rejoin.")

	return `Reset data for {player.Name}.`
end
