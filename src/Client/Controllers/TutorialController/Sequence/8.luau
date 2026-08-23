-- Step 8: Put the stick down on the stick stand, which is where a BBQ gets built.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Modules.EquippedItem)

local NEAR_DISTANCE = 12
local BEAM_HIDE_DISTANCE = 12

return function(self)
	local base = self:GetBase()
	local slot = base.Interactables.StickStand["1"]

	local highlight = self:CreateHighlight(slot)
	local beam = self:CreateBeam(slot.Stand, BEAM_HIDE_DISTANCE)

	self:AwaitGoal({
		{
			Description = `Go to your {self:Emphasize("Stick Stand")}`,
			Check = function()
				return self:IsNear(slot, NEAR_DISTANCE)
			end,
		},
		{
			Description = `Equip your {self:Emphasize("Stick")}`,
			Check = function()
				return EquippedItem.GetStickId() ~= nil
			end,
		},
	}, {
		Description = `Place your {self:Emphasize("Stick")} on the stand`,
		Wait = function()
			while slot:GetAttribute("PlacedStickId") == nil do
				slot:GetAttributeChangedSignal("PlacedStickId"):Wait()
			end
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("PlaceStick")

	self.SequenceFinish:Fire()
end
