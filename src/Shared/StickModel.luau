--[[
    Everything a filled skewer is, derived from its record: the model it's shown as, and what it's
    worth.

    The single builder behind every place a filled skewer is shown as a model -- the static one on a
    griller (StickManager.BuildPlacedStickModel) and the one carried above a player's head (the
    HeldItem component). Ingredient placement is StickIngredients' maths, seated relative to the stick
    model's own pivot, so the skewer looks identical however it's shown.

    Returns the composite unanchored and unwelded: each caller settles the parts itself (anchor it for
    a static display, or weld it rigid and hang it off the character).

    The value side (GetSellValue, GetEstimatedValue) lives here too, since this is the module that
    already owns StickRecord and every config it prices off -- ingredients, the stick itself, sauce and
    cook state.
]]

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

-- The scale a built skewer is shown at wherever it's displayed small -- on the sell stand and held by a
-- customer NPC -- so the two always match.
StickModel.DISPLAY_SCALE = 0.32

export type StickRecord = {
	StickId: string,
	Ingredients: { string },
	Cooked: boolean?, -- true renders from the cooked ingredient models, false/nil from the raw ones
	-- A CookStates id, set once a cook is stopped anywhere past the raw band. Cooked says the skewer
	-- has been through a grill (which is what the sauce dispenser gates on); this says how well it
	-- went, and is what tints a burnt one and scales what it sells for. A skewer pulled off raw
	-- carries neither -- GetCookStateId is what reads the pair back as a state.
	CookState: string?,
	-- How far up the bar a pull off the raw band got, as a fraction of it, so the next light resumes
	-- from there rather than from cold. A fraction and not seconds, so it means the same thing however
	-- long the bar it resumes on runs. Only ever on a raw skewer -- any cook that gets past that band
	-- settles into CookState instead and clears this.
	CookProgress: number?,
	Sauce: string?, -- a Sauces id, whose particles ride on every ingredient of the skewer
	-- A Mutations id, stamped by the grill the skewer was cooked on rather than by anything the player
	-- did with it -- only the Golden Grill stamps one so far. Like a sauce it multiplies what the
	-- skewer sells for and puts its particles on every ingredient, and it stays on the record for good.
	Mutation: string?,
}

-- Builds the skewer model for a record: the stick cloned as the root, then each ingredient seated on
-- its StickIngredients slot relative to the stick's pivot and parented in, tagged with its skewer
-- index. Unanchored and unwelded -- the caller settles the parts. Returns nil if the stick id is gone.
function StickModel.BuildStickModel(record: StickRecord): Model?
	local stick = Sticks.GetStickFromId(record.StickId)
	if not stick then
		return nil
	end

	local model = stick.Model:Clone()
	local base = model:GetPivot()

	-- A cooked skewer shows the cooked models; a raw one the raw models.
	local function sourceModel(ingredient: Ingredients.Ingredient): Model
		return if record.Cooked then ingredient.CookedModel else ingredient.Model
	end

	-- Each ingredient's footprint, so their slots space out by the room they actually take.
	local extents = StickIngredients.ComputeExtents(record.Ingredients, record.Cooked)

	-- The run centres on the stick's middle, measured relative to the stick's pivot (the base the
	-- ingredient slots hang off), and fits within the stick's own length.
	local middleOffset = StickIngredients.GetStickMiddleOffset(model)
	local stickLength = StickIngredients.GetStickLength(model)

	-- A sauced skewer wears its sauce's particles on every ingredient. Nil for an unsauced one (and for
	-- an id the config no longer has), which just skips the parenting below.
	local sauce = record.Sauce and Sauces.GetSauceFromId(record.Sauce)

	-- Same for a mutated one, except the mutation brings a whole folder of emitters rather than a single
	-- one -- what makes a golden skewer read as golden is the flare and the sparks together.
	local mutation = record.Mutation and Mutations.GetMutationFromId(record.Mutation)

	-- A skewer left on too long wears its state rather than needing a third set of models: the cooked
	-- one, darkened. Only the states past the end of the bar carry a tint, so every skewer stopped on
	-- it skips the repaint below and keeps its models exactly as authored.
	local cookState = record.CookState and CookStates.GetStateFromId(record.CookState)
	local charred = cookState ~= nil and cookState.Tint ~= nil

	for index, ingredientId in record.Ingredients do
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)
		if not ingredient then
			continue
		end

		-- Seat the ingredient's bounding-box centre on its slot relative to the stick's pivot.
		local ingredientModel = sourceModel(ingredient):Clone()
		local center = base
			* StickIngredients.GetRestLocalCFrame(index, ingredientId, extents, middleOffset, stickLength)
		ingredientModel:PivotTo(center * StickIngredients.GetPivotToCenter(ingredientModel):Inverse())

		-- Painting the burn here is what carries it everywhere the skewer shows -- the grill, above the
		-- player's head, the sell stand, the customer's hand -- and it lands on exactly the colour the
		-- griller's cook animation was already darkening toward, so stopping a cook shows no seam.
		if charred then
			for _, descendant in ingredientModel:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.Color = CookStates.GetTintedColor(descendant.Color, record.CookState)
				end
			end
		end

		-- Tag the child with its skewer position so the griller's cook animation can pair its parts back
		-- to record.Ingredients (and the cooked models) deterministically, even with duplicate ids.
		ingredientModel:SetAttribute("SkewerIndex", index)

		-- Hang the sauce's and the mutation's emitters off the ingredient itself, so they travel with it
		-- wherever the skewer is shown -- and get destroyed with it. Ingredient models are seated by
		-- bounding box rather than pivot, so they aren't guaranteed a PrimaryPart to hang them on.
		if sauce or mutation then
			local host = ingredientModel.PrimaryPart or ingredientModel:FindFirstChildWhichIsA("BasePart", true)

			if sauce then
				sauce.Particles:Clone().Parent = host
			end

			-- The whole folder, so a mutation reads as itself rather than as one of its emitters.
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

