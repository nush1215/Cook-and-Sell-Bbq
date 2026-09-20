return {
	Name = "completeQuest",
	Aliases = { "cq" },
	Description = "Finishes one quest on a player's daily quest board, leaving it to be claimed",
	Args = {
		{
			Type = "positiveInteger",
			Name = "Slot",
			Description = "The quest's tile, 1 to 3",
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player whose quest to finish",
			Optional = true,
		},
	},
}
