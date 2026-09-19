return {
	Name = "resetUpdateLog",
	Aliases = { "rul" },
	Description = "Clears a player's seen update log, so it comes up again on their next join",
	Args = {
		{
			Type = "player",
			Name = "Player",
			Description = "The player whose update log to clear",
			Optional = true,
		},
	},
}
