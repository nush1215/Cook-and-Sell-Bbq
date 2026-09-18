return {
	Name = "giveGems",
	Aliases = { "gg" },
	Description = "Gives Gems to a player",
	Args = {
		{
			Type = "positiveInteger",
			Name = "Amount",
			Description = "The amount of Gems to give",
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player to give Gems to",
			Optional = true,
		},
	},
}
