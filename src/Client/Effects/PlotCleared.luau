-- Controllers
local Controllers = script.Parent.Parent.Controllers
local PlotController = require(Controllers.PlotController)

--
-- The overgrowth on a just-bought plot burning back -- every part of it goes neon, holds, then fades
-- out, leaving the ground clear.
--
-- Fired by the base on the one plot that changed hands, rather than driven off the plot's Unlocked
-- flag like the rest of its render. The flag says which plots *are* cleared, which the client snaps
-- to; only the server knows which one was *just* bought, and on join the two are impossible to tell
-- apart from the client alone.
--
-- @param plotModel The plot that was bought; the class holding its overgrowth is found from it
return function(plotModel: Model)
	PlotController:PlayClearBurn(plotModel)
end