-- The CookStates id a record resolves to. A raw skewer carries no CookState at all -- it's
-- indistinguishable from one that was never lit -- so the Cooked flag is what tells a raw one apart
-- from a cooked one saved before CookState existed. Every read of a record's quality goes through
-- here, since taking CookState at face value would price a raw skewer as though it were fine.
-- Takes just the pair rather than a whole StickRecord, so a caller holding only a tool's attributes
-- (the backpack slot's cook-state badge) doesn't have to decode an ingredient list it never reads.
function StickModel.GetCookStateId(record: { Cooked: boolean?, CookState: string? }): string
	return record.CookState or (if record.Cooked then "Cooked" else "Raw")
end

-- What a skewer is worth before any haggling: its ingredients' total price plus a slice of what the
-- stick under them cost, scaled by that stick's tier boost, by the sauce it carries, by the mutation the
-- grill it cooked on stamped on it, and by how well it was cooked. The stick's slice sits inside those
-- multipliers rather than beside them, so a skewer pulled off raw can't dodge the penalty on it. The
-- one source for both the customer's offer maths and the estimate shown on a held skewer, so what a
-- player is promised and what they're offered can't drift apart -- and the one place a raw or burnt
-- skewer's penalty has to be applied to reach either.
function StickModel.GetSellValue(record: StickRecord): number
	-- A stick dropped from the config (its model went missing) prices as contributing nothing, the same
	-- way BuildStickModel above refuses to build one.
	local stick = Sticks.GetStickFromId(record.StickId)
	local stickValue = if stick then stick.Price * Sticks.SALE_RETURN_FACTOR else 0

	return (Ingredients.GetTotalValue(record.Ingredients) + stickValue)
		* Sticks.GetValueMultiplier(record.StickId)
		* Sauces.GetMultiplier(record.Sauce)
		* Mutations.GetMultiplier(record.Mutation)
		* CookStates.GetMultiplier(StickModel.GetCookStateId(record))
end

-- The NpcDialogue variant a customer picks its lines out of for this skewer. A mutation outranks the
-- cook state -- a golden skewer is the remarkable thing about it, whatever the bar said -- and a plain
-- skewer falls back on reacting to how well it cooked. One place, so what the server sends and what the
-- dialogue config offers can't drift apart.
function StickModel.GetDialogueVariant(record: StickRecord): string
	local mutation = record.Mutation and Mutations.GetMutationFromId(record.Mutation)
	return (mutation and mutation.DialogueVariant) or StickModel.GetCookStateId(record)
end

-- The rough valuation shown over a held skewer: ESTIMATE_MIN/MAX_FACTOR of its sell value, with the
-- spot in that range folded out of the skewer's own uid rather than rolled fresh. Seeding is what
-- makes the number trustworthy -- the same skewer always estimates the same, so a player can't
-- re-equip to re-roll a nicer figure, and every client watching them lands on the identical figure
-- without the estimate itself being replicated.
--
-- `boostFraction` is the holder's currency boost (CurrencyManager.GetPlayerBoostFraction, mirrored onto
-- the player as an attribute), so the guess quotes what the sale would actually bank rather than the
-- plain worth the customer haggles over -- the sell stand's offer frame quotes the boosted figure too,
-- and an estimate on the other basis reads as a fraction of what the player is about to be paid. It
-- scales the guess and the offer by the same term, so the offer still beats the guess exactly as before.
function StickModel.GetEstimatedValue(record: StickRecord, uid: string, boostFraction: number?): number
	local seed = 5381
	for i = 1, #uid do
		seed = (seed * 33 + string.byte(uid, i)) % 2147483647
	end

	local factor = RandomUtil.GetRandomFromMinMax(SellNpc.ESTIMATE_MIN_FACTOR, SellNpc.ESTIMATE_MAX_FACTOR, seed)
	return math.round(StickModel.GetSellValue(record) * factor * (1 + (boostFraction or 0)))
end

return StickModel
