-- Step 12: Pick the loaded BBQ back up. The stand only offers to hand it over with nothing in the
-- player's hands -- holding an ingredient keeps its prompt on "add another" instead.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local StickStandController = require(script.Parent.Parent.Parent.Parent.StickStandController)

local NEAR_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("StickStands")

	-- Step 10 held this from the moment the stick went down; this is the beat it was holding out for.
	StickStandController:SetTakeLocked(false)

	local highlight = self:CreateHighlight(slot)

	self:AwaitGoal({
		{
			Description = `Go to your {self:Emphasize("Stick Stand")}`,
			Check = function()
				return self:IsNear(slot, NEAR_DISTANCE)
			end,
		},
		{
			Description = "Put away what you're holding",
			Check = function()
				return EquippedItem.GetTool() == nil
			end,
		},
	}, {
		Description = `Take your {self:Emphasize("BBQ")}`,
		Wait = function()
			while slot:GetAttribute("PlacedStickId") ~= nil do
				slot:GetAttributeChangedSignal("PlacedStickId"):Wait()
			end

			-- Taken here rather than after AwaitGoal returns, which is a frame later: the stand goes back
			-- to offering "Place Stick" on the same frame the take lands, and that frame is long enough to
			-- press it straight back down in.
			--
			-- A stand accepts a loaded BBQ as readily as a bare stick, so from here to the end of the run
			-- it's an open invitation to undo the beat that just finished -- and the walk to the griller
			-- goes right past it. Held for the rest of the run rather than across the next beat alone:
			-- nothing past this point wants the stick stand again. TutorialController:Start hands it back.
			StickStandController:SetPlaceLocked(true)
		end,
	})

	highlight.Destroy()

	self:LogStep("TakeStick")

	self.SequenceFinish:Fire()
end
