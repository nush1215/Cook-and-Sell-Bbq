--!strict
-- Pure grid maths for tiling a base into cells, measured off the starting plot's floor so a rotated base still grids. One lattice covers the whole base, which is what lets a structure straddle a plot seam.

local GridUtil = {}

-- A plot's cells as half-open ranges, so two abutting plots meet with neither gap nor overlap
export type Rect = {
	MinX: number,
	MinZ: number,
	MaxX: number,
	MaxZ: number,
}

-- Every buildable cell and where the lattice sits. One rect per plot, cheaper to test than to merge
export type Ground = {
	Origin: CFrame, -- world pose of cell (0, 0)'s min corner, on the floors' top surface
	Rects: { Rect },
	MinX: number,
	MinZ: number,
	MaxX: number,
	MaxZ: number,
}

-- Where the lattice is measured from. Read alone by anything only turning cells back into poses
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

-- The ground a player may build on. Extents round to the nearest cell, the same rule GetFootprint uses, so abutting floors hand off exactly.
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

		-- Walked as corners, so a floor turned against the starting plot's still claims what it covers
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

		-- A sub-cell floor rounds to nothing -- a plot with no room rather than one reaching into its neighbour
		if rect.MaxX <= rect.MinX or rect.MaxZ <= rect.MinZ then
			continue
		end

		table.insert(ground.Rects, rect)

		ground.MinX = math.min(ground.MinX, rect.MinX)
		ground.MinZ = math.min(ground.MinZ, rect.MinZ)
		ground.MaxX = math.max(ground.MaxX, rect.MaxX)
		ground.MaxZ = math.max(ground.MaxZ, rect.MaxZ)
	end

	-- A point rather than the infinities above, which callers clamping into would turn into NaN cells
	if #ground.Rects == 0 then
		ground.MinX, ground.MinZ, ground.MaxX, ground.MaxZ = 0, 0, 0, 0
	end

	return ground
end

-- Whether every cell of the block sits on owned ground. Ownership is this test rather than a check beside it.
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

-- The anchor cell of a block centred on `position`, so it sits under the cursor. May be off their ground.
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

-- The block centre's world CFrame on the top surface. Callers lift by half-height themselves.
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

-- Swaps X/Z on a quarter-turn, so a turned structure reserves the cells it actually covers.
function GridUtil.RotateFootprint(footprintX: number, footprintZ: number, rotation: number): (number, number)
	if rotation % 2 == 1 then
		return footprintZ, footprintX
	end
	return footprintX, footprintZ
end

return GridUtil
