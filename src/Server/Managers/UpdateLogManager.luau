-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local UpdateLogs = require(Shared.Config.UpdateLogs)

-- Managers
local PlayerDataManager = require(script.Parent.PlayerDataManager)

-- Remembers the newest update each player has had the log up for, so it only comes up on its own once per update, and never for a new player.
local UpdateLogManager = {
	MarkUpdateLogSeenEvent = Network.Event("MarkUpdateLogSeen"), -- client -> server ()
}

-- Stamps the newest update as seen. A no-op once it already is, which is the guard against a spammed remote.
function UpdateLogManager:MarkUpdateLogSeen(player: Player)
	local data = PlayerDataManager:GetLoadedPlayerData(player)
	local newestTitle = UpdateLogs.Data[1].Title

	if not data or data.LastSeenUpdateLog == newestTitle then
		return
	end

	PlayerDataManager:SetPlayerDataKey(player, "LastSeenUpdateLog", newestTitle)
end

-- Clears a player's stamp so the log comes up again on their next join. For the resetUpdateLog command.
function UpdateLogManager:DebugResetUpdateLog(player: Player): boolean
	if not PlayerDataManager:GetLoadedPlayerData(player) then
		return false
	end

	PlayerDataManager:SetPlayerDataKey(player, "LastSeenUpdateLog", "")
	return true
end

function UpdateLogManager:OnInit()
	-- On Init, so the stamp is in place before any profile can finish loading
	PlayerDataManager:RegisterPostLoadCallback(function(_, data)
		-- A new player has nothing to catch up on, so they start with the newest already seen
		if not data.TutorialCompleted then
			data.LastSeenUpdateLog = UpdateLogs.Data[1].Title
		end
	end)
end

function UpdateLogManager:OnStart()
	self.MarkUpdateLogSeenEvent:OnServerEvent(function(player: Player)
		self:MarkUpdateLogSeen(player)
	end)
end

return UpdateLogManager
