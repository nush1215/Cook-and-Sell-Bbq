-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)
local GuiUtil = require(Shared.GuiUtil)

----
local PlayerDataManager
local NotificationManager

--[[
	Tracks a per-player index of the ingredients they've ever obtained, plus a lifetime count of how
	many. Distinct from the Ingredients inventory (which rises and falls as ingredients are obtained
	and consumed) -- the index only ever grows, so it's the source of truth for "has this player
	discovered X" and "how many have they pulled over their lifetime". Kept for future collection/stat
	features; the data replicates to its owner, so a client UI can read it straight off player data.
]]
local IndexManager = {
	-- (player, ingredientId) the first time a player ever obtains an ingredient.
	OnIngredientDiscovered = Signal.new(),
}

-- Records that a player obtained some amount of an ingredient (default one), bumping its lifetime
-- count in the index. The first obtain seeds the entry, so a key's presence marks it discovered.
-- Returns whether this obtain was that first discovery, so a caller can drop its own sound rather than
-- stacking it on the discovery notification's.
function IndexManager:RecordIngredientObtained(player: Player, ingredientId: string, amount: number?): boolean
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return false
	end

	local count = data.IngredientIndex[ingredientId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "IngredientIndex", ingredientId }, count + (amount or 1))

	-- An entry already there means they've pulled this one before, so it's an ordinary obtain.
	if count > 0 then
		return false
	end

	-- The name is tinted with the ingredient's own label colour so it stands out in the line.
	local ingredient = Ingredients.GetIngredientFromId(ingredientId)
	NotificationManager:NotifyNormal(player, {
		Text = `New ingredient discovered {GuiUtil.Colorize(ingredient.Name, ingredient.Color)}!`,
		Duration = 5,
		Sound = "DiscoveredNewIngredient",
		Effect = "Success",
	})
	self.OnIngredientDiscovered:Fire(player, ingredientId)

	return true
end

function IndexManager:OnInit()
	--
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	NotificationManager = require(script.Parent.NotificationManager)
end

return IndexManager
