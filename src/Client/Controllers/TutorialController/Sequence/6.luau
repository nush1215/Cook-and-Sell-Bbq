-- Step 6: Take the Base teleport home, where everything else happens.
--
-- Ends on the player standing on their base's PlayerSpawn -- the very part the Base button drops them
-- onto -- rather than on a reference held across the trip. Holding one was the obvious approach and it
-- was the wrong one: the base streams out while the player is over at the store and comes back as a
-- brand-new model, so anything looked up beforehand is dead by the time they are stood on it and the
-- beat never ends no matter where they go or what they press. Re-resolving per check, the way step 3
-- re-looks-up the Store pad, is what makes it survive the round trip.
local ARRIVED_DISTANCE = 30

return function(self)
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

	self:LogStep("ReturnToBase")

	self.SequenceFinish:Fire()
end
