return {
	Name = "offlineEarnings",
	Aliases = { "oe" },
	Description = "Runs a player's workers through a stretch of time away, as a rejoin would",
	Args = {
		{
			Type = "number",
			Name = "Seconds",
			Description = "How long they were away for",
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player whose workers should run",
			Optional = true,
		},
	},
}
