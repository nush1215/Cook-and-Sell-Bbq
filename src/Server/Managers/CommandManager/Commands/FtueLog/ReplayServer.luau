-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local ReplayManager = require(Managers.ReplayManager)

local STOP_KEYWORD = "stop"

return function(context, key: string)
	local player = context.Executor

	if string.lower(key) == STOP_KEYWORD then
		ReplayManager:StopReplayForViewer(player)
		return "Stopped the replay."
	end

	-- A missing DataStore throws rather than answering, and in Studio that needs API access turning on
	local ran, record, problem = pcall(function()
		return ReplayManager:LoadReplay(key)
	end)

	if not ran then
		return `Loading that replay threw: {record}`
	end

	if not record then
		return `Couldn't load that replay: {problem}`
	end

	ReplayManager:SendReplayToViewer(player, record)

	return `Playing {record.Username}'s {#record.Samples} samples on your base. Space plays, E is their view, `
		.. `"replay stop" ends it. Run it on an empty base -- your own build is not in the recording.`
end
