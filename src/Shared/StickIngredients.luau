-- Where each ingredient sits on a skewer: one reproducible pose per (index, id), and the spacing that fits the run onto the stick.

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)

--
local StickIngredients = {}

-- Placement in the stick base's local space; flip STACK_DIRECTION if the skewer points another way
StickIngredients.STACK_DIRECTION = Vector3.new(0, 1, 0) -- which way ingredients stack along the stick
StickIngredients.PADDING = -1.2 -- extra gap between neighbours on top of their extents (negative tightens)
StickIngredients.SPAWN_RISE = 6 -- studs along the stack direction a dropped ingredient starts from
StickIngredients.SPAWN_SPIN = math.pi -- extra spin at the drop start, unwound on the way down
-- Max pitch/roll, composing to 2x. Doubles as spacing -- a leaning ingredient reserves less room
StickIngredients.TILT = math.rad(50)

-- The id folded with the index, so a row of skewers doesn't read as clones. Purely shared data, so both paths agree.
local function orientationSeed(index: number, ingredientId: string): number
	local hash = 5381
	for i = 1, #ingredientId do
		hash = (hash * 33 + string.byte(ingredientId, i)) % 2147483647
	end
	return (hash * 33 + index) % 2147483647
end

-- The pose of ingredient `index`: a spin about STACK_DIRECTION, then a bounded tilt off it. The one place a pose is decided.
local function rotationFor(index: number, ingredientId: string): CFrame
	local direction = StickIngredients.STACK_DIRECTION.Unit

	local rng = Random.new(orientationSeed(index, ingredientId))
	local spin = rng:NextNumber(0, math.pi * 2)
	local pitch = rng:NextNumber(-StickIngredients.TILT, StickIngredients.TILT)
	local roll = rng:NextNumber(-StickIngredients.TILT, StickIngredients.TILT)

	-- Two axes across the skewer, so the lean tips it off the stick rather than spinning it along
	local reference = if math.abs(direction.Y) < 0.99 then Vector3.yAxis else Vector3.xAxis
	local pitchAxis = direction:Cross(reference).Unit
	local rollAxis = direction:Cross(pitchAxis)

	return CFrame.fromAxisAngle(direction, spin)
		* CFrame.fromAxisAngle(pitchAxis, pitch)
		* CFrame.fromAxisAngle(rollAxis, roll)
end

-- Room `index` takes along the skewer in its actual pose, as the ellipsoid inscribed in its bounding box.
local function stackExtentFor(model: Model, index: number, ingredientId: string): number
	local _, size = model:GetBoundingBox()
	local axis = rotationFor(index, ingredientId):VectorToObjectSpace(StickIngredients.STACK_DIRECTION.Unit)

	return math.sqrt((size.X * axis.X) ^ 2 + (size.Y * axis.Y) ^ 2 + (size.Z * axis.Z) ^ 2)
end

-- Every footprint in list order. The only supported input to GetRestLocalCFrame -- extents are pose-tied.
function StickIngredients.ComputeExtents(ingredientIds: { string }, cooked: boolean?): { number }
	local extents = {}
	for index, ingredientId in ingredientIds do
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)
		local model = ingredient and (if cooked then ingredient.CookedModel else ingredient.Model)
		extents[index] = if model then stackExtentFor(model, index, ingredientId) else 0
	end

	return extents
end

-- A model's biggest dimension, for callers asking how big it is rather than how much skewer it eats.
function StickIngredients.GetMaxExtent(model: Model): number
	local _, size = model:GetBoundingBox()
	return math.max(size.X, size.Y, size.Z)
end

-- From the stick's authored pivot to the middle of its length. Axial only, so slop can't push off-line.
function StickIngredients.GetStickMiddleOffset(stickModel: Model): Vector3
	local boundingCFrame = stickModel:GetBoundingBox()
	local localCentre = stickModel:GetPivot():Inverse() * boundingCFrame.Position
	local direction = StickIngredients.STACK_DIRECTION.Unit
	return direction * localCentre:Dot(direction)
end

-- The stick's length along the stack direction. Assumes the box's axes line up with the pivot's.
function StickIngredients.GetStickLength(stickModel: Model): number
	local _, size = stickModel:GetBoundingBox()
	local direction = StickIngredients.STACK_DIRECTION.Unit
	return math.abs(size:Dot(direction))
end

-- Fits the run to the stick: shrink padding first, then overlap. Returns (padding, scale) for offsetFor.
local function fitToLength(extents: { number }, stickLength: number): (number, number)
	if #extents <= 1 then
		return StickIngredients.PADDING, 1
	end

	local touchingSpan = 0
	for _, extent in extents do
		touchingSpan += extent
	end
	local gaps = #extents - 1

	-- Fits with the full padding: unchanged from before
	if touchingSpan + gaps * StickIngredients.PADDING <= stickLength then
		return StickIngredients.PADDING, 1
	end

	-- Fits once neighbours just touch -- shrink padding to exactly what's left, no further
	if touchingSpan <= stickLength then
		return (stickLength - touchingSpan) / gaps, 1
	end

	-- The end half-widths sit outside every scaled gap, so they come off both sides before scaling
	local endHalf = (extents[1] + extents[#extents]) / 2
	local scale = (stickLength - endHalf) / (touchingSpan - endHalf)
	return 0, math.max(scale, 0)
end

-- The centre offset of `index`; the run then shifts to centre its span, which is why adding one nudges the rest.
local function offsetFor(
	index: number,
	extents: { number },
	anchorOffset: Vector3,
	padding: number,
	scale: number
): Vector3
	local direction = StickIngredients.STACK_DIRECTION.Unit

	-- Cumulative centre of `index`, then carried on to the last for the run's full length
	local position = 0
	for i = 2, index do
		position += scale * (extents[i - 1] + extents[i]) / 2 + padding
	end
	local runLength = position
	for i = index + 1, #extents do
		runLength += scale * (extents[i - 1] + extents[i]) / 2 + padding
	end

	-- Neither end edge is scaled -- scale compresses the spacing, not the ingredients
	local spanCentre = (runLength + extents[#extents] / 2 - extents[1] / 2) / 2
	return anchorOffset + direction * (position - spanCentre)
end

-- The rest pose of `index` relative to the stick base. Callers must seat the bounding-box centre, not the pivot.
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

-- Where a dropped ingredient starts before springing to rest, pre-spun so it unwinds on the way in.
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

-- Pivot-to-bounding-box-centre, so a caller can seat the centre on a slot. Compute before moving the model.
function StickIngredients.GetPivotToCenter(model: Model): CFrame
	local boundingCFrame = model:GetBoundingBox()
	return model:GetPivot():Inverse() * boundingCFrame
end

return StickIngredients
