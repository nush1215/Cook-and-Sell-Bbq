return {
	Name = "fireEmployees",
	Aliases = { "fire" },
	Description = "Fires a player's whole roster, handing back anything they were carrying",
	Args = {
		{
			Type = "player",
			Name = "Player",
			Description = "The player whose employees should go",
			Optional = true,
		},
	},
}
