-- Step 9: hold the stick. A bought one goes straight into their hands, so this usually passes as it opens.
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
