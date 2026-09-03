-- Step 7: Load the stick with the ingredient. The stand's prompt turns into "Add <Ingredient>" while
-- one is held, so equipping it and pressing the prompt reads as the one action it is.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local Ingredients = require(ReplicatedStorage.Shared.Config.Ingredients)

-- What the tutorial's roll is pinned to, so this beat can name the thing to equip rather than asking for
-- "your Ingredient" while exactly one sits in the player's inventory. The server owns the pin --
-- TutorialManager's TUTORIAL_INGREDIENT_ID -- and this is the client's copy of it, the same way step 15
-- keeps the id of the stick it points at.
local TUTORIAL_INGREDIENT_ID = "Garlic"

local NEAR_DISTANCE = 12
local BEAM_HIDE_DISTANCE = 12

return function(self)
	-- Named in the ingredient's own label colour, which is what tells ingredients apart in the stick UI.
	local pinnedIngredient = Ingredients.GetIngredientFromId(TUTORIAL_INGREDIENT_ID)
	local ingredientName = self:Emphasize(pinnedIngredient.Name, pinnedIngredient.Color)

	local slot = self:GetStructure("StickStands")

	local highlight = self:CreateHighlight(slot)

	-- A has no beam on this beat because it follows straight on from putting the stick down, with the
	-- player still standing at the stand. Here the roll sends them across the base and back, so this is a
	-- return trip rather than a follow-on, and it gets pointed at the same way the first visit was.
	local beam = self:CreateBeam(slot.Stand, BEAM_HIDE_DISTANCE)

	self:AwaitGoal({
		{
			Description = `Go to your {self:Emphasize("Stick Stand")}`,
			Check = function()
				return self:IsNear(slot, NEAR_DISTANCE)
			end,
		},
		{
			Description = `Equip {ingredientName}`,
			Check = function()
				return EquippedItem.GetIngredientId() ~= nil
			end,
		},
	}, {
		-- Named live, and falling back to the plain word: the ingredient leaves their hands the instant
		-- it goes on the stick, a beat before the goal thread wakes to end the step.
		Description = function()
			local ingredient = Ingredients.GetIngredientFromId(EquippedItem.GetIngredientId())
			local name = if ingredient
				then self:Emphasize(ingredient.Name, ingredient.Color)
				else self:Emphasize("Ingredient")

			return `Put the {name} on your stick`
		end,
		Wait = function()
			-- A comma-separated list of what's on the stick, so anything at all in it is one added.
			while (slot:GetAttribute("PlacedIngredients") or "") == "" do
				slot:GetAttributeChangedSignal("PlacedIngredients"):Wait()
			end
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("AddIngredient")

	self.SequenceFinish:Fire()
end
