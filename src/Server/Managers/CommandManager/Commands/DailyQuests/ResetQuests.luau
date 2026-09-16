return {
	Name = "resetQuests",
	Aliases = { "rq" },
	Description = "Moves a player's daily quest board to reset now or after a countdown",
	Args = {
		{
			Type = "number",
			Name = "SecondsLeft",
			Description = "How long until the board resets",
			Default = 0,
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player whose board to move",
			Optional = true,
		},
	},
}
