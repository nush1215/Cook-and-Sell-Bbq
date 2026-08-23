--[[
    The one-time offer a new player gets, and what's in it.

    Everything the shop card shows about an entry -- its name, icon and what it's worth -- is read out
    of the Sticks or Ingredients config it points at, so this file only says what and how many. That
    keeps a repriced ingredient or a re-iconed stick from needing an edit here too.

    The offer is timed, and the clock is a stamp rather than a duration: ShopManager writes an absolute
    expiry into the player's StarterPackStart the first time they join, so it keeps running while
    they're offline and can't be reset by rejoining. DURATION is only how far ahead that stamp is set.

    Buying it is PurchaseOnce, which stops a second purchase for yourself. It doesn't take the card
    off the shop, though: PurchaseOnce is validated against the recipient when gifting, so an owner
    can still gift the pack to someone who hasn't had it, and only the clock running out ends the
    offer.
]]

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

-- The Robux dev product that buys it. A 0 here means none has been made on the dashboard yet, which
-- Products.luau checks -- no product means no shop card, rather than a button that can't charge.
StarterPack.RobuxProductId = 3709199992

-- How long a player has to take the offer, measured from their first join.
StarterPack.DURATION = 24 * 60 * 60

-- Config order is the order the shop card lays them out in: entry N fills the card's slot named "N".
StarterPack.Contents = {
	{ Type = "Stick", Id = "BambooStick", Amount = 3 },
	{ Type = "Ingredient", Id = "Chicken", Amount = 2 },
	{ Type = "Ingredient", Id = "Pineapple", Amount = 2 },
}

-- An entry pointing at a stick or ingredient the config doesn't have is dropped rather than left in,
-- so a typo can't be sold and then fail to grant halfway through handing the pack over.
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
