-- Step 10: put the stick on the stand, where a BBQ gets built. Ends holding the take off, which step 12 releases.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local StickStandController = require(script.Parent.Parent.Parent.Parent.StickStandController)

local NEAR_DISTANCE = 12
local BEAM_HIDE_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("StickStands")

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

			-- Taken here, not a frame later: the prompt turns to "Take Stick" on the same frame, and the load beat's only prompt in reach would hand it straight back
			StickStandController:SetTakeLocked(true)
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("PlaceStick")

	self.SequenceFinish:Fire()
end
