return {
	Name = "hireEmployee",
	Aliases = { "hire" },
	Description = "Hires an employee for a player's hut and puts them straight to work",
	Args = {
		{
			Type = "employeeBody",
			Name = "Body",
			Description = "Which rig they wear",
		},

		{
			Type = "number",
			Name = "Stars",
			Description = "Their rating out of 5, decimals allowed. Defaults to 3",
			Optional = true,
		},

		{
			Type = "employeeRole",
			Name = "Role",
			Description = "The station they work. Defaults to Cooker, the only one implemented",
			Optional = true,
		},

		{
			Type = "player",
			Name = "Player",
			Description = "The player to hire them for",
			Optional = true,
		},
	},
}
