-- Step 9: Hold the stick. A bought stick goes straight into the player's hands, so this usually passes
-- the moment it opens -- it's here for the case where it doesn't.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)

return function(self)
	self:AwaitGoal(nil, {
		Description = `Equip your {self:Emphasize("Stick")}`,
		Wait = function()
			while EquippedItem.GetStickId() == nil do
				task.wait()
			end
		end,
	})

	self:LogStep("EquipStick")

	self.SequenceFinish:Fire()
end
