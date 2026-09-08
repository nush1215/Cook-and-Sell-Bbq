-- Step 4: Buy what the roll landed on.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ingredients = require(ReplicatedStorage.Shared.Config.Ingredients)
local Rolling = require(ReplicatedStorage.Shared.Config.Rolling)

local BEAM_HIDE_DISTANCE = 10

return function(self)
	local base = self:GetBase()
	local standsFolder = base.Rolling.Stands
	local stand = standsFolder["1"]

	-- Buyable only once the cycle has played out -- the same window the claim is gated on, read off the stand
	local function hasSettled(): boolean
		local rolledAt = stand:GetAttribute("RolledAt")
		local duration = Rolling.GetRollDuration(stand:GetAttribute("RollSpeedLevel"))
		return rolledAt ~= nil and (workspace:GetServerTimeNow() - rolledAt) >= duration
	end

	-- Resolved per frame and only once settled, or the glow would strobe through the cycle's discards
	local function settledIngredient(): Instance?
		local rolled = stand:GetAttribute("RolledIngredient")
		if not rolled or not hasSettled() then
			return nil
		end

		return standsFolder:FindFirstChild(rolled)
	end

	-- Both cues hang off the settled result, so nothing points at a stand there's nothing to do at yet
	local highlight = self:CreateBreathingHighlight(settledIngredient)
	local beam = self:CreateBeam(settledIngredient, BEAM_HIDE_DISTANCE)

	self:AwaitGoal(nil, {
		-- Both checks -- the attribute clears a beat before the goal thread wakes, and this runs in between
		Description = function()
			local ingredient = Ingredients.GetIngredientFromId(stand:GetAttribute("RolledIngredient"))
			if not ingredient or not hasSettled() then
				return "Wait for it..."
			end

			return `Buy the {self:Emphasize(ingredient.Name, ingredient.Color)}`
		end,
		-- The pending roll is cleared the moment it's claimed, so the stand emptying is the purchase
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
