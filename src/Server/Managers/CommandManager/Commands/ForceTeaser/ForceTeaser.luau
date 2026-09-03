return {
	Name = "forceTeaser",
	Aliases = { "ft" },
	Description = "Makes a player's next pull show off a cool ingredient they can't afford, skipping the chance roll it normally waits on",
	Args = {
		{
			Type = "player",
			Name = "Player",
			Description = "The player whose next pull should tease",
			Optional = true,
		},
	},
}
