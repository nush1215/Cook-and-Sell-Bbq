return {
	Name = "replay",
	Aliases = { "rp" },
	Description = "Plays a saved FTUE drop recording on your own base, or stops the one running",
	Args = {
		{
			Type = "string",
			Name = "Key",
			Description = "The replay key from the drop report's footer, or 'stop' to end the one playing",
		},
	},
}
