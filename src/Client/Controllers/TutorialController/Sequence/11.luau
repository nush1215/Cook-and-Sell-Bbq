-- Step 11: Get the BBQ onto the griller. Ends by holding the take off, which step 12 releases once the
-- stove is lit -- see there.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local GrillerController = require(script.Parent.Parent.Parent.GrillerController)

local NEAR_DISTANCE = 12
local BEAM_HIDE_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("Grillers")

	-- The place prompt's attachment rather than the slot: it marks where the player has to stand to place,
	-- and the model is wide enough that its centre reads as near from places nothing on it is in reach.
	-- The knob beats measure from the knob for the same reason -- each beat's "near" is wherever the thing
	-- it's asking for can be reached from. Found the whole way down, since it sits on GrillModel's
	-- Base part rather than on the griller itself.
	local promptAttachment = slot:FindFirstChild("GrillAttachment", true)

	local highlight = self:CreateHighlight(slot)
	local beam = self:CreateBeam(promptAttachment, BEAM_HIDE_DISTANCE)

	self:AwaitGoal({
		{
			Description = `Go to your {self:Emphasize("Griller")}`,
			Check = function()
				return self:IsNear(promptAttachment, NEAR_DISTANCE)
			end,
		},
		{
			Description = `Equip your {self:Emphasize("BBQ")}`,
			Check = function()
				return EquippedItem.GetSkewer() ~= nil
			end,
		},
	}, {
		-- "Place", matching the prompt's own ActionText, so the banner and the thing they press say the
		-- same word.
		Description = `Place your {self:Emphasize("BBQ")} on the grill`,
		Wait = function()
			while slot:GetAttribute("PlacedStickId") == nil do
				slot:GetAttributeChangedSignal("PlacedStickId"):Wait()
			end

			-- Taken here rather than after AwaitGoal returns, which is a frame later: the take goes live on
			-- the same frame the place lands, and that frame is long enough to press it back off in.
			--
			-- Nothing about the next beat wants the BBQ coming back off. The griller is holding it, the
			-- banner is asking for the knob, and a prompt sat on top of it offering to undo the step they
			-- just finished is the only other thing in reach -- and taking it would drop them back to a
			-- beat the tutorial has already passed, with no way to say so.
			GrillerController:SetTakeLocked(true)
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("PlaceOnGrill")

	self.SequenceFinish:Fire()
end
