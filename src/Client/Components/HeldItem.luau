-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local GlobalUtil = require(Shared.GlobalUtil)
local GuiUtil = require(Shared.GuiUtil)
local StickModel = require(Shared.StickModel)
local StickIngredients = require(Shared.StickIngredients)
local Sticks = require(Shared.Config.Sticks)
local Ingredients = require(Shared.Config.Ingredients)
local Crates = require(Shared.Config.Crates)
local CookStates = require(Shared.Config.CookStates)
local Rarity = require(Shared.Config.Rarity)

-- Controllers
local AnimationController = require(script.Parent.Parent.Controllers.AnimationController)

-- Assets
local UI = ReplicatedStorage.Assets.UI

-- Draws any held tool's visual above the player's head off the tool's own attributes, so every client sees it. Built in Start, since only a component that reached Start gets a Stop.

--
local HOLD_ANIMATION = "Hold"
-- How far above the root the item's underside sits; the lift scales with the model, so any size clears by this margin
local HOLD_BASE_HEIGHT = 2.7
-- Gap between the top of the carried item and the underside of its billboard.
local INFO_UI_HEIGHT_MARGIN = 0.25

--
local HeldItem = Component.new({
	Tag = script.Name,
	Ancestors = { workspace },
})

-- Resolves a held tool's display model from its attributes, so every client draws the same visual.
local function buildModel(tool: Tool): Model?
	if tool:GetAttribute("FilledStickUid") then
		return StickModel.BuildStickModel({
			StickId = tool:GetAttribute("StickId"),
			Ingredients = HttpService:JSONDecode(tool:GetAttribute("Ingredients")),
			Cooked = tool:GetAttribute("Cooked"),
			CookState = tool:GetAttribute("CookState"),
			Sauce = tool:GetAttribute("Sauce"),
			Mutation = tool:GetAttribute("Mutation"),
		})
	end

	local ingredientId = tool:GetAttribute("IngredientId")
	if ingredientId then
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)
		return ingredient and ingredient.Model:Clone()
	end

	local crateId = tool:GetAttribute("CrateId")
	if crateId then
		local crate = Crates.GetCrateFromId(crateId)
		return crate and crate.Model:Clone()
	end

	local stick = Sticks.GetStickFromId(tool:GetAttribute("StickId"))
	return stick and stick.Model:Clone()
end

-- Builds the carried visual, welded above the character's head.
function HeldItem:Start()
	local tool = self.Instance

	local character = tool.Parent
	if not character or not character:IsA("Model") then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local model = buildModel(tool)
	if not model then
		return
	end

	self._cleaner = Trove.new()
	self._cleaner:Add(model)

	-- Welded via the PrimaryPart so it dies with the model, and seated on the bounding-box centre so authored pivots don't matter
	GlobalUtil.WeldModel(model, false)

	-- Lifted by half the model's extent, so a big skewer and a lone ingredient clear the head alike
	local extent = StickIngredients.GetMaxExtent(model)
	local holdOffset = CFrame.new(0, HOLD_BASE_HEIGHT + extent / 2, 0)
	model:PivotTo(root.CFrame * holdOffset * StickIngredients.GetPivotToCenter(model):Inverse())

	GlobalUtil.Weld(model.PrimaryPart, character.Head)

	-- Render-only, so the carried item doesn't collide or get raycast against
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.Massless = true
			descendant.CanQuery = false
		end
	end

	model.Parent = workspace

	-- Only a cooked skewer gets a value readout; a raw pull carries no flag and reads as never lit. Seeded by uid, so every watcher lands on the same figure
	local holder = Players:GetPlayerFromCharacter(character)
	local uid = tool:GetAttribute("FilledStickUid")
	local cooked = tool:GetAttribute("Cooked")
	if uid and cooked then
		local record = {
			StickId = tool:GetAttribute("StickId"),
			Ingredients = HttpService:JSONDecode(tool:GetAttribute("Ingredients")),
			Cooked = cooked,
			CookState = tool:GetAttribute("CookState"),
			Sauce = tool:GetAttribute("Sauce"),
			Mutation = tool:GetAttribute("Mutation"),
		}

		-- The root is the anchor the height was measured off. Needs the cleaner explicitly, not being under the model
		local valueUI = UI.EstimatedValueAttachment:Clone()

		-- Quotes what the sale would bank, boosts included, and is redrawn since a boost can land mid-hold
		local function drawEstimate()
			local boostFraction = holder:GetAttribute("BoostFraction") or 0
			local estimate = StickModel.GetEstimatedValue(record, uid, boostFraction)
			valueUI.UI.Value.Text = `${GuiUtil.ConvertNumberWithSuffix(estimate)}`
		end

		drawEstimate()
		self._cleaner:Add(holder:GetAttributeChangedSignal("BoostFraction"):Connect(drawEstimate))

		-- Read the way the sell price reads it, so the figure and the badge always agree
		local stateId = StickModel.GetCookStateId(record)
		valueUI.UI.CookStateIcon.Image = CookStates.GetStateFromId(stateId).Icon

		valueUI.Parent = character.Head
		self._cleaner:Add(valueUI)
	end

	-- Its own template, mirroring a rolling stand's, so an ingredient reads the same in hand as on the stand
	local ingredientId = tool:GetAttribute("IngredientId")
	if ingredientId then
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)
		local tier = ingredient.Tier

		local info = UI.EquippedIngredientInfo:Clone()
		local billboard = info.UI

		billboard.IngredientName.Text = ingredient.Name
		billboard.Rarity.Text = Rarity.FormatChance(ingredient.Chance)
		billboard.Price.Text = `${GuiUtil.ConvertNumberWithSuffix(ingredient.Price)}`

		billboard.Rarity.TextColor3 = tier.TextColor

		local stroke = billboard.Rarity:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			stroke.Color = tier.StrokeColor
		end

		-- On the PrimaryPart, since this one rides a welded head. Seated over the same box the hold offset uses
		local boundingCFrame, boundingSize = model:GetBoundingBox()
		info.CFrame = model.PrimaryPart.CFrame:ToObjectSpace(
			boundingCFrame * CFrame.new(0, boundingSize.Y / 2 + INFO_UI_HEIGHT_MARGIN, 0)
		)
		info.Parent = model.PrimaryPart
	end

	-- Hide the hand handle so only the carried visual shows
	local handle = tool:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		handle.Transparency = 1
		handle.CanCollide = false
	end

	-- Only the owning client plays the hold animation; it replicates to others
	if holder == Players.LocalPlayer then
		AnimationController:PlayAnimation(HOLD_ANIMATION)
		self._playingAnimation = true
	end
end

function HeldItem:Stop()
	if self._cleaner then
		self._cleaner:Destroy()
		self._cleaner = nil
	end

	if self._playingAnimation then
		AnimationController:StopAnimation(HOLD_ANIMATION)
		self._playingAnimation = nil
	end
end

return HeldItem
