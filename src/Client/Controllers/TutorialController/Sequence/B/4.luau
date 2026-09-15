-- Step 4: put the stick on the stand, where a BBQ gets built. Ends holding the take off, which step 8 releases.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local StickStandController = require(script.Parent.Parent.Parent.Parent.StickStandController)

-- What StickManager tags the tool it builds off the player's owned count
local STICK_TOOL_TAG = "StickTool"

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
				self:EquipForGamepad(self:GetBackpackTool(STICK_TOOL_TAG))
				return EquippedItem.GetStickId() ~= nil
			end,
		},
	}, {
		Description = `Place your {self:Emphasize("Stick")} on the stand`,
		Wait = function()
			while slot:GetAttribute("PlacedStickId") == nil do
				slot:GetAttributeChangedSignal("PlacedStickId"):Wait()
			end

			-- Taken here, not a frame later: the prompt turns to "Take Stick" immediately, and the next three beats all leave it the only prompt in reach
			StickStandController:SetTakeLocked(true)
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("PlaceStick")

	self.SequenceFinish:Fire()
end
