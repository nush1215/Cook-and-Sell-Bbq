return {
	Name = "spawnTutorialCrate",
	Aliases = { "stc" },
	Description = "Spawns the tutorial completion crate on a player's base",
	Args = {
		{
			Type = "boolean",
			Name = "ShowTimer",
			Description = "Whether it lands behind the countdown, or ready to open at once",
			Default = true,
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player to spawn the crate for",
			Optional = true,
		},
	},
}
