return {
	Name = "giveCrate",
	Aliases = { "gc" },
	Description = "Gives unopened crates to a player",
	Args = {
		{
			Type = "crateId",
			Name = "Crate",
			Description = "The crate to give",
		},

		{
			Type = "positiveInteger",
			Name = "Amount",
			Description = "How many to give",
			Optional = true,
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player to give the crates to",
			Optional = true,
		},
	},
}
