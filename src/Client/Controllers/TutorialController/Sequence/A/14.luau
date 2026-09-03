-- Step 14: Light the stove. Takes GrillerController's stop lock, which step 15 holds until the BBQ is
-- actually cooked -- see there for why.
local GrillerController = require(script.Parent.Parent.Parent.Parent.GrillerController)

local NEAR_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("Grillers")
	local knob = slot.Knob.Handle

	-- Taken before the cook exists at all, not on the Cooking attribute: the grill's own attribute
	-- handlers connect before any waiter this step could put on it, so their refresh runs first and a
	-- lock taken on that signal is already one "Stop Cooking" flash too late. Harmless this early --
	-- it only gates the stop, and nothing is cooking yet. The knob's glow goes down with its prompt.
	GrillerController:SetStopLocked(true)

	local highlight = self:CreateHighlight(knob)

	self:AwaitGoal({
		{
			Description = `Go to your {self:Emphasize("Griller")}`,
			-- The knob, not the griller: this beat is asking for the knob's own prompt, so what counts as
			-- near is wherever that prompt is in reach from.
			Check = function()
				return self:IsNear(knob, NEAR_DISTANCE)
			end,
		},
	}, {
		Description = `Turn the {self:Emphasize("Knob")} to start cooking`,
		Wait = function()
			while slot:GetAttribute("Cooking") ~= true do
				slot:GetAttributeChangedSignal("Cooking"):Wait()
			end

			-- Step 13 held this from the moment the BBQ went down; the cook is what it was holding out for.
			-- Nothing visible changes here -- a cooking grill offers no take of its own -- it just means the
			-- hold ends with the beat that wanted it rather than outliving the tutorial.
			GrillerController:SetTakeLocked(false)
		end,
	})

	highlight.Destroy()

	self:LogStep("StartCook")

	self.SequenceFinish:Fire()
end
