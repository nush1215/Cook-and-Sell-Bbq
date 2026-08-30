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

--[[
	Draws the visual for any held tool -- a plain stick, a filled skewer, a single ingredient or an
	unopened crate -- welded above the player's head, and plays the overhead Hold pose.

	Ancestors = { workspace } ties it to equip state: a tool in the Backpack isn't under workspace, so
	this is dormant; equipping reparents the tool into the Character (under workspace) and Start
	fires, unequipping reparents it back and Stop fires. The visual is built off the tool's own
	attributes, so every client draws it (not just the owner) and the owner also plays the animation.

	Built in Start rather than Construct, like every component here that owns something: the framework
	only runs Stop for a component that reached Start, so anything made in Construct is stranded if the
	tool is gone again before Start's deferred hop -- an equip/unequip inside one frame would leave the
	welded model and the Hold pose behind for good.
]]

--
local HOLD_ANIMATION = "Hold"
-- How far above the root the carried item's underside sits. The Hold pose is arms-up/overhead, so the
-- item rides above the head; the lift then scales with the model's own size (below) so items of any
-- size clear the head by this same margin. Tune in Studio to match the pose.
local HOLD_BASE_HEIGHT = 2.7
-- Gap between the top of the carried item and the underside of its billboard.
local INFO_UI_HEIGHT_MARGIN = 0.25

--
local HeldItem = Component.new({
	Tag = script.Name,
	Ancestors = { workspace },
})

-- Resolves the display model for a held tool from its attributes: a filled skewer rebuilt via the
-- shared StickModel, or a plain stick / single ingredient / crate cloned straight from config. Every
-- client runs this off the replicated tool, so the whole visual comes from the tool's own attributes.
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

	-- Weld the model rigid internally, seat its bounding-box centre above the head, then weld to the
	-- root. Part0 is the model's PrimaryPart so the WeldConstraint lives on the model and is destroyed
	-- with it on Stop. Seating on the bounding-box centre means the offset places sticks, skewers and
	-- ingredients alike, whatever their authored pivots.
	GlobalUtil.WeldModel(model, false)

	-- Lift by half the model's extent on top of the base height, so a big skewer floats higher than a
	-- lone ingredient and both clear the head by the same margin.
	local extent = StickIngredients.GetMaxExtent(model)
	local holdOffset = CFrame.new(0, HOLD_BASE_HEIGHT + extent / 2, 0)
	model:PivotTo(root.CFrame * holdOffset * StickIngredients.GetPivotToCenter(model):Inverse())

	GlobalUtil.Weld(model.PrimaryPart, character.Head)

	-- Render-only so the carried item doesn't collide or get raycast against.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.Massless = true
			descendant.CanQuery = false
		end
	end

	model.Parent = workspace

	-- Only a cooked skewer gets a value readout -- a bare stick or a loose ingredient has no record to
	-- price, and a raw one isn't finished yet, so quoting a figure for it would just read as what it's
	-- worth rather than as what it's worth unfinished. Cooked is the "has been through a grill" flag, so
	-- it covers a burnt skewer too; a skewer pulled off raw carries neither it nor CookState and is
	-- indistinguishable from one that was never lit. Every client draws it off the tool's own attributes
	-- plus the holder's replicated boost, and the estimate is seeded by the uid rather than rolled, so
	-- everyone watching one skewer lands on the same figure.
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

		-- The root is the anchor, since it's what the skewer's own height was measured off above -- so
		-- the billboard rides along without depending on the model's authored pivot. It needs the
		-- cleaner explicitly, not being a descendant of the model that gets dropped on unequip.
		local valueUI = UI.EstimatedValueAttachment:Clone()

		-- The guess quotes what the sale would bank rather than the skewer's plain worth, so it carries
		-- the holder's boosts -- the same figure the sell stand's offer frame is on. Redrawn rather than
		-- set once, since a boost can land mid-hold: a friend joining, a gamepass finishing its check, or
		-- EarlyBoost decaying on the sale before this one.
		local function drawEstimate()
			local boostFraction = holder:GetAttribute("BoostFraction") or 0
			local estimate = StickModel.GetEstimatedValue(record, uid, boostFraction)
			valueUI.UI.Value.Text = `${GuiUtil.ConvertNumberWithSuffix(estimate)}`
		end

		drawEstimate()
		self._cleaner:Add(holder:GetAttributeChangedSignal("BoostFraction"):Connect(drawEstimate))

		-- The state is read the same way the sell price reads it, so the figure and the badge under it
		-- are always saying the same thing -- including on a skewer saved before cook states existed,
		-- which resolves to Cooked rather than reading blank.
		local stateId = StickModel.GetCookStateId(record)
		valueUI.UI.CookStateIcon.Image = CookStates.GetStateFromId(stateId).Icon

		valueUI.Parent = character.Head
		self._cleaner:Add(valueUI)
	end

	-- Its own template, mirroring the billboard a rolling stand puts over what it landed on, so an
	-- ingredient in hand reads the way it read on the stand it came off. Every client draws it off the
	-- tool's replicated IngredientId, like the rest of the visual. buildModel already resolved the id.
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

		-- Hung off the PrimaryPart rather than the model: a stand's result sits still, but this one is
		-- welded to the head and has to ride along. Seated over the same bounding box the hold offset
		-- above seats on, so an ingredient of any size clears by this same margin. No cleaner entry
		-- needed, being a descendant of the model that's already on it.
		local boundingCFrame, boundingSize = model:GetBoundingBox()
		info.CFrame = model.PrimaryPart.CFrame:ToObjectSpace(
			boundingCFrame * CFrame.new(0, boundingSize.Y / 2 + INFO_UI_HEIGHT_MARGIN, 0)
		)
		info.Parent = model.PrimaryPart
	end

	-- Hide the hand handle so only the carried visual shows.
	local handle = tool:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		handle.Transparency = 1
		handle.CanCollide = false
	end

	-- Only the owning client plays the hold animation; it replicates to others.
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
