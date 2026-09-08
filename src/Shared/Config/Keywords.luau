-- One vocabulary of coloured words for all player-facing text, borrowing colours from Shared.Colors and Highlights so a word matches the thing it names.

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)
local Colors = require(Shared.Colors)
local Highlights = require(Shared.Config.Highlights)

--
local Keywords = {}

-- One colour across the stick, its shop and its stand -- they're one errand, and this says so
local STICK_COLOR = Color3.fromRGB(222, 184, 135)

-- The heat rather than the metal, a grill's own grey barely carrying. Shared with the shop that sells them
local GRILLER_COLOR = Color3.fromRGB(255, 146, 40)

-- Numbers and the "[N]" stack suffix, in the game's existing emphasis gold
Keywords.NUMBER = Color3.fromRGB(255, 212, 0)

-- The banner's fallback for an unnamed keyword. Verbs and buttons live here, not below -- they aren't objects to recognise
Keywords.EMPHASIS = Color3.fromRGB(85, 255, 0)

-- Objects, coloured as the thing rather than plain emphasis. Plurals are spelled out; longest key wins
Keywords.Colors = {
	Stick = STICK_COLOR,
	Sticks = STICK_COLOR,
	["Stick Shop"] = STICK_COLOR,
	["Stick Stand"] = STICK_COLOR,
	["Stick Stands"] = STICK_COLOR,

	-- Kept clear of the griller's colour -- they share a line, so they must read as two things
	BBQ = Color3.fromRGB(225, 122, 78),
	BBQs = Color3.fromRGB(225, 122, 78),

	-- The noun only; the bare verb stays plain. The shop takes the griller's colour, not the stand's tan
	Griller = GRILLER_COLOR,
	Grillers = GRILLER_COLOR,
	["Grill & Stand Shop"] = GRILLER_COLOR,

	-- Straight off Highlights, where gold already means "there's money in this" -- which a customer is
	Customer = Highlights.CLAIM,
	Customers = Highlights.CLAIM,

	-- A plain steel grey-blue, deliberately the dullest here -- it isn't bought, cooked or sold
	Hammer = Color3.fromRGB(175, 185, 195),

	-- No colour of its own to borrow; a cool blue clear of the tan, orange and gold
	Crate = Color3.fromRGB(120, 180, 230),
	Crates = Color3.fromRGB(120, 180, 230),

	-- The tier words, keyed off Shared.Colors so the word matches the thing it describes
	Common = Colors.Common.TextColor,
	Uncommon = Colors.Uncommon.TextColor,
	Rare = Colors.Rare.TextColor,
	Epic = Colors.Epic.TextColor,
	Legendary = Colors.Legendary.TextColor,
	Mythic = Colors.Mythic.TextColor,
}

-- Lowered and sorted longest-first, so matching is case-insensitive and "Uncommon" beats "Common"
local LOWERED_KEYWORDS = {}
local SORTED_KEYWORDS = {}

for keyword, color in Keywords.Colors do
	LOWERED_KEYWORDS[keyword:lower()] = color
	table.insert(SORTED_KEYWORDS, keyword:lower())
end

table.sort(SORTED_KEYWORDS, function(a, b)
	return #a > #b
end)

-- A price the way every call site writes one: "$500", "$1.2K", "$1,250".
local MONEY_PATTERN = "^%$%d[%d,]*%.?%d*%a*"
-- A unit is part of the number it follows -- a multiplier's "x", a duration's "m" -- so it colours with it
local NUMBER_PATTERN = "^%d+%.?%d*%a*"

-- Bounded, so "Uncommon" can't match as "Common" and "$500" can't match again as "500"
local function isWordBoundary(character: string?): boolean
	return character == nil or not character:match("[%w$]")
end

-- Colours every keyword, price and number in a line, leaving existing RichText tags alone -- so it never nests, and is safe to run twice.
function Keywords.Highlight(text: string): string
	local result = {}
	local index = 1
	local length = #text
	local fontDepth = 0

	while index <= length do
		local character = text:sub(index, index)

		-- Step over the tag itself, and remember whether it opened or closed a coloured run
		if character == "<" then
			local tagEnd = text:find(">", index, true)

			if tagEnd then
				local tag = text:sub(index, tagEnd)

				if tag:match("^</") then
					fontDepth = math.max(fontDepth - 1, 0)
				elseif not tag:match("/>$") then
					fontDepth += 1
				end

				table.insert(result, tag)
				index = tagEnd + 1
				continue
			end
		end

		-- Anything inside a tag already has a colour someone chose on purpose
		if fontDepth > 0 then
			table.insert(result, character)
			index += 1
			continue
		end

		local previousCharacter: string? = if index > 1 then text:sub(index - 1, index - 1) else nil
		local matched: string? = nil
		local color: Color3? = nil

		if isWordBoundary(previousCharacter) then
			if character == "$" then
				matched = text:match(MONEY_PATTERN, index)
				color = Colors.Currency
			elseif character:match("%d") then
				matched = text:match(NUMBER_PATTERN, index)
				color = Keywords.NUMBER
			else
				for _, keyword in SORTED_KEYWORDS do
					local candidate = text:sub(index, index + #keyword - 1)
					local nextCharacter = text:sub(index + #keyword, index + #keyword)

					if candidate:lower() == keyword and isWordBoundary(nextCharacter) then
						matched = candidate
						color = LOWERED_KEYWORDS[keyword]
						break
					end
				end
			end
		end

		if matched then
			table.insert(result, GuiUtil.Colorize(matched, color))
			index += #matched
		else
			table.insert(result, character)
			index += 1
		end
	end

	return table.concat(result)
end

return Keywords
