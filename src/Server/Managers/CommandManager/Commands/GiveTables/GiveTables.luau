return {
	Name = "giveTables",
	Aliases = { "gtab" },
	Description = "Gives one of every table to a player, as unplaced build tools",
	Args = {
		{
			Type = "positiveInteger",
			Name = "Amount",
			Description = "How many of each to give",
			Optional = true,
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player to give the tables to",
			Optional = true,
		},
	},
}
