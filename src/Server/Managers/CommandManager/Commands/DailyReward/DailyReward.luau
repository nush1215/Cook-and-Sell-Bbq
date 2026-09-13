return {
	Name = "dailyReward",
	Aliases = { "dr" },
	Description = "Puts a player on a daily reward day, unlocking now or after a countdown",
	Args = {
		{
			Type = "positiveInteger",
			Name = "Day",
			Description = "The day to put them on, counted across weeks (8 is the second week's Day 1)",
		},

		{
			Type = "number",
			Name = "SecondsLeft",
			Description = "How long until it unlocks",
			Default = 0,
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player to move",
			Optional = true,
		},
	},
}
