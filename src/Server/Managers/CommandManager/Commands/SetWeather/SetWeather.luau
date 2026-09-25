return {
	Name = "setWeather",
	Aliases = { "weather" },
	Description = "Rolls the server's weather over to another, or back to clear skies",
	Args = {
		{
			Type = "weatherName",
			Name = "Weather",
			Description = "The weather to roll over to, or Clear for the map's own skies",
		},
	},
}
