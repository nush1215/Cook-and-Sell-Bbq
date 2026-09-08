-- Step 9: get the BBQ onto the griller, which starts it cooking. Ends holding the take off, which step 10 releases.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local GrillerController = require(script.Parent.Parent.Parent.Parent.GrillerController)

-- Matches the grill prompts' MaxActivationDistance, so the beat clears where the prompt comes in reach
local NEAR_DISTANCE = 15
local BEAM_HIDE_DISTANCE = 15

return function(self)
	local slot = self:GetStructure("Grillers")

	-- The prompt's attachment, not the slot -- the model is wide enough that its centre reads as near from out of reach
	local promptAttachment = slot:FindFirstChild("GrillAttachment", true)

	-- Both held up front, since placing is what starts the cook and there's no gap between them to take a lock in. Step 10 hands both back
	GrillerController:SetTakeLocked(true)
	GrillerController:SetStopLocked(true)

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
		-- "Place", matching the prompt's ActionText, so the banner and the button say the same word
		Description = `Place your {self:Emphasize("BBQ")} on the grill`,
		Wait = function()
			while slot:GetAttribute("PlacedStickId") == nil do
				slot:GetAttributeChangedSignal("PlacedStickId"):Wait()
			end
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("PlaceOnGrill")

	self.SequenceFinish:Fire()
end
