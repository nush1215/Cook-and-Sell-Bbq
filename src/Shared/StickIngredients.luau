--[[
    Where ingredients sit on a stick.

    The single source of ingredient placement, so a stick's ingredients land in the exact same spots
    whether the stick is sitting on a stand (rendered client-side onto the StickAttachment) or welded
    onto a held tool (built server-side onto the Handle). Positions are in the stick base's local
    space -- "base" being the StickAttachment on a stand or the tool's Handle -- so both callers just
    multiply by their own base CFrame.

    Orientation is seeded off the ingredient's id and index together, so it varies both by which
    ingredient it is and where it sits down the skewer -- and is still reproducible on both sides
    without storing any rotation in player data. The room an ingredient reserves is measured in that
    same seeded pose (rotationFor feeds both stackExtentFor and GetRestLocalCFrame), so how much space
    it's given and how it's actually turned can't drift apart.

    The run stays centred on the middle of the stick (GetStickMiddleOffset), so adding an ingredient
    re-centres the whole block: the ones already on the stick shift to make room rather than the new one
    just stacking on the end.

    The run also fits the stick's own physical length (GetStickLength): while PADDING is positive the
    padding between neighbours shrinks first, and only once they're already touching edge-to-edge does
    the run start overlapping ingredients (proportional to their own size) rather than hang off either
    end of the stick model.
]]

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)

--
local StickIngredients = {}

-- Editable placement, all in the stick base's local space. Flip STACK_DIRECTION / swap its axis
-- in-game if the skewer points a different way.
StickIngredients.STACK_DIRECTION = Vector3.new(0, 1, 0) -- which way ingredients stack along the stick
StickIngredients.PADDING = -1.2 -- extra gap between neighbours on top of their extents (negative tightens)
StickIngredients.SPAWN_RISE = 6 -- studs along the stack direction a dropped ingredient starts from
StickIngredients.SPAWN_SPIN = math.pi -- extra spin at the drop start, unwound on the way down
-- Max random pitch/roll off the skewer, so ingredients don't all sit the same way. Pitch and roll are
-- rolled separately and compose, so the total lean off the skewer runs up to 2x this. Doubles as a
-- spacing knob: a leaning ingredient reserves less room along the skewer (see stackExtentFor), so more
-- tilt reads as a tighter stack.
StickIngredients.TILT = math.rad(50)

-- A stable orientation seed for ingredient `index`: its id folded together with its position, so the
-- same ingredient rotates differently at a different spot and a given spot rotates differently for a
-- different ingredient -- which stops a row of skewers reading as identical clones. Purely a function
-- of shared data (id + index), so every client and both render paths still agree without any rotation
-- being stored.
local function orientationSeed(index: number, ingredientId: string): number
	local hash = 5381
	for i = 1, #ingredientId do
		hash = (hash * 33 + string.byte(ingredientId, i)) % 2147483647
	end
	return (hash * 33 + index) % 2147483647
end

-- The random-but-reproducible pose of ingredient `index`: a full spin about the skewer itself, then a
-- bounded tilt off it. Spinning about STACK_DIRECTION rather than a fixed world axis is what keeps this
-- right whichever way the skewer points -- and it drops straight out of stackExtentFor, since spinning
-- a shape about an axis can't change how far it reaches along that axis. The one place the pose is
-- decided: stackExtentFor measures the room for exactly the rotation GetRestLocalCFrame places with.
local function rotationFor(index: number, ingredientId: string): CFrame
	local direction = StickIngredients.STACK_DIRECTION.Unit

	local rng = Random.new(orientationSeed(index, ingredientId))
	local spin = rng:NextNumber(0, math.pi * 2)
	local pitch = rng:NextNumber(-StickIngredients.TILT, StickIngredients.TILT)
	local roll = rng:NextNumber(-StickIngredients.TILT, StickIngredients.TILT)

	-- Two axes across the skewer for the tilt to lean about, so pitch/roll always lean the ingredient off
	-- the stick rather than spinning it along it. The reference axis only exists to avoid a zero-length
	-- cross product when the skewer already points along Y.
	local reference = if math.abs(direction.Y) < 0.99 then Vector3.yAxis else Vector3.xAxis
	local pitchAxis = direction:Cross(reference).Unit
	local rollAxis = direction:Cross(pitchAxis)

	return CFrame.fromAxisAngle(direction, spin)
		* CFrame.fromAxisAngle(pitchAxis, pitch)
		* CFrame.fromAxisAngle(rollAxis, roll)
end

