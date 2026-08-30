-- Step 3: Hold the stick. In A this beat follows the purchase that put the stick in the player's hands,
-- so it's a formality. Here the stick was handed over at the start of the run and left in the bag, and
-- the player has spent the last two beats holding build tools -- so this is the first they hear of it,
-- and the one beat in the run asking for something they don't know they own.
local Players = game:GetService("Players")

-- Modules
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)

--
local LocalPlayer = Players.LocalPlayer

-- What StickManager tags the tool it builds off the player's owned count.
local STICK_TOOL_TAG = "StickTool"

return function(self)
	-- The bag only, and re-resolved each frame rather than held: equipping moves the tool out of the
	-- Backpack, so this going nil is what puts the light out, and the reconcile rebuilds it as a new
	-- instance on every spawn.
	local function backpackStick(): Tool?
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if not backpack then
			return nil
		end

		for _, child in backpack:GetChildren() do
			if child:IsA("Tool") and child:HasTag(STICK_TOOL_TAG) then
				return child
			end
		end

		return nil
	end

	-- A's version of this beat has no cues at all, which it can afford because the stick arrives in the
	-- player's hands already. Nothing here would otherwise point at the slot it actually landed in.
	local spotlight = self:SpotlightHotbarSlot(backpackStick)

	self:AwaitGoal(nil, {
		Description = `Equip the free {self:Emphasize("Stick")} we gave you`,
		Wait = function()
			while EquippedItem.GetStickId() == nil do
				task.wait()
			end
		end,
	})

	spotlight.Destroy()

	self:LogStep("EquipStick")

	self.SequenceFinish:Fire()
end
