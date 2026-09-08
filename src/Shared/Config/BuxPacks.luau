-- The Bux the shop sells for Robux, one entry per ShopUI card of the same name. Amounts are provisional and noted as hours saved against an ~80k/hour playtest. Boosts deliberately don't apply.

--
export type BuxPack = {
	Id: string, -- also its ShopUI card name and its Products.luau id
	Name: string,
	Amount: number, -- Bux the pack hands over, exactly, boosts not folded in
	RobuxProductId: number, -- the dev product that buys it; 0 means none made yet, which Products.luau checks
}

--
local BuxPacks = {}

-- Cheapest first, which is the order the shop lays them out in.
BuxPacks.Data = {
	{ Id = "BuxPack1", Name = "Small Bux Pack", Amount = 10_000, RobuxProductId = 3709026393 }, -- ~7 min of play
	{ Id = "BuxPack2", Name = "Medium Bux Pack", Amount = 25_000, RobuxProductId = 3709026415 }, -- ~19 min
	{ Id = "BuxPack3", Name = "Large Bux Pack", Amount = 75_000, RobuxProductId = 3709026431 }, -- ~1 hr
	{ Id = "BuxPack4", Name = "Huge Bux Pack", Amount = 200_000, RobuxProductId = 3709026450 }, -- ~2.5 hrs
	{ Id = "BuxPack5", Name = "Mega Bux Pack", Amount = 600_000, RobuxProductId = 3709322656 }, -- ~7.5 hrs
}

table.freeze(BuxPacks.Data)

function BuxPacks.GetBuxPackFromId(id: string): BuxPack?
	for _, v in BuxPacks.Data do
		if v.Id == id then
			return v
		end
	end

	return nil
end

function BuxPacks.GetAllBuxPacks(): { BuxPack }
	return BuxPacks.Data
end

return BuxPacks
