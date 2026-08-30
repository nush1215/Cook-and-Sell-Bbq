-- Step 12: Take the cooked BBQ off the griller.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)

local NEAR_DISTANCE = 12
local BEAM_HIDE_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("Grillers")

	-- The grill's own attachment rather than the slot: the take prompt rides on the skewer, which is
	-- seated inches from it, and the model is wide enough that its centre reads as near from places
	-- nothing on it is in reach. The knob beats measure from the knob for the same reason -- each beat's
	-- "near" is wherever the thing it's asking for can be reached from. Found the whole way down, since it
	-- sits on Grill.Main.Base rather than on the griller itself.
	local promptAttachment = slot:FindFirstChild("GrillAttachment", true)

	local highlight = self:CreateHighlight(slot)

	-- The skewer rather than the griller: it's what the banner is naming, and the take prompt rides on it.
	-- The server rebuilds it on every record write -- the raw -> cooked swap this beat opens on is one --
	-- so it's resolved each frame, falling back to the prompt's own attachment inches away while it's
	-- between builds.
	local beam = self:CreateBeam(function()
		return slot:FindFirstChild("Skewer") or promptAttachment
	end, BEAM_HIDE_DISTANCE)

	self:AwaitGoal({
		{
			Description = `Go to your {self:Emphasize("Griller")}`,
			Check = function()
				return self:IsNear(promptAttachment, NEAR_DISTANCE)
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
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("TakeFromGrill")

	self.SequenceFinish:Fire()
end
