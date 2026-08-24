-- Step 12: Light the stove. Ends by locking the stop prompts, which step 13 holds until the BBQ is
-- actually cooked -- see there for why.
local GrillerController = require(script.Parent.Parent.Parent.GrillerController)

local NEAR_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("Grillers")
	local knob = slot.Knob.Handle

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

			-- Taken here rather than after AwaitGoal returns, which is a frame later: the stop prompt goes
			-- live the instant the cook starts, and that frame is long enough to press it in.
			--
			-- The knob's glow goes with its prompt. It breathes for the whole cook, since the knob is what
			-- stops one, and left alone it would be lit through the raw band for something the player is
			-- being held back from doing.
			-- Every prompt on the attachment rather than the first one found: the body carries the Robux
			-- skip through a cook as well as the place, and a beat teaching the timing shouldn't be
			-- offering to sell its way out of the thing it's teaching.
			local prompts = { knob:FindFirstChildWhichIsA("ProximityPrompt") }
			for _, child in slot:FindFirstChild("GrillAttachment", true):GetChildren() do
				if child:IsA("ProximityPrompt") then
					table.insert(prompts, child)
				end
			end

			self.CookPromptLock = self:DisablePrompts(prompts, function()
				GrillerController:RefreshInteractions()
			end, { slot.Knob })

			-- Step 11 held this from the moment the BBQ went down; the cook is what it was holding out for.
			-- Nothing visible changes here -- a cooking grill offers no take of its own -- it just means the
			-- hold ends with the beat that wanted it rather than outliving the tutorial.
			GrillerController:SetTakeLocked(false)
		end,
	})

	highlight.Destroy()

	self:LogStep("StartCook")

	self.SequenceFinish:Fire()
end
