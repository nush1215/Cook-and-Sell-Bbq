return {
	Name = "giveBoost",
	Aliases = { "gb", "boost" },
	Description = "Gives a player a timed boost. Several stack -- the biggest one applies, and it falls to the next as that one runs out",
	Args = {
		{
			Type = "boostId",
			Name = "Boost",
			Description = "The boost to give",
		},

		{
			Type = "number",
			Name = "Amount",
			Description = "The multiplier, e.g. 1.5 for a 1.5x boost. Luck is clamped to its config ceiling when it's read",
		},

		{
			Type = "number",
			Name = "Duration",
			Description = "How many seconds it lasts. It runs on wall-clock, so it keeps counting down while they're offline",
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player to give it to",
			Optional = true,
		},
	},
}
