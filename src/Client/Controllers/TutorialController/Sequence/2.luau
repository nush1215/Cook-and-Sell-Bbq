-- Step 2: Buy what the roll landed on.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ingredients = require(ReplicatedStorage.Shared.Config.Ingredients)
local Rolling = require(ReplicatedStorage.Shared.Config.Rolling)

local BEAM_HIDE_DISTANCE = 10

return function(self)
	local base = self:GetBase()
	local standsFolder = base.Rolling.Stands
	local stand = standsFolder["1"]

	-- The result is only buyable once the cycle has had time to play out -- the same window the server
	-- gates the claim on -- so until then there's nothing to point at yet. How long that is comes off
	-- the stand alongside the stamp, since it's a level rather than a constant now.
	local function hasSettled(): boolean
		local rolledAt = stand:GetAttribute("RolledAt")
		local duration = Rolling.GetRollDuration(stand:GetAttribute("RollSpeedLevel"))
		return rolledAt ~= nil and (workspace:GetServerTimeNow() - rolledAt) >= duration
	end

	-- The rolled model is parented alongside the stands rather than under one, and is named for the
	-- ingredient it is. Resolved per frame rather than held, and only once the landing has settled: the
	-- cycle spawns and destroys one of these per step on its way there, and marking each of those as the
	-- goal would have the glow strobing through a dozen ingredients that were never the answer.
	local function settledIngredient(): Instance?
		local rolled = stand:GetAttribute("RolledIngredient")
		if not rolled or not hasSettled() then
			return nil
		end

		return standsFolder:FindFirstChild(rolled)
	end

	-- No walk-back-to-the-roller beat: the pull is in the air and there is nothing to do about it, so the
	-- player is left to wander while it lands rather than being told to stand and watch. Both cues hang
	-- off the settled result rather than the stand, so nothing is drawn until there is something worth
	-- coming back for -- a line pointing at a stand mid-cycle is telling the player to go somewhere they
	-- can't do anything yet.
	--
	-- The breathing highlight rather than the tutorial's own: what lands on the stand is a thing to walk
	-- up and buy, and every other buyable thing in the game says so by breathing.
	local highlight = self:CreateBreathingHighlight(settledIngredient)
	local beam = self:CreateBeam(settledIngredient, BEAM_HIDE_DISTANCE)

	self:AwaitGoal(nil, {
		-- Both checks, not just the settle: the attribute clears on the purchase a beat before the goal
		-- thread wakes to end the step, and this runs in between.
		Description = function()
			local ingredient = Ingredients.GetIngredientFromId(stand:GetAttribute("RolledIngredient"))
			if not ingredient or not hasSettled() then
				return "Wait for it..."
			end

			return `Buy the {self:Emphasize(ingredient.Name, ingredient.Color)}`
		end,
		-- The pending roll is cleared the moment it's claimed, so the stand emptying is the purchase.
		Wait = function()
			while stand:GetAttribute("RolledIngredient") ~= nil do
				stand:GetAttributeChangedSignal("RolledIngredient"):Wait()
			end
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("BuyIngredient")

	self.SequenceFinish:Fire()
end
