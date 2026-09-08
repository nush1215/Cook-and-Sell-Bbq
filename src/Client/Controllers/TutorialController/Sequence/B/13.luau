-- Step 13: take the Store teleport. Last rather than fifth -- the sale two beats ago destroyed the stick, so this is restocking after a loop they've done once. Looked up per check, since a reference taken before a teleport is worth nothing after it.
local HudController = require(script.Parent.Parent.Parent.Parent.HudController)

-- The bar the Store button sits on, held down for the rest of the run by Start
local TOP_BAR_FRAME = "Top"

local ARRIVED_DISTANCE = 60

return function(self)
	local teleports = workspace:WaitForChild("Core"):WaitForChild("Teleports")

	-- This is the beat that wants it, so it comes back for exactly as long as the beat lasts
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
