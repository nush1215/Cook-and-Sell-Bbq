--
type LockStyle = "Layout" | "Ghost"

export type LayoutSpec = {
	MaxPerRow: number, -- copies per row before wrapping to the next; a "row" is just MaxPerRow high
	Padding: number, -- empty studs left between adjacent copies (added on top of the copy's size)
}

export type Unlock = {
	Id: string, -- also the key under Unlocks in player data
	Name: string, -- how it reads to the player, on the upgrade board and in the purchase notification
	Sound: string, -- the UI sound the purchase notification plays
	Path: { string }, -- folder, from a base model down, holding the single authored template
	LockStyle: LockStyle, -- Layout: template cloned into a centered grid. Ghost: faded, left in place.
	Layout: LayoutSpec?, -- present only on Layout entries
	Limit: number, -- highest level this can reach; caps render, purchase, and (for rolling) the roll
	Costs: { number }, -- Costs[n] is what level n costs to own; kept dense to at least Limit
	RobuxProductIds: { [number]: number }?, -- Robux dev-product id per level, keyed by the level it
	-- buys (level 1 is free, so these start at 2). Products.luau generates one product per entry; a
	-- level with no entry has no Robux option and its button stays hidden.
}

--
local BaseUnlocks = {}

-- How a Layout clone springs to its slot on the client (LayoutStand component). Damping/frequency
-- feed spr.target; Rise is how far below its slot a fresh clone starts, so it rises up into place;
-- EntranceScale is the size a fresh clone starts at before it springs up to full, for a pop-in.
--
-- Placed structures ride the same component and the same spring, but start above their slot at full
-- size instead (see Structures.PLACE_DROP_HEIGHT) -- so a bought upgrade grows into place while a
-- built structure is set down onto it. The Rise and EntranceScale below are the unlocks' alone.
BaseUnlocks.LAYOUT_DAMPING = 0.6
BaseUnlocks.LAYOUT_FREQUENCY = 3.5
BaseUnlocks.LAYOUT_RISE = 0.5
BaseUnlocks.LAYOUT_ENTRANCE_SCALE = 0.4

-- The one-shot gold flash a slot wears the moment it's bought, so the thing you just paid for is
-- obvious on a base that already has five of them. Fed straight to the HighlightPulse effect:
-- START_TRANSPARENCY is where the fill begins before it tweens out over DURATION seconds.
BaseUnlocks.UNLOCK_PULSE_COLOR = Color3.fromRGB(255, 205, 65)
BaseUnlocks.UNLOCK_PULSE_START_TRANSPARENCY = 0
BaseUnlocks.UNLOCK_PULSE_DURATION = 1.2

-- Maps each Unlocks key in player data onto the folder its render lives in. A level of N shows N of
-- the thing. How the place file authors that folder depends on LockStyle:
--   Layout -- the folder holds ONE template model. The base clones it N times into a centered grid,
--             so the count is the level. MaxPerRow sets the wrap (5 = a row of up to 5; 3 = a 3x3),
--             Padding the gap between copies. The template's authored position is the grid's centre.
--   Ghost  -- the folder holds the single real model. It's just faded + made non-collidable while
--             locked, and restored when owned.
--
-- Costs[n] is what level n costs to own, so a purchase reads Costs[currentLevel + 1] and being past
-- the end of the list means fully upgraded -- which also makes #Costs the max level. Levels the data
-- template already grants are never bought, so their entries never get read; they're kept anyway to
-- hold the array dense.
--
-- Grillers and stick stands used to be here too. They're freely-placed structures now (see
-- Config.Structures) -- a player builds as many as they like, wherever they like, rather than buying
-- them one at a time in a fixed order -- so nothing about them is a level any more.
BaseUnlocks.Data = {
	{
		Id = "RollingStands",
		Name = "Ingredient Rolls",
		Sound = "Upgrade",
		Path = { "Rolling", "Stands" },
		LockStyle = "Layout",
		Layout = { MaxPerRow = 3, Padding = 3 },
		Limit = 6,
		Costs = { 0, 1_500, 12_500, 50_000, 250_000, 750_000 },
		-- Level 6 has no product made for it yet, so that last step is currency-only.
		RobuxProductIds = { [2] = 3709025046, [3] = 3709025081, [4] = 3709025105, [5] = 3709025123 },
	},
	-- Sauce dispensers are postponed to a future update and their models are out of the workspace, so
	-- the unlock is out of the list too -- otherwise every base warns about the missing path and the
	-- sign sells something that can't be built. Un-comment it alongside SauceDispenserManager -- though
	-- by then it's probably a Config.Structures entry rather than a level, like the grillers went.
	--[==[
	{
		Id = "SauceDispenser",
		Name = "Sauce Dispenser",
		Sound = "BasePurchase",
		Path = { "Interactables", "SauceDispenser" },
		LockStyle = "Ghost",
		Limit = 1,
		Costs = { 15_000 },
	},
	]==]
}

-- Every unlock at level 0. A base renders from this before anyone owns it and again once its owner
-- leaves, so the next player through can't inherit the last one's build.
BaseUnlocks.NO_UNLOCKS = {}
for _, unlock in BaseUnlocks.Data do
	BaseUnlocks.NO_UNLOCKS[unlock.Id] = 0
end

table.freeze(BaseUnlocks.Data)
table.freeze(BaseUnlocks.NO_UNLOCKS)

-- The Products.luau string id for buying one level of an unlock with Robux. Built in one place so the
-- config that generates the product and the client that prompts it can't drift apart.
function BaseUnlocks.GetProductStringId(unlockId: string, level: number): string
	return `{unlockId}_L{level}`
end

function BaseUnlocks.GetUnlockFromId(id: string): Unlock?
	for _, v in BaseUnlocks.Data do
		if v.Id == id then
			return v
		end
	end

	return nil
end

return BaseUnlocks