-- How much room ingredient `index` takes along the skewer, in the pose it's actually placed at
-- (rotationFor) rather than upright -- an ingredient leaning across the skewer eats less of its length
-- than the same one standing along it. The ingredient is treated as the ellipsoid inscribed in its
-- bounding box, whose reach along a direction is sqrt of the summed squared axes, since ingredients are
-- rounded food rather than actual boxes: projecting the box itself would reserve up to 1.73x an
-- ingredient's own size for the empty corners on a diagonal tilt.
--
-- Measuring off the bounding box is only sound because callers seat each ingredient's bounding-box
-- centre on its slot (GetPivotToCenter), which makes the box's own axes exactly rotationFor's and its
-- reach symmetric about the slot -- which is what fitToLength/offsetFor's half-extent maths assumes.
local function stackExtentFor(model: Model, index: number, ingredientId: string): number
	local _, size = model:GetBoundingBox()
	local axis = rotationFor(index, ingredientId):VectorToObjectSpace(StickIngredients.STACK_DIRECTION.Unit)

	return math.sqrt((size.X * axis.X) ^ 2 + (size.Y * axis.Y) ^ 2 + (size.Z * axis.Z) ^ 2)
end

-- Every ingredient's footprint along the skewer, in list order, so placement spaces them by the room
-- they actually take. The only way to build the list GetRestLocalCFrame wants: an extent is tied to the
-- (index, id) pair whose pose it was measured in, so building one by hand risks reserving room for one
-- pose and placing another. `cooked` picks the cooked models over the raw ones, matching how the caller
-- clones them. An id the config no longer has contributes 0, keeping indices lined up with the list.
function StickIngredients.ComputeExtents(ingredientIds: { string }, cooked: boolean?): { number }
	local extents = {}
	for index, ingredientId in ingredientIds do
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)
		local model = ingredient and (if cooked then ingredient.CookedModel else ingredient.Model)
		extents[index] = if model then stackExtentFor(model, index, ingredientId) else 0
	end

	return extents
end

-- A model's biggest dimension, ignoring how it's turned: how much space it needs at worst, whichever way
-- it ends up facing. Deliberately not the axial extent above -- this is for callers that just want "how
-- big is this thing" (the lift a held item needs to clear the head), not how much of a skewer it eats.
function StickIngredients.GetMaxExtent(model: Model): number
	local _, size = model:GetBoundingBox()
	return math.max(size.X, size.Y, size.Z)
end

-- The offset from a stick's authored pivot to the middle of its length along the stack direction. The
-- stick's pivot is authored on the grip and every caller seats the stick there (the stand attachment,
-- the tool Handle), so this is what the ingredient run hangs off. Only the axial component is kept, so
-- lateral bounding-box slop can't push ingredients off the skewer line.
function StickIngredients.GetStickMiddleOffset(stickModel: Model): Vector3
	local boundingCFrame = stickModel:GetBoundingBox()
	local localCentre = stickModel:GetPivot():Inverse() * boundingCFrame.Position
	local direction = StickIngredients.STACK_DIRECTION.Unit
	return direction * localCentre:Dot(direction)
end

-- The stick's own physical length along the stack direction, so fitToLength has something to fit the
-- ingredient run into. Unlike GetStickMiddleOffset (which only ever reads the bounding box's
-- position), this reads its size, so it assumes the bounding box's axes line up with the pivot's --
-- true for a normally-modelled, normally-pivoted stick, but not guaranteed if a stick's pivot is
-- rotated relative to its own mesh. Good enough here: a mismatch just biases how the run degrades
-- under crowding.
function StickIngredients.GetStickLength(stickModel: Model): number
	local _, size = stickModel:GetBoundingBox()
	local direction = StickIngredients.STACK_DIRECTION.Unit
	return math.abs(size:Dot(direction))
end

