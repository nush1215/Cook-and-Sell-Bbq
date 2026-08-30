--[[
    The words that get coloured when they turn up in player-facing text.

    One vocabulary for the whole game, so a word carries the same colour wherever it's written. The
    tutorial banner looks a keyword up by hand (TutorialController:Emphasize) because it knows which
    word it means; notifications hand their whole line to Keywords.Highlight and let it find them,
    because a toast is written once and read everywhere and nobody wants to mark up sixty of them.

    Colours are borrowed rather than invented wherever something already owns one -- the rarity tiers
    come off Shared.Colors so a Rare stick and the word "Rare" match, and a customer is the gold that
    Highlights already uses to mean "there's money in this".
]]

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)
local Colors = require(Shared.Colors)
local Highlights = require(Shared.Config.Highlights)

--
local Keywords = {}

-- Sticks, and the two places that deal in them. One colour across all three on purpose: the shop, the
-- stand and the stick itself are one errand, and colouring them alike is what says so before the player
-- has worked out that a stand is where a stick goes.
local STICK_COLOR = Color3.fromRGB(222, 184, 135)

-- The heat rather than the metal. A charcoal grill's own colour is a dark grey that would barely
-- carry on the banner, and the fire is the half of it the player is being sent to work anyway.
-- Shared with the shop that sells them, the same way the stick tan above covers the Stick Shop.
local GRILLER_COLOR = Color3.fromRGB(255, 146, 40)

-- Numbers, and the "[3]" that says a notification has fired three times. The game's existing emphasis
-- gold -- the same #ffd400 that ShopManager, CodeManager and the daily reward already write by hand.
Keywords.NUMBER = Color3.fromRGB(255, 212, 0)

-- What the tutorial banner falls back to for a keyword this file doesn't name, so "Pull the Lever"
-- still says which word is the thing to go and find. Verbs and UI buttons ("Lever", "Knob", "Accept",
-- "Store") live here rather than in the table below -- they aren't objects to go and recognise, and
-- giving them object colours would only dilute the words that are.
Keywords.EMPHASIS = Color3.fromRGB(85, 255, 0)

-- Words that name a thing the player can picture, coloured as that thing rather than as the plain
-- emphasis green, so the word carries what it's pointing at and not just that it's worth reading.
-- Plurals are spelled out rather than stemmed; Highlight matches the longest key first, so "BBQs"
-- wins over "BBQ" and "Stick Shop" over "Stick".
Keywords.Colors = {
	Stick = STICK_COLOR,
	Sticks = STICK_COLOR,
	["Stick Shop"] = STICK_COLOR,
	["Stick Stand"] = STICK_COLOR,
	["Stick Stands"] = STICK_COLOR,

	-- Glazed and cooked, and kept clear of the griller's own colour: the two share a line more than once
	-- ("Place your BBQ on the grill"), so they have to read as two things rather than one phrase.
	BBQ = Color3.fromRGB(225, 122, 78),
	BBQs = Color3.fromRGB(225, 122, 78),

	-- Only the noun: "grill" on its own is the verb ("You need a BBQ to grill!") and stays plain. The
	-- shop's whole name is safe to name where that bare word isn't, since nothing else in the game
	-- reads "Grill & Stand Shop" -- and it takes the griller's colour rather than the stand's tan so
	-- the two shops don't come out looking like one.
	Griller = GRILLER_COLOR,
	Grillers = GRILLER_COLOR,
	["Grill & Stand Shop"] = GRILLER_COLOR,

	-- The game's own gold, straight off the Highlights palette, where gold already means "there's money
	-- in this" -- which is exactly what a customer is. Reused rather than mixed by hand so the word and
	-- every claimable thing in the game say the same colour.
	Customer = Highlights.CLAIM,
	Customers = Highlights.CLAIM,

	-- The tool that moves a build around, named once when the tutorial hands it over and in every toast
	-- about rearranging since. A plain steel grey-blue, deliberately the dullest thing in this table --
	-- it's the one item here that isn't bought, cooked or sold, and it shouldn't read like it is.
	Hammer = Color3.fromRGB(175, 185, 195),

	-- The only word here with no colour of its own to borrow -- each crate carries a Color in
	-- Config.Crates, but the generic word doesn't. A cool blue, picked to sit clear of the stick tan,
	-- the BBQ orange and the customer gold so a line naming two of them still reads as two.
	Crate = Color3.fromRGB(120, 180, 230),
	Crates = Color3.fromRGB(120, 180, 230),

	-- The tier words, keyed off Shared.Colors so the word matches the thing it describes.
	Common = Colors.Common.TextColor,
	Uncommon = Colors.Uncommon.TextColor,
	Rare = Colors.Rare.TextColor,
	Epic = Colors.Epic.TextColor,
	Legendary = Colors.Legendary.TextColor,
	Mythic = Colors.Mythic.TextColor,
}

-- Keys lowered once and sorted longest-first, so Highlight can match case-insensitively ("customer"
-- keeps its lowercase c) and so "Uncommon" is tried before "Common".
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
-- The trailing "x" is part of a multiplier ("3x Common Crate"), so it colours with the number.
local NUMBER_PATTERN = "^%d+%.?%d*x?"

-- A word only counts as a keyword if there's no letter or digit either side of it, so "Uncommon"
-- can't match as "Common" and "$500" can't match again as "500".
local function isWordBoundary(character: string?): boolean
	return character == nil or not character:match("[%w$]")
end

--[[
    Colours every keyword, price and number in a line of text, leaving anything already inside a
    RichText tag exactly as it was -- so hand-written markup and GuiUtil.Colorize'd names (an
    ingredient, a crate, a player) keep their own colour and never end up nested. That also makes this
    safe to run twice on the same string.
    @param text The text to colour
    @return The text with RichText font tags around the words this file names
]]
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
