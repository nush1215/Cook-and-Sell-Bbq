-- Step 3: Take the Store teleport. The stick shop isn't on the player's base -- it's in the shared
-- store -- and the top bar's Store button is how you get there. The spotlight teaches the button;
-- arriving is what ends the beat, so walking there counts the same as pressing it.
--
-- Looked up per check rather than held, for the same reason the trip home uses a zone: a reference
-- taken on one side of a teleport is worth nothing on the other if the thing it points at has been
-- out of the world in between.
local ARRIVED_DISTANCE = 60

return function(self)
	local teleports = workspace:WaitForChild("Core"):WaitForChild("Teleports")

	local spotlight = self:SpotlightHudButton("Store")

	self:AwaitGoal(nil, {
		Description = `Click the {self:Emphasize("Store")} button`,
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

	self:LogStep("OpenStore")

	self.SequenceFinish:Fire()
end
