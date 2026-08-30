--[[
    Where ingredients sit on a stick -- the single source of placement, so they land identically whether
    rendered onto a stand's StickAttachment client-side or welded onto a tool's Handle server-side.
    Positions are in the base's local space, so both callers just multiply by their own base CFrame.

    Orientation is seeded off the ingredient's id and index together, so it varies by both and stays
    reproducible on both sides without storing any rotation. rotationFor feeds stackExtentFor *and*
    GetRestLocalCFrame, so the room an ingredient is given and how it's turned can't drift apart.

    The run stays centred on the stick (GetStickMiddleOffset) and fits its physical length
    (GetStickLength): padding shrinks first, and only once neighbours touch does the run start
    overlapping them -- rather than hanging off either end.
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
-- Max random pitch/roll off the skewer. The two are rolled separately and compose, so the total lean
-- reaches 2x this. Doubles as a spacing knob -- a leaning ingredient reserves less room (stackExtentFor).
StickIngredients.TILT = math.rad(50)

-- A stable orientation seed: the id folded with the index, so the same ingredient turns differently at a
-- different spot and vice versa -- which stops a row of skewers reading as clones. Purely a function of
-- shared data, so both render paths agree without any rotation being stored.
local function orientationSeed(index: number, ingredientId: string): number
	local hash = 5381
	for i = 1, #ingredientId do
		hash = (hash * 33 + string.byte(ingredientId, i)) % 2147483647
	end
	return (hash * 33 + index) % 2147483647
end

-- The reproducible pose of ingredient `index`: a full spin about the skewer, then a bounded tilt off it.
-- Spinning about STACK_DIRECTION rather than a world axis keeps this right whichever way the skewer
-- points, and drops out of stackExtentFor entirely -- spinning about an axis can't change reach along it.
-- The one place a pose is decided, so the room measured and the rotation placed are the same.
local function rotationFor(index: number, ingredientId: string): CFrame
	local direction = StickIngredients.STACK_DIRECTION.Unit

	local rng = Random.new(orientationSeed(index, ingredientId))
	local spin = rng:NextNumber(0, math.pi * 2)
	local pitch = rng:NextNumber(-StickIngredients.TILT, StickIngredients.TILT)
	local roll = rng:NextNumber(-StickIngredients.TILT, StickIngredients.TILT)

	-- Two axes across the skewer, so pitch/roll lean the ingredient off the stick rather than spinning it
	-- along it. The reference axis only avoids a zero-length cross product when the skewer points along Y.
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

-- Every ingredient's footprint along the skewer, in list order. The only supported way to build the list
-- GetRestLocalCFrame wants: an extent is tied to the (index, id) pair whose pose it was measured in, so a
-- hand-built one risks reserving room for one pose and placing another. An unknown id contributes 0,
-- keeping indices lined up.
function StickIngredients.ComputeExtents(ingredientIds: { string }, cooked: boolean?): { number }
	local extents = {}
	for index, ingredientId in ingredientIds do
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)
		local model = ingredient and (if cooked then ingredient.CookedModel else ingredient.Model)
		extents[index] = if model then stackExtentFor(model, index, ingredientId) else 0
	end

	return extents
end

-- A model's biggest dimension, ignoring rotation -- the worst-case space it needs. Not the axial extent
-- above: this is for callers wanting "how big is this thing", not how much of a skewer it eats.
function StickIngredients.GetMaxExtent(model: Model): number
	local _, size = model:GetBoundingBox()
	return math.max(size.X, size.Y, size.Z)
end

-- From the stick's authored pivot (on the grip, where every caller seats it) to the middle of its length.
-- Only the axial component is kept, so lateral bounding-box slop can't push ingredients off the line.
function StickIngredients.GetStickMiddleOffset(stickModel: Model): Vector3
	local boundingCFrame = stickModel:GetBoundingBox()
	local localCentre = stickModel:GetPivot():Inverse() * boundingCFrame.Position
	local direction = StickIngredients.STACK_DIRECTION.Unit
	return direction * localCentre:Dot(direction)
end

-- The stick's physical length along the stack direction, for fitToLength. Reads the bounding box's size
-- rather than only its position, so it assumes the box's axes line up with the pivot's -- not guaranteed
-- for a stick whose pivot is rotated against its mesh, but a mismatch only biases how the run crowds.
function StickIngredients.GetStickLength(stickModel: Model): number
	local _, size = stickModel:GetBoundingBox()
	local direction = StickIngredients.STACK_DIRECTION.Unit
	return math.abs(size:Dot(direction))
end

-- Fits the run into the stick's length: shrink padding toward zero first, and only once neighbours touch
-- does the run start overlapping them rather than hanging off either end. Returns (padding, scale) for
-- offsetFor's gap: scale * (extents[i-1]+extents[i])/2 + padding. Returns early for #extents <= 1, which
-- also dodges a divide-by-zero on `gaps`.
--
-- The padding-shrinking stage only runs while PADDING is positive: if full padding doesn't fit then
-- touchingSpan >= stickLength, so the touching case can't either. Negative PADDING jumps to overlap.
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

	-- Fits once neighbours just touch -- shrink padding to exactly what's left, no further.
	if touchingSpan <= stickLength then
		return (stickLength - touchingSpan) / gaps, 1
	end

	-- Overflows even edge-to-edge, so scale the centre gaps down. The first and last half-widths (endHalf)
	-- sit outside every scaled gap, so they're taken off both sides before scaling -- otherwise the run
	-- overshoots by however much of them isn't compressed.
	local endHalf = (extents[1] + extents[#extents]) / 2
	local scale = (stickLength - endHalf) / (touchingSpan - endHalf)
	return 0, math.max(scale, 0)
end

-- The centre offset of ingredient `index`. Neighbours are spaced by half of each of their extents (so a
-- bigger ingredient pushes the next further along), then the whole run is shifted to centre its span on
-- the anchor -- which is why adding an ingredient nudges the existing ones.
local function offsetFor(
	index: number,
	extents: { number },
	anchorOffset: Vector3,
	padding: number,
	scale: number
): Vector3
	local direction = StickIngredients.STACK_DIRECTION.Unit

	-- Cumulative centre of `index`, then carried on to the last for the run's full length.
	local position = 0
	for i = 2, index do
		position += scale * (extents[i - 1] + extents[i]) / 2 + padding
	end
	local runLength = position
	for i = index + 1, #extents do
		runLength += scale * (extents[i - 1] + extents[i]) / 2 + padding
	end

	-- Half-way between the first ingredient's bottom edge and the last's top. Neither edge is scaled --
	-- only the gaps between centres are, since scale compresses spacing rather than the ingredients.
	local spanCentre = (runLength + extents[#extents] / 2 - extents[1] / 2) / 2
	return anchorOffset + direction * (position - spanCentre)
end

-- The resting pose of ingredient `index` (1-based) relative to the stick base. `extents` comes from
-- ComputeExtents, `anchorOffset` from GetStickMiddleOffset, `stickLength` from GetStickLength. Orientation
-- comes from rotationFor -- the same function the extents were measured through.
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

-- Where a dropped ingredient starts before springing to rest: offset along the stack direction and
-- pre-spun, so it travels in and unwinds. SPAWN_SPIN is applied in the ingredient's own frame on top of
-- the rest pose, so it never touches the room it reserves.
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
