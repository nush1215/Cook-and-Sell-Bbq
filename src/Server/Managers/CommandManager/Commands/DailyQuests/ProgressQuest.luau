return {
	Name = "progressQuest",
	Aliases = { "pq" },
	Description = "Adds progress to one quest on a player's daily quest board",
	Args = {
		{
			Type = "positiveInteger",
			Name = "Slot",
			Description = "The quest's tile, 1 to 3",
		},

		{
			Type = "positiveInteger",
			Name = "Amount",
			Description = "How much progress to add",
			Default = 1,
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player whose quest to progress",
			Optional = true,
		},
	},
}
