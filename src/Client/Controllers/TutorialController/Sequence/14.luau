-- Step 14: Take the cooked BBQ off the griller.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Modules.EquippedItem)

local NEAR_DISTANCE = 12

return function(self)
	local base = self:GetBase()
	local slot = base.Interactables.Grillers["1"]

	-- The grill prompt's attachment rather than the slot: it marks where the player has to stand to place
	-- or take, and the model is wide enough that its centre reads as near from places nothing on it is in
	-- reach. The knob beats measure from the knob for the same reason -- each beat's "near" is wherever
	-- the thing it's asking for can be reached from.
	local promptAttachment = slot.GrillPromptAttachment

	local highlight = self:CreateHighlight(slot)

	self:AwaitGoal({
		{
			Description = `Go to your {self:Emphasize("Griller")}`,
			Check = function()
				return self:IsNear(promptAttachment, NEAR_DISTANCE)
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

	self:LogStep("TakeFromGrill")

	self.SequenceFinish:Fire()
end
