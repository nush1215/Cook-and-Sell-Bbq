--
return {

	Currency = Color3.fromRGB(0, 255, 0),

	-- Rarity Colors, keyed by the tier word sticks are authored with and ingredient tiers take their
	-- Id from -- so a Rare stick and a Rare ingredient read the same colour. Ingredients still show
	-- odds rather than the word itself (see Config.Rarity).
	Common = {
		TextColor = Color3.fromRGB(85, 170, 0),
		StrokeColor = Color3.fromRGB(0, 50, 0),
	},

	Uncommon = {
		TextColor = Color3.fromRGB(0, 200, 130),
		StrokeColor = Color3.fromRGB(0, 55, 35),
	},

	Rare = {
		TextColor = Color3.fromRGB(0, 170, 255),
		StrokeColor = Color3.fromRGB(0, 41, 61),
	},

	Epic = {
		TextColor = Color3.fromRGB(170, 85, 255),
		StrokeColor = Color3.fromRGB(43, 0, 65),
	},

	Legendary = {
		TextColor = Color3.fromRGB(255, 170, 0),
		StrokeColor = Color3.fromRGB(56, 35, 0),
	},

	Mythic = {
		TextColor = Color3.fromRGB(255, 116, 2),
		StrokeColor = Color3.fromRGB(50, 20, 0),
	},
}
