local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

return function(registry)
	registry:RegisterHook("BeforeRun", function(context)
		local userId = context.Executor.UserId
		local player = Players:GetPlayerByUserId(userId)

		local playerRank = player:GetRankInGroupAsync(984015744)
		if playerRank < 254 then
			return "You are not allowed to run this command sonion"
		end

		return nil
	end)
end
