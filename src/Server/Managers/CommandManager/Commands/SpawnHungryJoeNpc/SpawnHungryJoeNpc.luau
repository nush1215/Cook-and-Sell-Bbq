return {
	Name = "spawnHungryJoeNpc",
	Aliases = { "joe" },
	Description = "Sends Hungry Joe to a player's base right now, or brings back one still owed his stick",
	Args = {
		{
			Type = "player",
			Name = "Player",
			Description = "The player whose base Hungry Joe should visit",
			Optional = true,
		},
	},
}
