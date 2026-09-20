return {
	Name = "spawnCustomOrderNpc",
	Aliases = { "order" },
	Description = "Sends a custom order customer to a player right now",
	Args = {
		{
			Type = "player",
			Name = "Player",
			Description = "The player the customer should bring an order to",
			Optional = true,
		},

		{
			Type = "customOrderVariation",
			Name = "Variation",
			Description = "Inspect looks the stand over and turns it down first, Direct asks on arrival. Leave it off to roll for one as an ordinary visit does. An Inspect order queues until the stand has a BBQ on it",
			Optional = true,
		},

		{
			Type = "boolean",
			Name = "Rich",
			Description = "True sends a rich customer asking for Rare or better, false an ordinary one. Leave it off to roll for it as an ordinary visit does",
			Optional = true,
		},
	},
}
