-- Step 8: Pick the loaded BBQ back up. The stand only offers to hand it over with nothing in the
-- player's hands -- holding an ingredient keeps its prompt on "add another" instead.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local StickStandController = require(script.Parent.Parent.Parent.Parent.StickStandController)

local NEAR_DISTANCE = 12
local BEAM_HIDE_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("StickStands")

	-- Step 4 held this from the moment the stick went down; this is the beat it was holding out for.
	StickStandController:SetTakeLocked(false)

	-- The stand renders its stick client side and rebuilds it from scratch on every change, so the BBQ
	-- is resolved each frame rather than held -- anything holding one is holding a destroyed model.
	local function stickModel(): Model?
		return StickStandController:GetPlacedStickModel(slot)
	end

	-- The BBQ itself, not the stand holding it: this beat asks for one specific thing off a stand the
	-- player has already been sent to twice, and lighting the whole stand again says "press the stand"
	-- just as readily. They're separate models -- the stick is seated beside the stand, not inside it --
	-- so this is a glow the stand's own never reached.
	local highlight = self:CreateHighlight(stickModel)

	-- Aimed at the BBQ, falling back to the stand holding it. One beam covers both halves of the beat --
	-- walking over and knowing what to take -- since the two sit a stud apart and a second would only draw
	-- the same line twice; the fallback keeps it pointing somewhere while the stand is between renders.
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

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("TakeStick")

	self.SequenceFinish:Fire()
end
