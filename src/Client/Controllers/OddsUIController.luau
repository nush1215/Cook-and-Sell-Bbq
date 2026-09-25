-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)

-- Controllers
local UIController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- Drives the odds panel: one entry per ingredient a paid roll can land, with the odds Roblox requires shown before purchase.
local OddsUIController = {
	-- Owns the entries cloned for the pool on show, so a repopulate clears the old ones in one call
	_entriesTrove = nil,
}

-- Fills the panel from an ingredient pool, replacing whatever it showed. Odds are out of the pool's actual total, so they stay true if the chances drift off 100.
function OddsUIController:PopulateIngredientOdds(pool: { { Id: string, Chance: number } })
	self._entriesTrove:Clean()

	local scrollingFrame = self.UI.Holder.Container.ScrollingFrame
	local template = scrollingFrame.Template

	local total = 0
	for _, entry in pool do
		total += entry.Chance
	end

	-- Commonest tier first, and the likeliest first within it; equal odds fall back to the cheaper, since table.sort isn't stable
	local sorted = table.clone(pool)
	table.sort(sorted, function(a, b)
		local aIngredient = Ingredients.GetIngredientFromId(a.Id)
		local bIngredient = Ingredients.GetIngredientFromId(b.Id)

		if aIngredient.Tier.Index ~= bIngredient.Tier.Index then
			return aIngredient.Tier.Index < bIngredient.Tier.Index
		end

		if a.Chance ~= b.Chance then
			return a.Chance > b.Chance
		end

		return aIngredient.Price < bIngredient.Price
	end)

	for order, entry in sorted do
		local ingredient = Ingredients.GetIngredientFromId(entry.Id)
		local percent = entry.Chance / total * 100

		local slot = template:Clone()
		slot.Name = entry.Id
		slot.LayoutOrder = order
		slot.Icon.Image = ingredient.Icon
		slot.IngredientName.Text = ingredient.Name
		slot.Rarity.Text = ingredient.Tier.Id
		slot.Rarity.TextColor3 = ingredient.Tier.TextColor

		-- Two decimals covers anything authored here; under 0.01% keeps two significant figures rather than reading 0%
		slot.Odds.Text = if percent >= 0.01
			then string.format("%g%%", math.round(percent * 100) / 100)
			else string.format("%.2g%%", percent)

		slot.Visible = true
		slot.Parent = scrollingFrame

		self._entriesTrove:Add(slot)
	end
end

-- Opens the odds panel, closing whatever other panel is up.
function OddsUIController:OpenOdds()
	UIController:OpenFrame(self.UI.Holder)
end

function OddsUIController:OnInit()
	UIController = require(script.Parent.UIController)

	self.UI = PlayerGui:WaitForChild("OddsUI")
	self._entriesTrove = Trove.new()
end

function OddsUIController:OnStart()
	local holder = self.UI.Holder
	holder.Visible = false
	holder.Container.ScrollingFrame.Template.Visible = false

	UIController:BindButtonClick(holder.Exit, function()
		UIController:CloseFrame(holder)
	end, true)
end

return OddsUIController
