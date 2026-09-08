-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)
local Ingredients = require(Shared.Config.Ingredients)
local Rarity = require(Shared.Config.Rarity)

-- Controllers
local PlayerDataController
local UIController
local HudController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- A locked cell is blacked out behind "???"; a discovered one shows its icon, name, odds and value
local UNLOCKED_ICON_COLOR = Color3.new(1, 1, 1)
local LOCKED_ICON_COLOR = Color3.new(0, 0, 0)
local LOCKED_TEXT = "???"
local LOCKED_RARITY_COLOR = Color3.new(1, 1, 1)

-- Drives the Index screen: one cell per ingredient in config order, blacked out as "???" until it turns up in the player's replicated IngredientIndex.
local IndexController = {
	_cells = {}, -- [ingredientId] = the cloned Template frame for that ingredient
}

-- Applies the discovered or locked look to one ingredient's cell.
function IndexController:_applyCellState(ingredient: Ingredients.Ingredient, discovered: boolean)
	local cell = self._cells[ingredient.Id]

	cell.Icon.ImageColor3 = discovered and UNLOCKED_ICON_COLOR or LOCKED_ICON_COLOR
	cell.IngredientName.Text = discovered and ingredient.Name or LOCKED_TEXT
	cell.Value.Text = discovered and `${GuiUtil.ConvertNumberWithSuffix(ingredient.Price)}` or LOCKED_TEXT

	if discovered then
		local tier = ingredient.Tier

		cell.Rarity.Text = Rarity.FormatChance(ingredient.Chance)
		cell.Rarity.TextColor3 = tier.TextColor

		local stroke = cell.Rarity:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			stroke.Color = tier.StrokeColor
		end
	else
		cell.Rarity.Text = LOCKED_TEXT
		cell.Rarity.TextColor3 = LOCKED_RARITY_COLOR
	end
end

-- Writes the header's tally of how much of the roster the player has discovered.
function IndexController:_setDiscoveredCount(count: number)
	self.UI.Holder.Discovered.Text = `Discovered Ingredients: {count}/{#Ingredients.GetAllIngredients()}`
end

-- One cell per ingredient in config order, each starting locked so nothing flashes before the index reads in.
function IndexController:_buildCells()
	local scrollingFrame = self.UI.Holder.Container.ScrollingFrame
	local template = scrollingFrame.Template
	template.Parent = nil

	for order, ingredient in Ingredients.GetAllIngredients() do
		local cell = template:Clone()
		cell.Name = ingredient.Id
		cell.LayoutOrder = order
		cell.Icon.Image = ingredient.Icon

		self._cells[ingredient.Id] = cell
		self:_applyCellState(ingredient, false)

		cell.Visible = true
		cell.Parent = scrollingFrame
	end

	self:_setDiscoveredCount(0)
end

-- Re-reads the player's index, reveals every discovered ingredient's cell and retallies the header.
function IndexController:_refreshCells()
	local index = PlayerDataController:GetKey("IngredientIndex")
	local discoveredCount = 0

	for _, ingredient in Ingredients.GetAllIngredients() do
		local discovered = (index[ingredient.Id] or 0) > 0
		self:_applyCellState(ingredient, discovered)

		if discovered then
			discoveredCount += 1
		end
	end

	self:_setDiscoveredCount(discoveredCount)
end

function IndexController:OnInit()
	PlayerDataController = require(script.Parent.PlayerDataController)
	UIController = require(script.Parent.UIController)
	HudController = require(script.Parent.HudController)

	self.UI = PlayerGui:WaitForChild("IndexUI")
end

function IndexController:OnStart()
	local holder = self.UI.Holder
	holder.Visible = false

	self:_buildCells()

	-- The HUD's Index button toggles the screen open; the Exit button closes it.
	HudController:BindHudButton("Index", function()
		UIController:OpenFrame(holder)
	end)
	UIController:BindButtonClick(holder.Exit, function()
		UIController:CloseFrame(holder)
	end, true)

	-- Reveal discovered ingredients, then keep the grid in sync. Deferred: the read awaits the replica.
	task.spawn(function()
		self:_refreshCells()

		PlayerDataController:ListenForChange("IngredientIndex", function()
			self:_refreshCells()
		end)
	end)
end

return IndexController
