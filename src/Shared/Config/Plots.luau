--
local Plots = {}

-- The cell the base ships with. It isn't a plot the player can buy and has no model of its own --
-- it's just the square in the grid below that counts as owned from the moment a base is handed over,
-- which is what makes the three plots touching it the first ones on offer.
Plots.START = "Start"

--[[
    The plots a player buys to grow their base outwards.

    Unlike an unlock ladder (Config.BaseUnlocks) there's no fixed order: every plot that's currently
    reachable is on offer at the same price, and the player picks which one they want. What changes
    with each purchase is the price -- Costs is indexed by how many plots they've bought, not by which
    plot -- so the choice is where to expand, never how much it costs.

    Reachability is the other half of it. A plot is only offered when it orthogonally touches
    something already owned, so the base grows outwards from the starting cell rather than letting
    someone leapfrog to a far corner. That rule lives in IsAvailable and is read by the sign, the
    purchase and the Robux fallback alike, so the client can't offer something the server refuses.
]]

-- The grid as it reads in the world, back row first. This is the whole source of truth for which
-- plots touch which, so re-laying out a base is a change to this table and nothing else. The names
-- are the plot models' names in the base's Plots folder.
Plots.Grid = {
	{ "6", "7", "8" },
	{ "3", "4", "5" },
	{ "1", Plots.START, "2" },
}

-- Where each plot's pieces live on a base. Named here so the server that moves them and the client
-- that mounts their UI can't drift apart.
Plots.FOLDER_NAME = "Plots" -- the folder on a base model holding every plot
Plots.MISC_FOLDER_NAME = "Misc" -- the overgrowth on a plot, parked in the base's storage once it's bought
Plots.SIGN_NAME = "UnlockSign" -- the board a buyable plot wears
Plots.SIGN_UI = "PlotUnlockUI" -- the Assets.UI template that sign's UI is cloned from
-- The part covering a plot's buildable ground. Every plot carries one, the starting cell included --
-- which is the one thing Plots.START does have a model for, since owning ground and being able to
-- build on it are the same question. Its size and pose are the whole grid (see Shared.GridUtil), so
-- re-shaping where a player can build is a change to the part and nothing else.
Plots.FLOOR_NAME = "Floor"

-- Costs[n] is what the nth plot a player buys costs them, whichever plot that turns out to be. Being
-- past the end of the list means they own the lot, which also makes #Costs the number of plots.
Plots.Costs = { 1_000, 15_000, 50_000, 150_000, 500_000, 1_500_000, 5_000_000, 15_000_000 }

-- The Robux dev product per unlock, keyed the same way Costs is -- by how many plots the player has
-- already bought, not by which plot. The receipt says nothing about which one they picked, so
-- BaseManager remembers that when it raises the prompt (see PromptPlotProduct).
Plots.RobuxProductIds = {
	[1] = 3709025165,
	[2] = 3709025236,
	[3] = 3709025263,
	[4] = 3709025285,
	[5] = 3709488967,
	[6] = 3709488993,
	[7] = 3709489006,
	[8] = 3709489039,
}

-- How the overgrowth goes when a plot is bought: every part of it snaps to neon and then fades out,
-- so the clearing reads as the land being burned back rather than the props blinking out of
-- existence. Played by the client (see the Plot class), because it's the trees themselves being
-- animated -- a plot that was already bought before you joined skips it and is simply clear.
--
-- What's left at the end of it isn't a hidden tree: the server pulls the whole Misc folder into the
-- base's storage as the fade lands, so a cleared plot has no overgrowth in the world at all.
Plots.CLEAR_COLOR = Color3.fromRGB(255, 205, 65)
Plots.CLEAR_HOLD = 0.15 -- seconds the neon holds at full before the fade starts
Plots.CLEAR_FADE = 0.75 -- seconds the fade itself runs
-- How long the server leaves the overgrowth standing past the end of that fade before it pulls the
-- folder. The effect goes out at the same moment the wait starts, so a player on a slow connection is
-- that far behind the burn the server is timing -- and without the margin their trees are taken out
-- from under a tween still running.
Plots.CLEAR_PARK_GRACE = 0.25

-- [plotId] = { Row, Column } into the grid above, built once so neighbour lookups don't re-walk it.
local CELLS = {}
for row, columns in Plots.Grid do
	for column, plotId in columns do
		CELLS[plotId] = { Row = row, Column = column }
	end
end

table.freeze(Plots.Grid)
table.freeze(Plots.Costs)
table.freeze(Plots.RobuxProductIds)

-- The Products.luau string id for buying one plot with Robux. Built in one place so the config that
-- generates the product and the manager that prompts it can't drift apart.
function Plots.GetProductStringId(unlockIndex: number): string
	return `Plot_{unlockIndex}`
end

-- Whether the id names a real plot, which everything taking one off a remote has to check first.
function Plots.IsPlot(plotId: string): boolean
	return plotId ~= Plots.START and CELLS[plotId] ~= nil
end

-- The cells directly touching this plot -- up, down, left and right, but not the diagonals, which is
-- what makes the base grow in a cross from the start rather than reaching a corner in one step. The
-- starting cell comes back as Plots.START, since it counts as owned without being in anyone's data.
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

-- Whether this plot is one the player can buy right now: not already theirs, and touching something
-- that is. Every place that offers, sells or falls back to a plot goes through here, so a sign can
-- never stand on something the purchase would turn down.
-- @param unlocked The player's data.Plots
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

-- Whether the player has this plot's ground -- either bought, or the starting cell they were handed
-- with the base. Distinct from IsAvailable above, which asks whether a plot is on *offer*: the two are
-- never true at once, since buying a plot is exactly what moves it from the one to the other.
--
-- This is what gates building. The ghost, the placement and the render on a rejoin all read it, so a
-- client can never offer ground the server would refuse to build on.
-- @param unlocked The player's data.Plots
function Plots.IsOwned(plotId: string, unlocked: { [string]: boolean }): boolean
	return plotId == Plots.START or unlocked[plotId] == true
end

-- How many plots the player has bought, which is what their next one is priced off.
function Plots.GetUnlockedCount(unlocked: { [string]: boolean }): number
	local count = 0
	for plotId in unlocked do
		-- Only cells the grid still has: a plot dropped from the layout shouldn't go on counting
		-- against the price of the ones that are left.
		if Plots.IsPlot(plotId) then
			count += 1
		end
	end

	return count
end

-- What the player's next plot costs them, or nil once they own every one.
function Plots.GetCost(unlockedCount: number): number?
	return Plots.Costs[unlockedCount + 1]
end

return Plots
