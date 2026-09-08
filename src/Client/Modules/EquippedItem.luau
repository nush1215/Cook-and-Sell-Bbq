-- Services
local Players = game:GetService("Players")

--
local LocalPlayer = Players.LocalPlayer

local INGREDIENT_TOOL_TAG = "IngredientTool"
local STICK_TOOL_TAG = "StickTool"
local FILLED_TOOL_TAG = "FilledStickTool"
local SAUCE_TOOL_TAG = "SauceTool"
local CRATE_TOOL_TAG = "CrateTool"
local STRUCTURE_TOOL_TAG = "StructureTool"

-- What the local player is holding: a scan of the character for a tagged tool, the same read the server does. A character holds at most one, so the first hit is the answer.

--
local EquippedItem = {}

-- The equipped tool carrying `tag`, or any equipped tool with no tag. Nil if nothing matches.
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

-- The held filled-skewer tool, or nil. The tool rather than an id, so callers can read Cooked.
function EquippedItem.GetSkewer(): Tool?
	return findEquippedTool(FILLED_TOOL_TAG)
end

-- The structure a build tool is out for, or nil -- which doubles as "are they placing right now".
function EquippedItem.GetStructureId(): string?
	local tool = findEquippedTool(STRUCTURE_TOOL_TAG)
	return tool and tool:GetAttribute("StructureId")
end

-- The held crate tool, or nil. The tool rather than an id, since opening reads its Count too.
function EquippedItem.GetCrate(): Tool?
	return findEquippedTool(CRATE_TOOL_TAG)
end

return EquippedItem
