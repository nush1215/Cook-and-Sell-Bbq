-- Services
local Players = game:GetService("Players")

--
local LocalPlayer = Players.LocalPlayer

local INGREDIENT_TOOL_TAG = "IngredientTool"
local STICK_TOOL_TAG = "StickTool"
local FILLED_TOOL_TAG = "FilledStickTool"
local SAUCE_TOOL_TAG = "SauceTool"
local CRATE_TOOL_TAG = "CrateTool"

--[[
    What the local player is currently holding.

    An equipped tool is parented to the character, so "held" is just a scan of the character's
    children for a tool with the right tag -- the same read the server does before it acts on a
    place/put request (see StickStandManager.getEquippedStickPlacement). A character holds at most
    one equipped tool, so the first hit is the answer.

    Callers use this to decide what a prompt should say and which interactables should light up, and
    re-run it whenever a tool is added to or removed from the character.
]]

--
local EquippedItem = {}

-- The equipped tool carrying `tag` -- or, with no tag, whatever tool is equipped at all. nil if
-- nothing matches.
local function findEquippedTool(tag: string?): Tool?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	for _, child in character:GetChildren() do
		if child:IsA("Tool") and (not tag or child:HasTag(tag)) then
			return child
		end
	end

	return nil
end

-- Whatever the local player has equipped, whichever kind, or nil if their hands are empty.
function EquippedItem.GetTool(): Tool?
	return findEquippedTool()
end

-- The id of the loose ingredient the local player is holding, or nil.
function EquippedItem.GetIngredientId(): string?
	local tool = findEquippedTool(INGREDIENT_TOOL_TAG)
	return tool and tool:GetAttribute("IngredientId")
end

-- The id of the empty stick the local player is holding, or nil.
function EquippedItem.GetStickId(): string?
	local tool = findEquippedTool(STICK_TOOL_TAG)
	return tool and tool:GetAttribute("StickId")
end

-- The id of the sauce bottle the local player is holding, or nil.
function EquippedItem.GetSauceId(): string?
	local tool = findEquippedTool(SAUCE_TOOL_TAG)
	return tool and tool:GetAttribute("SauceId")
end

-- The filled-skewer tool the local player is holding, or nil. Returns the tool rather than an id so
-- callers can read its Cooked attribute -- raw and cooked skewers go to different places.
function EquippedItem.GetSkewer(): Tool?
	return findEquippedTool(FILLED_TOOL_TAG)
end

-- The crate tool the local player is holding, or nil. Returns the tool rather than an id because
-- opening one reads its Count as well, to cap how many the open panel offers.
function EquippedItem.GetCrate(): Tool?
	return findEquippedTool(CRATE_TOOL_TAG)
end

return EquippedItem
