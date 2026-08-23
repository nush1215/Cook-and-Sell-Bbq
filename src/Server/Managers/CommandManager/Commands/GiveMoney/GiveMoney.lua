return {
	Name = "giveMoney",
	Aliases = { "gm" },
	Description = "Gives currency to a player",
	Args = {
		{
			Type = "positiveInteger",
			Name = "Amount",
			Description = "The amount of currency to give",
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player to give currency to",
			Optional = true,
		},
	},
}
