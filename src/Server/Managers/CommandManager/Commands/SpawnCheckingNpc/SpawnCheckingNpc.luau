return {
	Name = "spawnCheckingNpc",
	Aliases = { "checker" },
	Description = "Sends a customer to ask whether a player has any BBQ for sale right now",
	Args = {
		{
			Type = "player",
			Name = "Player",
			Description = "The player whose stand the customer should come asking at. A stocked stand means it buys straight away rather than waiting",
			Optional = true,
		},
	},
}
