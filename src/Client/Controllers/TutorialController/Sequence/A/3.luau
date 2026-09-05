-- Step 3: pull the rolling lever, which opens for this one pull and is shut again for the rest of the run.
local IngredientRollingController = require(script.Parent.Parent.Parent.Parent.IngredientRollingController)

local NEAR_DISTANCE = 14
local BEAM_HIDE_DISTANCE = 14

return function(self)
	local base = self:GetBase()
	local lever = base.Rolling.Lever
	local leverHandle = lever.Handle
	local stand = base.Rolling.Stands["1"]

	IngredientRollingController:SetRollLocked(false)

	local highlight = self:CreateHighlight(leverHandle)
	local beam = self:CreateBeam(leverHandle, BEAM_HIDE_DISTANCE)

	-- Compared, not waited on from nil -- an unclaimed pull from last session already sits on the stand
	local rolledAt = stand:GetAttribute("RolledAt")

	self:AwaitGoal({
		{
			Description = `Go to your {self:Emphasize("Roller")}`,
			Check = function()
				return self:IsNear(leverHandle, NEAR_DISTANCE)
			end,
		},
	}, {
		Description = `Pull the {self:Emphasize("Lever")}`,
		Wait = function()
			while stand:GetAttribute("RolledAt") == rolledAt do
				stand:GetAttributeChangedSignal("RolledAt"):Wait()
			end

			-- Shut here rather than after AwaitGoal: the lever re-arms as the cycle settles, and a second pull would rewrite the roll the next beat points at
			self.LeverLock = self:DisablePrompts({
				leverHandle:FindFirstChildWhichIsA("ProximityPrompt"),
			}, function()
				IngredientRollingController:RefreshInteractions()
			end, { lever })
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("Roll")

	self.SequenceFinish:Fire()
end
