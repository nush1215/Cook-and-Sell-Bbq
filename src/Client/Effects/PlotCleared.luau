-- Controllers
local Controllers = script.Parent.Parent.Controllers
local PlotController = require(Controllers.PlotController)

--
-- A just-bought plot's overgrowth burning back: neon, hold, fade, leaving the ground clear.
return function(plotModel: Model)
	PlotController:PlayClearBurn(plotModel)
end
