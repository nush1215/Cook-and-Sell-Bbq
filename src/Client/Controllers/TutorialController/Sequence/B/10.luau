-- Step 10: Light the stove. Ends by locking the stop prompts, which step 15 holds until the BBQ is
-- actually cooked -- see there for why.
local GrillerController = require(script.Parent.Parent.Parent.Parent.GrillerController)

local NEAR_DISTANCE = 12
local BEAM_HIDE_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("Grillers")
	local knob = slot.Knob.Handle

	local highlight = self:CreateHighlight(knob)

	-- The knob rather than the griller, matching what this beat counts as near: the griller is wide
	-- enough that a beam into its middle lands nowhere near the thing being asked for.
	local beam = self:CreateBeam(knob, BEAM_HIDE_DISTANCE)

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

			-- Taken here rather than after AwaitGoal returns, which is a frame later: the stop prompt goes
			-- live the instant the cook starts, and that frame is long enough to press it in.
			--
			-- The knob's glow goes with its prompt. It breathes for the whole cook, since the knob is what
			-- stops one, and left alone it would be lit through the raw band for something the player is
			-- being held back from doing.
			local prompts = {
				knob:FindFirstChildWhichIsA("ProximityPrompt"),
				slot:FindFirstChild("GrillAttachment", true):FindFirstChildWhichIsA("ProximityPrompt"),
			}

			-- The Robux skip isn't among them, and isn't this beat's to take: it's held for the whole run
			-- from TutorialController:Start. It used to be taken here and released on the same lock as
			-- these prompts, which handed it back at the raw band -- putting it on the bar for the tail of
			-- the very cook it was hidden through, still offering to sell the player out of the thing they
			-- were being taught.
			self.CookPromptLock = self:DisablePrompts(prompts, function()
				GrillerController:RefreshInteractions()
			end, { slot.Knob })

			-- Step 9 held this from the moment the BBQ went down; the cook is what it was holding out for.
			-- Nothing visible changes here -- a cooking grill offers no take of its own -- it just means the
			-- hold ends with the beat that wanted it rather than outliving the tutorial.
			GrillerController:SetTakeLocked(false)
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("StartCook")

	self.SequenceFinish:Fire()
end
