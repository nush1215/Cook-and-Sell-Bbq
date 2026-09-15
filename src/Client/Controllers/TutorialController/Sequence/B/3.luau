-- Step 3: hold the stick. Unlike A, it was handed over at the start and left in the bag, so this is the first the player hears of it.
-- Modules
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)

-- What StickManager tags the tool it builds off the player's owned count
local STICK_TOOL_TAG = "StickTool"

return function(self)
	-- The bag only, re-resolved each frame: equipping moves it out, and every spawn rebuilds it anew
	local function backpackStick(): Tool?
		return self:GetBackpackTool(STICK_TOOL_TAG)
	end

	-- A can afford no cues, the stick arriving in hand; here nothing else would point at its slot
	local spotlight = self:SpotlightHotbarSlot(backpackStick)

	self:AwaitGoal(nil, {
		Description = `Equip the free {self:Emphasize("Stick")} we gave you`,
		Wait = function()
			while EquippedItem.GetStickId() == nil do
				self:EquipForGamepad(backpackStick())
				task.wait()
			end
		end,
	})

	spotlight.Destroy()

	self:LogStep("EquipStick")

	self.SequenceFinish:Fire()
end
