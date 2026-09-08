-- The one-time new-player offer. Entries name what and how many; names, icons and values come off the configs they point at. The clock is an absolute stamp, so it runs offline and a rejoin can't reset it.

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)
local Sticks = require(Shared.Config.Sticks)

--
export type EntryType = "Stick" | "Ingredient"

export type Entry = {
	Type: EntryType, -- which config the id below comes from, and which manager grants it
	Id: string, -- a Sticks or Ingredients id, depending on Type
	Amount: number, -- how many of it the pack hands over
}

--
local StarterPack = {}

StarterPack.Id = "StarterPack" -- also its Products.luau id, and the tag a buyer is given
StarterPack.Name = "Starter Pack"

-- The product that buys it; a 0 means none exists yet, so Products.luau leaves the card off
StarterPack.RobuxProductId = 3709199992

-- How long a player has to take the offer, measured from their first join.
StarterPack.DURATION = 24 * 60 * 60

-- Config order is the order the shop card lays them out in: entry N fills the card's slot named "N".
StarterPack.Contents = {
	{ Type = "Stick", Id = "BambooStick", Amount = 3 },
	{ Type = "Ingredient", Id = "Chicken", Amount = 2 },
	{ Type = "Ingredient", Id = "Pineapple", Amount = 2 },
}

-- An entry naming something the config doesn't have is dropped, so a typo can't be sold and then fail
for index = #StarterPack.Contents, 1, -1 do
	local entry = StarterPack.Contents[index]
	local exists = if entry.Type == "Stick"
		then Sticks.GetStickFromId(entry.Id) ~= nil
		else Ingredients.GetIngredientFromId(entry.Id) ~= nil

	if not exists then
		warn(`Starter pack contains a {entry.Type} the config doesn't have ({entry.Id}), it won't be given`)
		table.remove(StarterPack.Contents, index)
	end
end

table.freeze(StarterPack.Contents)

return StarterPack
