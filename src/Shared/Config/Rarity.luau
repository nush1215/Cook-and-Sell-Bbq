--[[
    How an ingredient's odds are shown to the player.

    An ingredient has no rarity word -- there's no tier name printed anywhere to keep in sync with the
    number behind it. It shows the odds it actually rolls at ("1 in 10M") and nothing else, so the
    label can never drift from the roll.

    It can't drift from the config either: Config.Ingredients derives every Chance from the same
    weight the roller draws on, rather than anyone writing the odds down by hand. This file only turns
    that number into text -- the colour it's drawn in comes off the ingredient's tier, which keys into
    Shared.Colors the same way sticks do.
]]

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)

--
local Rarity = {}

-- How a chance reads on a label: "1 in 7", "1 in 1K", "1 in 10M". Shares the suffix formatter with
-- prices so big numbers shorten the same way everywhere. Rounded because Chance is derived from a
-- division and would otherwise print as "1 in 8.44".
function Rarity.FormatChance(chance: number): string
	return `1 in {GuiUtil.ConvertNumberWithSuffix(math.round(chance))}`
end

return Rarity
