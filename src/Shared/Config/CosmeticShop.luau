-- The Cosmetic Shop: cosmetics, tables and Worker Huts sold for Gems, a few drawn from each tier every rotation. The structures themselves are Config.Structures entries; this holds what each tier offers and what it costs. See docs/balance.md.

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Structures = require(Shared.Config.Structures)

--
export type Offer = {
	Id: string, -- a Structures id, which is what a purchase grants
	Price: number, -- Gems for the first one bought here
	PriceStep: number?, -- Gems the price climbs per copy already bought, nil for one that never moves
	PriceMultiplier: number?, -- what the price is multiplied by per copy already bought, nil for one that never moves
	FreeCopies: number?, -- copies handed over outside the shop (the repaired hut), which the climb doesn't count
	Amount: number?, -- how many one purchase grants, nil for one. Read as "x3 Name" wherever it's shown
	Weight: number, -- this offer's share of its tier's draws
}

export type Tier = {
	Id: string, -- the key a rotation is stored under, and which of the shop's slots the client fills from it
	Slots: number, -- how many distinct offers each rotation draws from this tier
	Offers: { Offer },
}

--
local CosmeticShop = {}

-- How many of each offer one player can buy per rotation
CosmeticShop.STOCK = 1

-- In draw order, which is what keeps every server's rotation the same off the same seed
CosmeticShop.Tiers = {
	-- Anything that earns is priced by what it earns, anything that's only looks stays cheap; see docs/balance.md
	{
		Id = "Featured",
		Slots = 1,
		Offers = {
			-- The goal the shop saves toward: a hut is another free worker slot and room to buy two more. Doubles per hut, the repaired one aside, so the third is the real ask
			{ Id = "RepairedHut", Price = 550, PriceMultiplier = 2, FreeCopies = 1, Weight = 1 },
			-- The only draw for rich orders, and their bigger tips, on top of its two seats; six tables reach RICH_CHANCE_MAX, each 100 dearer than the last
			{ Id = "FancyTable", Price = 600, PriceStep = 100, Weight = 1 },
		},
	},

	{
		Id = "Great",
		Slots = 2,
		Offers = {
			-- 60 Gems a seat (2, 4, 3 and 6): each speeds custom orders up, and a seated order tips surer and bigger
			{ Id = "SmallWoodenTable", Price = 120, Weight = 3 },
			{ Id = "MediumWoodenTable", Price = 240, Weight = 3 },
			{ Id = "CircularTable", Price = 180, Weight = 3 },
			{ Id = "LargeWoodenTable", Price = 360, Weight = 3 },
			-- Only looks, so priced like the decorations in Good rather than the tables beside them
			{ Id = "MediumCanopy", Price = 75, Weight = 3 },
			{ Id = "LargeCanopy", Price = 120, Weight = 3 },
			-- Only two seats, but orders seated there pay 1.2x, so the dearest table here and the rarest to turn up
			{ Id = "GoldenTable", Price = 1_000, Weight = 2 },
		},
	},

	{
		Id = "Good",
		Slots = 3,
		-- All only looks, cheap enough to buy on a whim. Paths weigh half the rest, or ten of them would crowd the tier
		Offers = {
			{ Id = "SmallDirtPath", Price = 10, Amount = 3, Weight = 1 },
			{ Id = "MediumDirtPath", Price = 15, Amount = 3, Weight = 1 },
			{ Id = "LongDirtPath", Price = 20, Amount = 3, Weight = 1 },
			{ Id = "LargeDirtPath", Price = 25, Amount = 3, Weight = 1 },
			{ Id = "BigDirtPath", Price = 30, Amount = 3, Weight = 1 },
			{ Id = "SmallStonePath", Price = 15, Amount = 3, Weight = 1 },
			{ Id = "MediumStonePath", Price = 20, Amount = 3, Weight = 1 },
			{ Id = "LongStonePath", Price = 25, Amount = 3, Weight = 1 },
			{ Id = "LargeStonePath", Price = 30, Amount = 3, Weight = 1 },
			{ Id = "BigStonePath", Price = 40, Amount = 3, Weight = 1 },
			{ Id = "SmallFence", Price = 10, Amount = 2, Weight = 2 },
			{ Id = "MediumFence", Price = 15, Amount = 2, Weight = 2 },
			{ Id = "LongFence", Price = 25, Amount = 2, Weight = 2 },
			{ Id = "HangingLight", Price = 40, Weight = 2 },
			{ Id = "PicnicParasol", Price = 50, Weight = 2 },
		},
	},
} :: { Tier }

-- Drops an offer whose structure the config doesn't have (a missing model prunes it there), and warns on a tier too small to fill.
for _, tier in CosmeticShop.Tiers do
	for index = #tier.Offers, 1, -1 do
		local offer = tier.Offers[index]

		if not Structures.GetStructureFromId(offer.Id) then
			warn(`Cosmetic Shop's {tier.Id} tier sells a structure the config doesn't have ({offer.Id}), it won't be stocked`)
			table.remove(tier.Offers, index)
		end
	end

	if #tier.Offers < tier.Slots then
		warn(
			`Cosmetic Shop's {tier.Id} tier draws {tier.Slots} distinct offers from only {#tier.Offers}, so it can't fill `
				.. `every slot -- add offers or drop its Slots`
		)
	end
end

table.freeze(CosmeticShop.Tiers)

-- An offer and the tier selling it, or nil for a structure the shop never stocks.
function CosmeticShop.GetOffer(structureId: string): (Offer?, Tier?)
	for _, tier in CosmeticShop.Tiers do
		for _, offer in tier.Offers do
			if offer.Id == structureId then
				return offer, tier
			end
		end
	end

	return nil, nil
end

-- What one more costs that player: the base price climbed by every copy they already bought here, so each is dearer than the last.
function CosmeticShop.GetPrice(offer: Offer, data): number
	local bought = math.max(0, Structures.CountOwned(data, offer.Id) - (offer.FreeCopies or 0))
	local price = (offer.Price + (offer.PriceStep or 0) * bought) * (offer.PriceMultiplier or 1) ^ bought

	return math.floor(price)
end

-- An offer as the shop names it: "x3 Medium Dirt Path" for a bundle, the plain name for one.
function CosmeticShop.GetOfferName(offer: Offer): string
	local structure = Structures.GetStructureFromId(offer.Id)
	local amount = offer.Amount or 1

	return if amount > 1 then `x{amount} {structure.Name}` else structure.Name
end

return CosmeticShop
