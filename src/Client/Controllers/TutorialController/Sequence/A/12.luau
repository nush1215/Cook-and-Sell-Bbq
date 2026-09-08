-- Step 12: pick the loaded BBQ back up, which the stand only offers with empty hands.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local StickStandController = require(script.Parent.Parent.Parent.Parent.StickStandController)

local NEAR_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("StickStands")

	-- Step 10 held this from the moment the stick went down; this is the beat it was holding out for
	StickStandController:SetTakeLocked(false)

	local highlight = self:CreateHighlight(slot)

	self:AwaitGoal({
		{
			Description = `Go to your {self:Emphasize("Stick Stand")}`,
			Check = function()
				return self:IsNear(slot, NEAR_DISTANCE)
			end,
		},
		{
			Description = "Put away what you're holding",
			Check = function()
				return EquippedItem.GetTool() == nil
			end,
		},
	}, {
		Description = `Take your {self:Emphasize("BBQ")}`,
		Wait = function()
			while slot:GetAttribute("PlacedStickId") ~= nil do
				slot:GetAttributeChangedSignal("PlacedStickId"):Wait()
			end

			-- Taken here, not a frame later: the stand offers "Place Stick" again immediately, and the walk to the griller goes right past it. Held for the rest of the run
			StickStandController:SetPlaceLocked(true)
		end,
	})

	highlight.Destroy()

	self:LogStep("TakeStick")

	self.SequenceFinish:Fire()
end
