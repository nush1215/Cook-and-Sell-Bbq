-- Builds a skewer model from a record, and the shared reads of what one is worth: its cook state, sell value and dialogue variant.

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Sticks = require(Shared.Config.Sticks)
local Ingredients = require(Shared.Config.Ingredients)
local Sauces = require(Shared.Config.Sauces)
local Mutations = require(Shared.Config.Mutations)
local CookStates = require(Shared.Config.CookStates)
local SellNpc = require(Shared.Config.SellNpc)
local StickIngredients = require(Shared.StickIngredients)
local RandomUtil = require(Shared.RandomUtil)

--
local StickModel = {}

-- The scale a built skewer is shown at wherever it's displayed small, so the two always match
StickModel.DISPLAY_SCALE = 0.32

export type StickRecord = {
	StickId: string,
	Ingredients: { string },
	Cooked: boolean?, -- true renders from the cooked ingredient models, false/nil from the raw ones
	-- A CookStates id set past the raw band. Cooked says it went through a grill; this says how well
	CookState: string?,
	-- A raw pull's banked bar fraction, so the next light resumes there. Cleared once a cook settles
	CookProgress: number?,
	Sauce: string?, -- a Sauces id, whose particles ride on every ingredient of the skewer
	-- A Mutations id stamped by the grill it cooked on. Multiplies sell value and adds particles, for good
	Mutation: string?,
}

-- Builds a record's skewer: the stick as root, each ingredient on its slot, tagged by index. Unwelded.
function StickModel.BuildStickModel(record: StickRecord): Model?
	local stick = Sticks.GetStickFromId(record.StickId)
	if not stick then
		return nil
	end

	local model = stick.Model:Clone()
	local base = model:GetPivot()

	-- A cooked skewer shows the cooked models; a raw one the raw models
	local function sourceModel(ingredient: Ingredients.Ingredient): Model
		return if record.Cooked then ingredient.CookedModel else ingredient.Model
	end

	-- Each ingredient's footprint, so their slots space out by the room they actually take
	local extents = StickIngredients.ComputeExtents(record.Ingredients, record.Cooked)

	-- Centred on the stick's middle relative to its pivot, and fitted within the stick's own length
	local middleOffset = StickIngredients.GetStickMiddleOffset(model)
	local stickLength = StickIngredients.GetStickLength(model)

	-- Nil for an unsauced skewer, or an id the config no longer has, which skips the parenting below
	local sauce = record.Sauce and Sauces.GetSauceFromId(record.Sauce)

	-- A mutation brings a whole folder -- the flare and sparks together are what read as golden
	local mutation = record.Mutation and Mutations.GetMutationFromId(record.Mutation)

	-- Only states past the bar carry a tint, so anything stopped on it keeps its models as authored
	local cookState = record.CookState and CookStates.GetStateFromId(record.CookState)
	local charred = cookState ~= nil and cookState.Tint ~= nil

	for index, ingredientId in record.Ingredients do
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)
		if not ingredient then
			continue
		end

		-- Seat the ingredient's bounding-box centre on its slot relative to the stick's pivot
		local ingredientModel = sourceModel(ingredient):Clone()
		local center = base
			* StickIngredients.GetRestLocalCFrame(index, ingredientId, extents, middleOffset, stickLength)
		ingredientModel:PivotTo(center * StickIngredients.GetPivotToCenter(ingredientModel):Inverse())

		-- Painted here so the burn follows the skewer everywhere, landing on the colour the cook darkened toward
		if charred then
			for _, descendant in ingredientModel:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.Color = CookStates.GetTintedColor(descendant.Color, record.CookState)
				end
			end
		end

		-- Tagged by position so the cook animation can pair parts back deterministically, duplicate ids included
		ingredientModel:SetAttribute("SkewerIndex", index)

		-- On the ingredient, so they travel and die with it -- there's no guaranteed PrimaryPart to use
		if sauce or mutation then
			local host = ingredientModel.PrimaryPart or ingredientModel:FindFirstChildWhichIsA("BasePart", true)

			if sauce then
				sauce.Particles:Clone().Parent = host
			end

			-- The whole folder, so a mutation reads as itself rather than as one of its emitters
			if mutation then
				for _, emitter in mutation.Particles:GetChildren() do
					emitter:Clone().Parent = host
				end
			end
		end

		ingredientModel.Parent = model
	end

	return model
end

-- The CookStates id a record resolves to; the Cooked flag is what tells a raw skewer from a legacy cooked one.
function StickModel.GetCookStateId(record: { Cooked: boolean?, CookState: string? }): string
	return record.CookState or (if record.Cooked then "Cooked" else "Raw")
end

-- Sell value before haggling: ingredients plus a slice of the stick, scaled by tier, sauce, mutation and cook state.
function StickModel.GetSellValue(record: StickRecord): number
	-- A stick dropped from the config prices as nothing, as BuildStickModel refuses to build one
	local stick = Sticks.GetStickFromId(record.StickId)
	local stickValue = if stick then stick.Price * Sticks.SALE_RETURN_FACTOR else 0

	return (Ingredients.GetTotalValue(record.Ingredients) + stickValue)
		* Sticks.GetValueMultiplier(record.StickId)
		* Sauces.GetMultiplier(record.Sauce)
		* Mutations.GetMultiplier(record.Mutation)
		* CookStates.GetMultiplier(StickModel.GetCookStateId(record))
end

-- The dialogue variant for this skewer; a mutation outranks the cook state as the remarkable thing.
function StickModel.GetDialogueVariant(record: StickRecord): string
	local mutation = record.Mutation and Mutations.GetMutationFromId(record.Mutation)
	return (mutation and mutation.DialogueVariant) or StickModel.GetCookStateId(record)
end

-- The held-skewer estimate, seeded off the skewer's uid so it can't be re-rolled and every client agrees. `boostFraction` quotes what the sale would bank.
function StickModel.GetEstimatedValue(record: StickRecord, uid: string, boostFraction: number?): number
	local seed = 5381
	for i = 1, #uid do
		seed = (seed * 33 + string.byte(uid, i)) % 2147483647
	end

	local factor = RandomUtil.GetRandomFromMinMax(SellNpc.ESTIMATE_MIN_FACTOR, SellNpc.ESTIMATE_MAX_FACTOR, seed)
	return math.round(StickModel.GetSellValue(record) * factor * (1 + (boostFraction or 0)))
end

return StickModel
