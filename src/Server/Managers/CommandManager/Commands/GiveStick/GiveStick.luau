return {
	Name = "giveStick",
	Aliases = { "gst" },
	Description = "Gives sticks to a player, as stacking backpack tools",
	Args = {
		{
			Type = "stickId",
			Name = "Stick",
			Description = "The stick to give",
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
			Description = "The player to give the sticks to",
			Optional = true,
		},
	},
}
