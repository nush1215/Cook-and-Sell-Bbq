-- Step 3: Pull the rolling lever. Ends by locking the lever, which stays shut for the rest of the run --
-- see TutorialController:Start, which is what hands it back.
local IngredientRollingController = require(script.Parent.Parent.Parent.Parent.IngredientRollingController)

local NEAR_DISTANCE = 14
local BEAM_HIDE_DISTANCE = 14

return function(self)
	local base = self:GetBase()
	local lever = base.Rolling.Lever
	local leverHandle = lever.Handle
	local stand = base.Rolling.Stands["1"]

	local highlight = self:CreateHighlight(leverHandle)
	local beam = self:CreateBeam(leverHandle, BEAM_HIDE_DISTANCE)

	-- Compared against rather than waited on from nil: a pull the player left unclaimed last session
	-- would already have a roll sitting on the stand, and this beat is about them pulling it now.
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

			-- One pull is all the tutorial wants, and the lever is shut from here to the end of the run. It
			-- re-arms the instant the cycle settles, and a second pull rewrites every pending roll rather
			-- than filling the empty stands -- so during the next beat it would replace the very ingredient
			-- the beam and the glow are pointing at, and past that it's a free invitation off a line the
			-- tutorial has already walked the player down.
			--
			-- Taken here rather than after AwaitGoal returns, which is a frame later: the pull that ends
			-- this beat is the one that arms the next roll, and that frame is long enough to press.
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
