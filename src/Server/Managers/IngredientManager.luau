-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)
local GuiUtil = require(Shared.GuiUtil)

-- Assets
local Assets = ReplicatedStorage.Assets
local ToolTemplate = Assets.Tools.IngredientTool

--
local PlayerDataManager
local IndexManager

--
local TOOL_TAG = "IngredientTool"
local HELD_TAG = "HeldItem"

-- Projects a player's owned ingredients onto backpack tools, one per kind with a Count. Player data is the only source of truth, so stacking, respawn and rejoin all fall out of one reconcile.

--
local IngredientManager = {
	_listeners = {}, -- [player] = the Ingredients data listener
	_pendingEquips = {}, -- [player] = the ingredient id to equip once its tool exists
}

-- Equips a tool. A no-op mid-respawn, since the new character's reconcile rebuilds their tools.
local function equipTool(player: Player, tool: Tool)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:EquipTool(tool)
	end
end

-- The player's ingredient tools by id. Both containers, since an equipped tool sits in the character.
local function getIngredientTools(player: Player): { [string]: Tool }
	local tools = {}
	local containers = { player:FindFirstChildOfClass("Backpack"), player.Character }

	for _, container in containers do
		if not container then
			continue
		end

		for _, child in container:GetChildren() do
			if not (child:IsA("Tool") and child:HasTag(TOOL_TAG)) then
				continue
			end

			local ingredientId = child:GetAttribute("IngredientId")
			if ingredientId then
				tools[ingredientId] = child
			end
		end
	end

	return tools
end

-- An empty tagged tool carrying an ingredient's id and count; HeldItem and the backpack slot draw off these.
function IngredientManager:_buildTool(ingredient: Ingredients.Ingredient, count: number): Tool
	local tool = ToolTemplate:Clone()

	tool.Name = ingredient.Name
	tool.TextureId = ingredient.Icon
	tool.ToolTip = GuiUtil.Colorize(ingredient.Name, ingredient.Color)
	tool:SetAttribute("IngredientId", ingredient.Id)
	tool:SetAttribute("Count", count)

	-- Tag last, against a fully assembled tool
	tool:AddTag(TOOL_TAG)
	tool:AddTag(HELD_TAG)
	return tool
end

-- Brings the player's ingredient tools in line with the ingredients they own.
function IngredientManager:_reconcileTools(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or not player:IsDescendantOf(Players) then
		return
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end

	local owned = data.Ingredients
	local existing = getIngredientTools(player)

	-- Drop the tools for anything they've run out of
	for ingredientId, tool in existing do
		if (owned[ingredientId] or 0) <= 0 then
			tool:Destroy()
		end
	end

	for ingredientId, count in owned do
		if count <= 0 then
			continue
		end

		-- Buying the same ingredient again stacks onto the tool that's already there
		local tool = existing[ingredientId]
		if tool then
			tool:SetAttribute("Count", count)
		else
			-- Data can hold an id the config no longer has, removed outright or dropped at load
			local ingredient = Ingredients.GetIngredientFromId(ingredientId)
			if not ingredient then
				continue
			end

			tool = self:_buildTool(ingredient, count)
			tool.Parent = backpack
		end

		-- The ingredient the player just took goes straight into their hands
		if self._pendingEquips[player] == ingredientId then
			self._pendingEquips[player] = nil
			equipTool(player, tool)
		end
	end
end

-- Adds to the player's owned count and records the obtain in their index. Returns whether it was their first.
function IngredientManager:GrantIngredient(player: Player, ingredientId: string, amount: number?): boolean
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return false
	end

	-- Flagged before the write, since that's what runs the reconcile that builds the tool to equip
	self._pendingEquips[player] = ingredientId

	local owned = data.Ingredients[ingredientId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "Ingredients", ingredientId }, owned + (amount or 1))
	return IndexManager:RecordIngredientObtained(player, ingredientId, amount)
end

-- Takes from the player's owned ingredients; the reconcile turns it into a lower Count or a destroyed tool.
function IngredientManager:ConsumeIngredient(player: Player, ingredientId: string, amount: number?)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local owned = data.Ingredients[ingredientId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "Ingredients", ingredientId }, math.max(0, owned - (amount or 1)))
end

function IngredientManager:_setupPlayer(player: Player)
	-- The signal only reports the top-level key, but the reconcile re-diffs everything anyway
	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "Ingredients", function()
		self:_reconcileTools(player)
	end)

	-- Every respawn clears the backpack and runtime tools aren't in StarterGear, so they're rebuilt
	player.CharacterAdded:Connect(function()
		self:_reconcileTools(player)
	end)

	self:_reconcileTools(player)
end

function IngredientManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	IndexManager = require(script.Parent.IndexManager)
end

function IngredientManager:OnStart()
	Players.PlayerAdded:Connect(function(player: Player)
		self:_setupPlayer(player)
	end)

	-- Reconciling yields on the player's data, so sweep existing players off the main thread
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_setupPlayer(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		local listener = self._listeners[player]
		if listener then
			listener:Disconnect()
			self._listeners[player] = nil
		end

		self._pendingEquips[player] = nil
	end)
end

return IngredientManager
