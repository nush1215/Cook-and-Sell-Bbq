-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local TutorialCrateManager = require(Managers.TutorialCrateManager)

-- The tutorial's own drop, crash and all, optionally spawned already past its open time.
return function(context, showTimer: boolean, player: Player?)
	local target = player or context.Executor

	-- Cleared first, so a repeat run replaces the crate rather than hitting SpawnFor's one-at-a-time guard
	TutorialCrateManager:RemoveFor(target)

	if not TutorialCrateManager:SpawnFor(target, showTimer) then
		return `Couldn't spawn a tutorial crate for {target.Name} -- their base is missing its meteor spawn part.`
	end

	return `Spawned the tutorial crate for {target.Name}{if showTimer then " with its countdown" else ", ready to open"}.`
end
