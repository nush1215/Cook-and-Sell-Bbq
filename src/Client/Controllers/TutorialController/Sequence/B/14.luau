-- Step 14: Walk into the stick shop, which opens its own UI on entry.
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

local BEAM_HIDE_DISTANCE = 14

return function(self)
	local zone = workspace:WaitForChild("Core"):WaitForChild("Zones"):WaitForChild("StickShop")
	local stall = workspace:WaitForChild("Stalls"):WaitForChild("StickStall")
	local holder = PlayerGui:WaitForChild("StickShopUI").Holder

	-- The glow marks the stall a player scans for; the beam stays on the zone, which is what opens the shop
	local highlight = self:CreateBreathingHighlight(stall)
	local beam = self:CreateBeam(zone, BEAM_HIDE_DISTANCE)

	self:AwaitGoal(nil, {
		Description = `Go to the {self:Emphasize("Stick Shop")}`,
		Wait = function()
			while not holder.Visible do
				holder:GetPropertyChangedSignal("Visible"):Wait()
			end
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("OpenStickShop")

	self.SequenceFinish:Fire()
end
