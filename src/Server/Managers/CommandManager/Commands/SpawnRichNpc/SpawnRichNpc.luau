return {
	Name = "spawnRichNpc",
	Aliases = { "rich" },
	Description = "Sends a rich customer to a player's stand right now",
	Args = {
		{
			Type = "player",
			Name = "Player",
			Description = "The player whose stand the customer should visit",
			Optional = true,
		},
	},
}
