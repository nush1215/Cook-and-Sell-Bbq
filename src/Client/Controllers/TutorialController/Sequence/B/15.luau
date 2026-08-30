-- Step 15: Take the Store teleport. The stick shop isn't on the player's base -- it's in the shared
-- store -- and the top bar's Store button is how you get there. The spotlight teaches the button;
-- arriving is what ends the beat, so walking there counts the same as pressing it.
--
-- Last in this variant rather than fifth, and the sale two beats ago is what pays for it: selling a BBQ
-- destroys the stick under it, so the player really is at zero here. The trip is them restocking after
-- a loop they've now done once, instead of an errand run before they've seen one pay out.
--
-- Looked up per check rather than held, for the same reason the trip home uses a zone: a reference
-- taken on one side of a teleport is worth nothing on the other if the thing it points at has been
-- out of the world in between.
-- Controllers
local HudController = require(script.Parent.Parent.Parent.Parent.HudController)

-- The bar the Store button sits on, held down for the rest of the run by Start.
local TOP_BAR_FRAME = "Top"

local ARRIVED_DISTANCE = 60

return function(self)
	local teleports = workspace:WaitForChild("Core"):WaitForChild("Teleports")

	-- This is the beat that wants it, so it comes back for exactly as long as the beat lasts.
	HudController:SetHudFrameHiddenFor(self, TOP_BAR_FRAME, false)

	local spotlight = self:SpotlightHudButton("Store")

	self:AwaitGoal(nil, {
		Description = `You're out of {self:Emphasize("Sticks")}! Click the {self:Emphasize("Store")} button`,
		Wait = function()
			local function atStore(): boolean
				local store = teleports:FindFirstChild("Store")
				return store ~= nil and self:IsNear(store, ARRIVED_DISTANCE)
			end

			while not atStore() do
				task.wait()
			end
		end,
	})

	spotlight.Destroy()
	HudController:SetHudFrameHiddenFor(self, TOP_BAR_FRAME, true)

	self:LogStep("OpenStore")

	self.SequenceFinish:Fire()
end
