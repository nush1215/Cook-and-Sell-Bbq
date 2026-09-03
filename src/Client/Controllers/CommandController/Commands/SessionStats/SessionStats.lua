-- Controllers
local Controllers = script.Parent.Parent.Parent.Parent
local DebugSessionStatsController = require(Controllers.DebugSessionStatsController)

return {
	Name = "sessionStats",
	Aliases = { "ss" },
	Description = "Toggles the session stats panel: time played, rolls, and what's been bought this session",
	Args = {},

	Run = function()
		if DebugSessionStatsController:Toggle() then
			return "Session stats shown"
		end

		return "Session stats hidden"
	end,
}
