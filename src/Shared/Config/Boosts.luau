-- Timed consumable boosts and the curves they apply, not the permanent income ones -- see docs/balance.md.

--
export type Boost = {
	Id: string, -- also the Type stored in player data, and the argument the give command takes
	Name: string, -- what an icon reads before its amount, e.g. "Luck 1.25x"
	Icon: string, -- rbxassetid for the BoostIcon
}

--
local Boosts = {}

-- Most a player can hold at once; a grant past this drops the weakest they already had
Boosts.MAX_ACTIVE = 5

-- How often expired boosts are swept off. One pass over every player, so it's the tick rate, not a per-boost timer
Boosts.SWEEP_INTERVAL = 1

-- How hard luck is dampened before it reaches the exponent. HIGHER IS MORE AGGRESSIVE -- see docs/balance.md
Boosts.LUCK_STEEPNESS = 0.9

-- Past this luck displaces the tier guarantees rather than working alongside them -- see docs/balance.md
Boosts.MAX_LUCK = 3

Boosts.Data = {
	{
		Id = "Luck",
		Name = "Luck",
		Icon = "rbxassetid://94882864367766",
	},
} :: { Boost }

table.freeze(Boosts.Data)

local boostsById = {}

for _, boost in Boosts.Data do
	boostsById[boost.Id] = boost
end

table.freeze(boostsById)

function Boosts.GetBoostFromId(id: string): Boost?
	return boostsById[id]
end

function Boosts.GetAllBoosts(): { Boost }
	return Boosts.Data
end

-- How a boost reads on its icon and in its toast, written once so the two can't drift.
function Boosts.GetLabel(boostId: string, amount: number): string
	-- %.10g so 1.25 stays "1.25" and 2 reads "2" rather than "2.0"
	return `{boostsById[boostId].Name} {string.format("%.10g", amount)}x`
end

-- What a roll weight becomes under `luck`. Returns it untouched at 1, so a caller applies it unconditionally.
function Boosts.GetLuckWeight(baseWeight: number, luck: number): number
	-- Clamped where it's read rather than where it's granted, so a bad grant can't reach the economy
	return baseWeight ^ (1 / math.clamp(luck, 1, Boosts.MAX_LUCK) ^ Boosts.LUCK_STEEPNESS)
end

return Boosts