-- How to fit the ingredient run into the stick's own length: shrink the padding between neighbours
-- toward zero first (same spacing feel, just tighter), and only once they're already touching
-- edge-to-edge does the run start overlapping ingredients (scaled down proportional to their own size)
-- rather than hang off either end of the stick model. Returns (padding, scale) for offsetFor's
-- per-neighbour gap: scale * (extents[i-1]+extents[i])/2 + padding. A single ingredient always sits
-- exactly on the anchor regardless (offsetFor never uses padding/scale when there's nothing to space
-- it against), so this returns early for #extents <= 1 -- also dodging a divide-by-zero below, since
-- gaps would be 0.
--
-- Note the padding-shrinking middle stage only ever runs while PADDING is positive: if the full padding
-- doesn't fit then touchingSpan > stickLength - gaps * PADDING >= stickLength, so the touching case
-- can't fit either. With PADDING negative an overcrowded stick jumps straight to overlap-scaling.
local function fitToLength(extents: { number }, stickLength: number): (number, number)
	if #extents <= 1 then
		return StickIngredients.PADDING, 1
	end

	local touchingSpan = 0
	for _, extent in extents do
		touchingSpan += extent
	end
	local gaps = #extents - 1

	-- Fits with the full padding: unchanged from before.
	if touchingSpan + gaps * StickIngredients.PADDING <= stickLength then
		return StickIngredients.PADDING, 1
	end

	-- Doesn't fit with full padding, but fits once neighbours just touch -- shrink padding down to
	-- exactly what's left, no further.
	if touchingSpan <= stickLength then
		return (stickLength - touchingSpan) / gaps, 1
	end

	-- Overflows even touching edge-to-edge -- scale the gap between centres down so ingredients overlap
	-- instead of hanging off the ends. The first and last ingredient's own half-widths (endHalf) sit
	-- outside every scaled gap, so they're subtracted from both sides before scaling and added back
	-- after, or the run would still overshoot by however much of them isn't compressed.
	local endHalf = (extents[1] + extents[#extents]) / 2
	local scale = (stickLength - endHalf) / (touchingSpan - endHalf)
	return 0, math.max(scale, 0)
end

-- The centre offset of ingredient `index`, laid out so the whole run stays centred on the stick's
-- middle (anchorOffset): each neighbour is spaced by half of each of their extents, scaled by `scale`,
-- plus `padding` (bigger ingredients push the next further along), then the run is shifted so its span
-- is centred on the anchor. `padding`/`scale` come from fitToLength, so a run that doesn't fit the
-- stick shrinks its gaps before it starts overlapping ingredients. Adding an ingredient re-centres the
-- run, nudging the existing ones.
local function offsetFor(
	index: number,
	extents: { number },
	anchorOffset: Vector3,
	padding: number,
	scale: number
): Vector3
	local direction = StickIngredients.STACK_DIRECTION.Unit

	-- Cumulative centre of `index` from the first ingredient, then carried on to the last to get the
	-- run's full length (reuses the partial sum).
	local position = 0
	for i = 2, index do
		position += scale * (extents[i - 1] + extents[i]) / 2 + padding
	end
	local runLength = position
	for i = index + 1, #extents do
		runLength += scale * (extents[i - 1] + extents[i]) / 2 + padding
	end

	-- Centre the visible span on the anchor: half-way between the first ingredient's bottom edge
	-- (-extents[1]/2) and the last's top edge (runLength + extents[#extents]/2). These two edges are
	-- never scaled -- only the gaps between centres are -- since scale compresses spacing, not the
	-- ingredients themselves.
	local spanCentre = (runLength + extents[#extents] / 2 - extents[1] / 2) / 2
	return anchorOffset + direction * (position - spanCentre)
end

-- The resting pose of ingredient `index` (1-based) relative to the stick base. `extents` is the list
-- from ComputeExtents, so spacing tracks the room each ingredient takes in the very pose this places it
-- at; `anchorOffset` is the stick's middle (GetStickMiddleOffset) the run centres on; `stickLength` is
-- the stick's own length (GetStickLength), so the run fits it (fitToLength) instead of just growing with
-- the ingredient count regardless of the stick's own size. Orientation comes from rotationFor -- the
-- same function the extents were measured through, and seeded by the ingredient's id and index, so it's
-- varied yet reproducible: the stand render and the welded tool match without any rotation being stored.
--
-- Callers must seat the ingredient's bounding-box centre (GetPivotToCenter) on this, not its authored
-- pivot, or the spacing stops lining up with where the ingredient actually sits.
function StickIngredients.GetRestLocalCFrame(
	index: number,
	ingredientId: string,
	extents: { number },
	anchorOffset: Vector3,
	stickLength: number
): CFrame
	local padding, scale = fitToLength(extents, stickLength)
	return CFrame.new(offsetFor(index, extents, anchorOffset, padding, scale)) * rotationFor(index, ingredientId)
end

-- Where a dropped ingredient starts before it springs into its rest pose: offset along the stack
-- direction and pre-spun, so it visibly travels in and unwinds. SPAWN_SPIN is applied in the
-- ingredient's own frame on top of its rest pose, so it never touches the room it reserves.
-- `stickLength` just forwards to GetRestLocalCFrame.
function StickIngredients.GetSpawnLocalCFrame(
	index: number,
	ingredientId: string,
	extents: { number },
	anchorOffset: Vector3,
	stickLength: number
): CFrame
	local rest = StickIngredients.GetRestLocalCFrame(index, ingredientId, extents, anchorOffset, stickLength)
	return (rest + StickIngredients.STACK_DIRECTION.Unit * StickIngredients.SPAWN_RISE)
		* CFrame.Angles(0, StickIngredients.SPAWN_SPIN, 0)
end

-- The transform from a model's authored pivot to its bounding-box centre, so a caller can seat the
-- centre (not the arbitrary authored pivot) on a slot: pivot the model to `slotCFrame * this:Inverse()`.
-- Mirrors IngredientManager's recentre. Compute it once, before moving the model.
function StickIngredients.GetPivotToCenter(model: Model): CFrame
	local boundingCFrame = model:GetBoundingBox()
	return model:GetPivot():Inverse() * boundingCFrame
end

return StickIngredients
