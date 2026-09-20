return {
	Name = "forceTip",
	Aliases = { "tip" },
	Description = "Makes a player's next paying customer tip Gems, skipping the chance roll and the gap between tips",
	Args = {
		{
			Type = "player",
			Name = "Player",
			Description = "The player whose next paying customer should tip",
			Optional = true,
		},
	},
}
