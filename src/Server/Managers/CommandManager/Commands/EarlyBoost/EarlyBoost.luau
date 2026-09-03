return {
	Name = "earlyBoost",
	Aliases = { "eb" },
	Description = "Turns a player's early boost on or off for this session",
	Args = {
		{
			Type = "boolean",
			Name = "Enabled",
			Description = "Whether the early boost should apply",
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player whose early boost should be toggled",
			Optional = true,
		},
	},
}
