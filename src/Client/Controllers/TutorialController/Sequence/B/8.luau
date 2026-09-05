-- Step 8: pick the loaded BBQ back up, which the stand only offers with empty hands.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local StickStandController = require(script.Parent.Parent.Parent.Parent.StickStandController)

local NEAR_DISTANCE = 12
local BEAM_HIDE_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("StickStands")

	-- Step 4 held this from the moment the stick went down; this is the beat it was holding out for
	StickStandController:SetTakeLocked(false)

	-- Resolved each frame, the stand rebuilding its stick on every change -- a held one is destroyed
	local function stickModel(): Model?
		return StickStandController:GetPlacedStickModel(slot)
	end

	-- The BBQ, not the stand -- they're separate models, and lighting the stand again says "press the stand"
	local highlight = self:CreateHighlight(stickModel)

	-- Aimed at the BBQ with the stand as fallback; a stud apart, so a second beam would draw the same line
	local beam = self:CreateBeam(function()
		return stickModel() or slot.Stand
	end, BEAM_HIDE_DISTANCE)

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

			-- Taken here, not a frame later: the stand offers "Place Stick" again immediately, and the walk to the griller goes right past it. Held for the rest of the run
			StickStandController:SetPlaceLocked(true)
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("TakeStick")

	self.SequenceFinish:Fire()
end
