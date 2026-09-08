-- Step 8: take the Base teleport home. Ends on standing at PlayerSpawn, re-resolved per check -- the base streams out over at the store and returns as a new model, so a held reference is dead.
local HudController = require(script.Parent.Parent.Parent.Parent.HudController)

-- The bar the Base button sits on, held down for the rest of the run by Start
local TOP_BAR_FRAME = "Top"

local ARRIVED_DISTANCE = 30

return function(self)
	-- This is the beat that wants it, so it comes back for exactly as long as the beat lasts
	HudController:SetHudFrameHiddenFor(self, TOP_BAR_FRAME, false)

	local spotlight = self:SpotlightHudButton("Base")

	self:AwaitGoal(nil, {
		Description = `Click the {self:Emphasize("Base")} button to go home`,
		Wait = function()
			local function atBase(): boolean
				local base = self:GetBaseIfPresent()
				local core = base and base:FindFirstChild("Core")
				local spawnPart = core and core:FindFirstChild("PlayerSpawn")

				return spawnPart ~= nil and self:IsNear(spawnPart, ARRIVED_DISTANCE)
			end

			while not atBase() do
				task.wait()
			end
		end,
	})

	spotlight.Destroy()
	HudController:SetHudFrameHiddenFor(self, TOP_BAR_FRAME, true)

	self:LogStep("ReturnToBase")

	self.SequenceFinish:Fire()
end
