--!strict
-- Pure grid math for tiling a base into square cells, shared by the client ghost preview and the
-- server placement validation. Cell indices are measured off the starting plot's floor, in that
-- part's local space, so a rotated base still grids correctly.
--
-- One lattice covers the whole base rather than one per plot, and which of it a player may build on
-- is the union of the plots they own (see BuildGround below). That's what lets a structure straddle
-- the seam between two plots: the cells run straight through it, so there's nothing there to stop at.
-- Cells on a plot behind or left of the starting one are simply negative.

local GridUtil = {}

-- A run of cells one plot's floor covers, as half-open ranges: the Max edges are the first cell
-- *past* the plot, which is what lets two abutting plots' rects meet with neither a gap nor an overlap.
export type Rect = {
	MinX: number,
	MinZ: number,
	MaxX: number,
	MaxZ: number,
}

-- Every cell a player may build on, plus where the lattice sits in the world. Rects is one per owned
-- plot rather than a merged shape, because the union of a few rectangles is cheaper to test against
-- than it is to compute -- and the Min/Max below are the bounding box of the lot, which is what the
-- ghost clamps into.
export type Ground = {
	Origin: CFrame, -- world pose of cell (0, 0)'s min corner, on the floors' top surface
	Rects: { Rect },
	MinX: number,
	MinZ: number,
	MaxX: number,
	MaxZ: number,
}

-- Where the base's lattice is measured from: the starting plot's floor, at its (-X, -Z) corner on its
-- top surface and turned the way it is. Read on its own by anything that only has to turn cells back
-- into poses -- a structure standing on cells its owner has since had cleared still belongs where it
-- was put, so rendering one asks where the lattice is and never which of it is owned.
function GridUtil.GetOrigin(startFloor: BasePart): CFrame
	local size = startFloor.Size
	return startFloor.CFrame * CFrame.new(-size.X / 2, size.Y / 2, -size.Z / 2)
end

-- The four horizontal corners of a floor, in its own local space.
local function getFloorCorners(floor: BasePart): { Vector3 }
	local halfX, halfZ = floor.Size.X / 2, floor.Size.Z / 2

	return {
		Vector3.new(-halfX, 0, -halfZ),
		Vector3.new(-halfX, 0, halfZ),
		Vector3.new(halfX, 0, -halfZ),
		Vector3.new(halfX, 0, halfZ),
	}
end

-- The ground a player may build on: the base's lattice, measured off the starting plot's floor, and
-- the cells each of the floors they own covers within it.
--
-- Extents are rounded to the nearest cell rather than floored inwards, so floors that abut hand off
-- to each other exactly instead of each leaving a sub-cell margin -- which would put an unbuildable
-- strip down every seam. It's the same rounding Structures.GetFootprint measures a structure with, so
-- a floor and the things standing on it are sized by the same rule.
--
-- @param startFloor The Plots.START floor, which every base has and which anchors the lattice
-- @param floors The floors of the plots the player owns, the starting one included
function GridUtil.BuildGround(startFloor: BasePart, floors: { BasePart }, cellSize: number): Ground
	local ground: Ground = {
		Origin = GridUtil.GetOrigin(startFloor),
		Rects = {},
		MinX = math.huge,
		MinZ = math.huge,
		MaxX = -math.huge,
		MaxZ = -math.huge,
	}

	for _, floor in floors do
		local minX, minZ = math.huge, math.huge
		local maxX, maxZ = -math.huge, -math.huge

		-- Walked as corners rather than read off the size, so a floor turned against the starting plot's
		-- still claims the cells it actually covers.
		for _, corner in getFloorCorners(floor) do
			local point = ground.Origin:PointToObjectSpace(floor.CFrame:PointToWorldSpace(corner))

			minX = math.min(minX, point.X)
			maxX = math.max(maxX, point.X)
			minZ = math.min(minZ, point.Z)
			maxZ = math.max(maxZ, point.Z)
		end

		local rect: Rect = {
			MinX = math.round(minX / cellSize),
			MinZ = math.round(minZ / cellSize),
			MaxX = math.round(maxX / cellSize),
			MaxZ = math.round(maxZ / cellSize),
		}

		-- A floor less than a cell across rounds away to nothing. That's a plot with no room on it rather
		-- than one that reaches into its neighbour's cells, so it contributes no ground at all.
		if rect.MaxX <= rect.MinX or rect.MaxZ <= rect.MinZ then
			continue
		end

		table.insert(ground.Rects, rect)

		ground.MinX = math.min(ground.MinX, rect.MinX)
		ground.MinZ = math.min(ground.MinZ, rect.MinZ)
		ground.MaxX = math.max(ground.MaxX, rect.MaxX)
		ground.MaxZ = math.max(ground.MaxZ, rect.MaxZ)
	end

	-- Nothing to build on, so the bounding box is a point rather than the infinities above -- callers
	-- clamp into it, and an infinity there would come back as a NaN cell.
	if #ground.Rects == 0 then
		ground.MinX, ground.MinZ, ground.MaxX, ground.MaxZ = 0, 0, 0, 0
	end

	return ground
end

-- True when every cell of the footprint block sits on ground the player owns. A block spanning two
-- plots passes on the cells each of them covers, which is the whole of what makes building across a
-- seam legal -- and a block over a plot they haven't bought fails on the cells nothing covers, so
-- ownership is this test rather than a check beside it.
function GridUtil.IsBlockOnGround(
	ground: Ground,
	cellX: number,
	cellZ: number,
	footprintX: number,
	footprintZ: number
): boolean
	for x = cellX, cellX + footprintX - 1 do
		for z = cellZ, cellZ + footprintZ - 1 do
			local covered = false

			for _, rect in ground.Rects do
				if x >= rect.MinX and x < rect.MaxX and z >= rect.MinZ and z < rect.MaxZ then
					covered = true
					break
				end
			end

			if not covered then
				return false
			end
		end
	end

	return true
end

-- Maps a world position to the anchor (min-corner) cell of a footprint block CENTERED on that
-- position, so the block sits under the cursor instead of extending off toward one corner. May be off
-- the player's ground; callers clamp against it.
function GridUtil.WorldToCenteredAnchor(
	origin: CFrame,
	worldPosition: Vector3,
	footprintX: number,
	footprintZ: number,
	cellSize: number
): (number, number)
	local localPosition = origin:PointToObjectSpace(worldPosition)
	local anchorX = math.round(localPosition.X / cellSize - footprintX / 2)
	local anchorZ = math.round(localPosition.Z / cellSize - footprintZ / 2)
	return anchorX, anchorZ
end

-- World CFrame of the footprint block's center on the base's top surface, oriented like the lattice.
-- Callers lift the model by its half-height: cf * CFrame.new(0, halfHeight, 0).
function GridUtil.CellToSurfaceCFrame(
	origin: CFrame,
	cellX: number,
	cellZ: number,
	footprintX: number,
	footprintZ: number,
	cellSize: number
): CFrame
	local localX = (cellX + footprintX / 2) * cellSize
	local localZ = (cellZ + footprintZ / 2) * cellSize
	return origin * CFrame.new(localX, 0, localZ)
end

-- Swaps the footprint's X/Z for quarter-turn rotations (odd rotation indices 1 and 3), which is what
-- makes a turned structure reserve the cells it actually covers rather than the ones it started on.
function GridUtil.RotateFootprint(footprintX: number, footprintZ: number, rotation: number): (number, number)
	if rotation % 2 == 1 then
		return footprintZ, footprintX
	end
	return footprintX, footprintZ
end

return GridUtil
