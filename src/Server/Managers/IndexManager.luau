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

-- A per-player index of every ingredient ever obtained, plus a lifetime count. Only ever grows, unlike the Ingredients inventory, and replicates to its owner.
local IndexManager = {
	-- (player, ingredientId) the first time a player ever obtains an ingredient.
	OnIngredientDiscovered = Signal.new(),
}

-- Records an obtain, bumping the index's lifetime count. Returns whether it was the first discovery.
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
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	NotificationManager = require(script.Parent.NotificationManager)
end

return IndexManager
