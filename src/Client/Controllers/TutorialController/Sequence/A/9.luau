-- Step 9: hold the stick. A bought one goes straight into their hands, so this usually passes as it opens.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)

-- What StickManager tags the tool it builds off the player's owned count
local STICK_TOOL_TAG = "StickTool"

return function(self)
	self:AwaitGoal(nil, {
		Description = `Equip your {self:Emphasize("Stick")}`,
		Wait = function()
			while EquippedItem.GetStickId() == nil do
				self:EquipForGamepad(self:GetBackpackTool(STICK_TOOL_TAG))
				task.wait()
			end
		end,
	})

	self:LogStep("EquipStick")

	self.SequenceFinish:Fire()
end
