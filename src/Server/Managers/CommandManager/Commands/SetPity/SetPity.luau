return {
	Name = "setPity",
	Aliases = { "sp", "ffp" },
	Description = "Fast-forwards a player's pity counter to the tier's threshold, so their next roll is a guaranteed one. Give a count to set it somewhere short of that instead",
	Args = {
		{
			Type = "pityTierId",
			Name = "Tier",
			Description = "The tier whose pity counter should be set",
		},

		{
			Type = "number",
			Name = "Count",
			Description = "Rolls since that tier or better. Leave it off to arm the counter at the tier's threshold, so the next roll is forced. Name a player and you have to give this too",
			Optional = true,
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player whose pity counter should be set",
			Optional = true,
		},
	},
}
