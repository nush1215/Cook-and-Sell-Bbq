-- Step 10: Pick the loaded BBQ back up. The stand only offers to hand it over with nothing in the
-- player's hands -- holding an ingredient keeps its prompt on "add another" instead.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Modules.EquippedItem)

local NEAR_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("StickStands")

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
		end,
	})

	highlight.Destroy()

	self:LogStep("TakeStick")

	self.SequenceFinish:Fire()
end
