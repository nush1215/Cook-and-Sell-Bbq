return {
	Name = "giveIngredient",
	Aliases = { "gi" },
	Description = "Gives ingredients to a player, as stacking backpack tools",
	Args = {
		{
			Type = "ingredientId",
			Name = "Ingredient",
			Description = "The ingredient to give",
		},

		{
			Type = "positiveInteger",
			Name = "Amount",
			Description = "How many to give",
			Optional = true,
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player to give the ingredients to",
			Optional = true,
		},
	},
}
