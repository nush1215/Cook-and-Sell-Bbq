return {
	Name = "forceIngredient",
	Aliases = { "fi" },
	Description = "Forces a player's next roll to land this ingredient on their first stand",
	Args = {
		{
			Type = "ingredientId",
			Name = "Ingredient",
			Description = "The ingredient the next roll should land",
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player whose next roll should be forced",
			Optional = true,
		},
	},
}
