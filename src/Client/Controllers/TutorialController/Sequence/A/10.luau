-- Step 10: Put the stick down on the stick stand, which is where a BBQ gets built. Ends by holding the
-- take off, which step 12 releases once it's the beat asking for the stick back -- see there.
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

			-- Taken here rather than after AwaitGoal returns, which is a frame later: the stand's prompt
			-- turns into "Take Stick" on the same frame the place lands, and that frame is long enough to
			-- press it back off in.
			--
			-- The load beat that follows reads the stand as holding a stick, and the one prompt in reach
			-- through it offers to hand that stick back. Taking it would drop the player behind a beat the
			-- tutorial has already passed, with no way to say so.
			StickStandController:SetTakeLocked(true)
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("PlaceStick")

	self.SequenceFinish:Fire()
end
