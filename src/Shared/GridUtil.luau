--!strict
-- Pure grid math for tiling a floor part into square cells, shared by the client ghost preview and
-- the server placement validation. All cell indices are 0-based and computed in the floor part's
-- local space, so a rotated floor still grids correctly. The grid starts from the floor's
-- (-X, -Z) corner; any remainder smaller than a cell is left as an unused margin at the far edge.
--
-- Every function takes the floor it's gridding, so one plot's grid is entirely independent of its
-- neighbours' -- which is what lets a base be built out of nine separately-sized plots rather than
-- one authored slab (see Config.Plots).

local GridUtil = {}

-- Number of whole cells the floor fits along its local X and Z axes.
function GridUtil.GetDimensions(floor: BasePart, cellSize: number): (number, number)
	return math.floor(floor.Size.X / cellSize), math.floor(floor.Size.Z / cellSize)
end

-- Maps a world position to the 0-based anchor (min-corner) cell of a footprint block CENTERED on
-- that position, so the block sits under the cursor instead of extending off toward one corner. May
-- be out of range near the edges; callers clamp against the grid dimensions.
function GridUtil.WorldToCenteredAnchor(
	floor: BasePart,
	worldPosition: Vector3,
	footprintX: number,
	footprintZ: number,
	cellSize: number
): (number, number)
	local localPosition = floor.CFrame:PointToObjectSpace(worldPosition)
	local size = floor.Size
	local anchorX = math.round((localPosition.X + size.X / 2) / cellSize - footprintX / 2)
	local anchorZ = math.round((localPosition.Z + size.Z / 2) / cellSize - footprintZ / 2)
	return anchorX, anchorZ
end

-- True when the whole footprint block fits inside the floor's cell grid.
function GridUtil.IsBlockInBounds(
	floor: BasePart,
	cellX: number,
	cellZ: number,
	footprintX: number,
	footprintZ: number,
	cellSize: number
): boolean
	local countX, countZ = GridUtil.GetDimensions(floor, cellSize)
	return cellX >= 0 and cellZ >= 0 and (cellX + footprintX) <= countX and (cellZ + footprintZ) <= countZ
end

-- World CFrame of the footprint block's center on the floor's top surface, oriented like the floor.
-- Callers lift the model by its half-height: cf * CFrame.new(0, halfHeight, 0).
function GridUtil.CellToSurfaceCFrame(
	floor: BasePart,
	cellX: number,
	cellZ: number,
	footprintX: number,
	footprintZ: number,
	cellSize: number
): CFrame
	local size = floor.Size
	local localX = (cellX + footprintX / 2) * cellSize - size.X / 2
	local localZ = (cellZ + footprintZ / 2) * cellSize - size.Z / 2
	local localY = size.Y / 2
	return floor.CFrame * CFrame.new(localX, localY, localZ)
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
