return {
	Name = "spawnWizardNpc",
	Aliases = { "wizard" },
	Description = "Sends a wizard customer to a player's stand right now",
	Args = {
		{
			Type = "player",
			Name = "Player",
			Description = "The player whose stand the wizard should visit",
			Optional = true,
		},
	},
}
