return {
	Name = "giveStructure",
	Aliases = { "gs" },
	Description = "Gives structures (grillers, stands, cosmetics) to a player, as unplaced build tools",
	Args = {
		{
			Type = "structureId",
			Name = "Structure",
			Description = "The structure to give",
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
			Description = "The player to give the structures to",
			Optional = true,
		},
	},
}
