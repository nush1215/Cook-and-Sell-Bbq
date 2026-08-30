-- Step 18: Take the Base teleport home, where everything else happens.
--
-- Ends on the player standing on their base's PlayerSpawn -- the very part the Base button drops them
-- onto -- rather than on a reference held across the trip. Holding one was the obvious approach and it
-- was the wrong one: the base streams out while the player is over at the store and comes back as a
-- brand-new model, so anything looked up beforehand is dead by the time they are stood on it and the
-- beat never ends no matter where they go or what they press. Re-resolving per check, the way step 15
-- re-looks-up the Store pad, is what makes it survive the round trip.
-- Controllers
local HudController = require(script.Parent.Parent.Parent.Parent.HudController)

-- The bar the Base button sits on, held down for the rest of the run by Start.
local TOP_BAR_FRAME = "Top"

local ARRIVED_DISTANCE = 30

return function(self)
	-- This is the beat that wants it, so it comes back for exactly as long as the beat lasts.
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
