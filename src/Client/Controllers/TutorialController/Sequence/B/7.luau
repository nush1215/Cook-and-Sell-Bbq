-- Step 7: load the stick with the ingredient, which the stand's prompt offers while one is held.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local Ingredients = require(ReplicatedStorage.Shared.Config.Ingredients)

-- The client's copy of the server's pinned ingredient, so the beat can name what to equip
local TUTORIAL_INGREDIENT_ID = "Garlic"

local NEAR_DISTANCE = 12
local BEAM_HIDE_DISTANCE = 12

return function(self)
	-- Named in the ingredient's own label colour, which is what tells them apart in the stick UI
	local pinnedIngredient = Ingredients.GetIngredientFromId(TUTORIAL_INGREDIENT_ID)
	local ingredientName = self:Emphasize(pinnedIngredient.Name, pinnedIngredient.Color)

	local slot = self:GetStructure("StickStands")

	local highlight = self:CreateHighlight(slot)

	-- B's roll sends the player across the base and back, so this is a return trip and gets pointed at
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
		-- Named live with a plain fallback -- it leaves their hands a beat before the goal thread wakes
		Description = function()
			local ingredient = Ingredients.GetIngredientFromId(EquippedItem.GetIngredientId())
			local name = if ingredient
				then self:Emphasize(ingredient.Name, ingredient.Color)
				else self:Emphasize("Ingredient")

			return `Put the {name} on your stick`
		end,
		Wait = function()
			-- A comma-separated list of what's on the stick, so anything at all in it is one added
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
