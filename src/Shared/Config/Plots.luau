--
local Plots = {}

-- The cell the base ships with: owned from handover, which is what puts the three touching it on offer
Plots.START = "Start"

-- The plot grid a base grows through: which plots touch which, what the next one costs, and how a bought one clears.

-- The grid as it reads in the world, back row first -- the whole source of truth for which plots touch which
Plots.Grid = {
	{ "9", "10", "11" },
	{ "6", "7", "8" },
	{ "3", "4", "5" },
	{ "1", Plots.START, "2" },
}

-- Where each plot's pieces live, named so the server moving them and the client mounting them can't drift
Plots.FOLDER_NAME = "Plots" -- the folder on a base model holding every plot
Plots.MISC_FOLDER_NAME = "Misc" -- the overgrowth on a plot, parked in the base's storage once it's bought
Plots.SIGN_NAME = "UnlockSign" -- the board a buyable plot wears
Plots.SIGN_UI = "PlotUnlockUI" -- the Assets.UI template that sign's UI is cloned from
-- The part covering a plot's buildable ground; its size and pose are the whole grid (see GridUtil)
Plots.FLOOR_NAME = "Floor"

-- Costs[n] is what the nth plot costs, whichever it is; past the end means they own the lot
Plots.Costs =
	{ 5_000, 50_000, 100_000, 250_000, 500_000, 1_500_000, 5_000_000, 7_500_000, 10_000_000, 12_500_000, 15_000_000 }

-- One product per unlock, keyed by how many they own -- BaseManager remembers which plot was picked
Plots.RobuxProductIds = {
	[1] = 3709025165,
	[2] = 3709025236,
	[3] = 3709025263,
	[4] = 3709025285,
	[5] = 3709488967,
	[6] = 3709488993,
	[7] = 3709489006,
	[8] = 3709489039,
	[9] = 3711461679,
	[10] = 3711461700,
	[11] = 3711461724,
}

-- The burn on a bought plot: neon then fade, played client-side, after which the server pulls the folder
Plots.CLEAR_COLOR = Color3.fromRGB(255, 205, 65)
Plots.CLEAR_HOLD = 0.15 -- seconds the neon holds at full before the fade starts
Plots.CLEAR_FADE = 0.75 -- seconds the fade itself runs
-- Margin past the fade, so a slow client's tween isn't cut off when the server pulls the folder
Plots.CLEAR_PARK_GRACE = 0.25

-- [plotId] = { Row, Column }, built once so neighbour lookups don't re-walk the grid
local CELLS = {}
for row, columns in Plots.Grid do
	for column, plotId in columns do
		CELLS[plotId] = { Row = row, Column = column }
	end
end

table.freeze(Plots.Grid)
table.freeze(Plots.Costs)
table.freeze(Plots.RobuxProductIds)

-- The Products id for one plot, built in one place so the config and the prompt can't drift.
function Plots.GetProductStringId(unlockIndex: number): string
	return `Plot_{unlockIndex}`
end

-- Whether the id names a real plot, which everything taking one off a remote must check first.
function Plots.IsPlot(plotId: string): boolean
	return plotId ~= Plots.START and CELLS[plotId] ~= nil
end

-- The four cells touching this plot, no diagonals, so a base grows in a cross. START is included.
function Plots.GetNeighbours(plotId: string): { string }
	local cell = CELLS[plotId]
	if not cell then
		return {}
	end

	local neighbours = {}
	for _, step in { { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 } } do
		local row = Plots.Grid[cell.Row + step[1]]
		local neighbour = row and row[cell.Column + step[2]]

		if neighbour then
			table.insert(neighbours, neighbour)
		end
	end

	return neighbours
end

-- Whether the player can buy this plot: not theirs, and touching something that is. Every offer and sale goes through here.
function Plots.IsAvailable(plotId: string, unlocked: { [string]: boolean }): boolean
	if not Plots.IsPlot(plotId) or unlocked[plotId] then
		return false
	end

	for _, neighbour in Plots.GetNeighbours(plotId) do
		if neighbour == Plots.START or unlocked[neighbour] then
			return true
		end
	end

	return false
end

-- Whether the player owns this plot's ground. This is what gates building, so a client can't offer ground the server refuses.
function Plots.IsOwned(plotId: string, unlocked: { [string]: boolean }): boolean
	return plotId == Plots.START or unlocked[plotId] == true
end

-- How many plots the player has bought, which is what their next one is priced off.
function Plots.GetUnlockedCount(unlocked: { [string]: boolean }): number
	local count = 0
	for plotId in unlocked do
		-- Only cells the grid still has, so a dropped plot doesn't go on pricing the ones left
		if Plots.IsPlot(plotId) then
			count += 1
		end
	end

	return count
end

-- What the player's next plot costs, or nil once they own every one.
function Plots.GetCost(unlockedCount: number): number?
	return Plots.Costs[unlockedCount + 1]
end

return Plots
