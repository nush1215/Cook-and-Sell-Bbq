return {
	Name = "giveCosmetics",
	Aliases = { "gcos" },
	Description = "Gives one of every cosmetic to a player, as unplaced build tools",
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
			Description = "The player to give the cosmetics to",
			Optional = true,
		},
	},
}
