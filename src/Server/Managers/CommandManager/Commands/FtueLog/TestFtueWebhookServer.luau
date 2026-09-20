-- Services
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local FtueLogManager = require(Managers.FtueLogManager)

return function(context)
	-- Read before the post, which yields, so the trail count is the one the command was typed against
	local status = FtueLogManager:GetStatusSummary()

	-- A missing secret and HTTP being off both throw rather than answering, so the raw message is the useful part
	local ran, posted, message = pcall(function()
		return FtueLogManager:SendTestReport(context.Executor)
	end)

	-- A solo playtest can't read the Creator Hub's store at all, which is most of what a throw means in Studio
	if not ran then
		local hint = if RunService:IsStudio()
			then " -- Studio playtests can't read Creator Hub secrets; add it under File > Experience Settings > Security > Local Secrets, or run this on a live server"
			else ""

		return `Webhook test threw: {posted}{hint} [{status}]`
	end

	if not posted then
		return `Webhook test failed: {message} [{status}]`
	end

	return `Webhook test posted ({message}) -- look for the blue TEST embed in the channel. [{status}]`
end
