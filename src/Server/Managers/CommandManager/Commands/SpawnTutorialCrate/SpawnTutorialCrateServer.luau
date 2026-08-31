-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local TutorialCrateManager = require(Managers.TutorialCrateManager)

-- The same drop finishing the tutorial gets, crash and all -- only with the option of skipping the
-- countdown. Nothing hides the timer: with ShowTimer off the crate spawns already past its open time,
-- so the client's countdown goes straight to the Open prompt.
return function(context, showTimer: boolean, player: Player?)
	local target = player or context.Executor

	-- Cleared first so a repeat run replaces the crate rather than being turned away by the
	-- one-at-a-time guard in SpawnFor
	TutorialCrateManager:RemoveFor(target)

	if not TutorialCrateManager:SpawnFor(target, showTimer) then
		return `Couldn't spawn a tutorial crate for {target.Name} -- their base is missing its meteor spawn part.`
	end

	return `Spawned the tutorial crate for {target.Name}{if showTimer then " with its countdown" else ", ready to open"}.`
end
