-- Turns an ingredient's odds into text. It shows the rate it actually rolls at and no tier name, so the label can never drift from the roll.

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)

--
local Rarity = {}

-- How a chance reads on a label, sharing the suffix formatter with prices. Rounded, or it prints "1 in 8.44"
function Rarity.FormatChance(chance: number): string
	return `1 in {GuiUtil.ConvertNumberWithSuffix(math.round(chance))}`
end

return Rarity
