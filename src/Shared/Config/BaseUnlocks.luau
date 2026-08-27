-- Config
local Rolling = require(script.Parent.Rolling)

--
type LockStyle = "Layout" | "Ghost" | "Stat"

export type LayoutSpec = {
	MaxPerRow: number, -- copies per row before wrapping to the next; a "row" is just MaxPerRow high
	Padding: number, -- empty studs left between adjacent copies (added on top of the copy's size)
}

export type Unlock = {
	Id: string, -- also the key under Unlocks in player data
	Name: string, -- how it reads to the player, on the upgrade board and in the purchase notification
	Sound: string, -- the UI sound the purchase notification plays
	Path: { string }?, -- folder, from a base model down, holding the single authored template. Absent
	-- on a Stat entry, which has nothing in the world to point at.
	LockStyle: LockStyle, -- Layout: template cloned into a centered grid. Ghost: faded, left in place.
	-- Stat: nothing rendered at all -- the level is read by whatever system it tunes.
	Layout: LayoutSpec?, -- present only on Layout entries
	Limit: number, -- highest level this can reach; caps render, purchase, and (for rolling) the roll
	Costs: { number }, -- Costs[n] is what level n costs to own; kept dense to at least Limit
	RobuxProductIds: { [number]: number }?, -- Robux dev-product id per level, keyed by the level it
	-- buys (level 1 is free, so these start at 2). Products.luau generates one product per entry; a
	-- level with no entry has no Robux option and its button stays hidden. The same id may repeat
	-- across neighbouring levels -- one product covering a band of them -- since a product only sets
	-- the price and the server grants whatever the player's next level is.
	FormatLevel: ((level: number) -> string)?, -- how a level reads on the upgrade board. Defaults to
	-- the bare number, which is right for a group whose level *is* a count of something.
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
	{
		Id = "RollSpeed",
		Name = "Roll Speed",
		Sound = "Upgrade",
		LockStyle = "Stat",
		-- One rung per entry in Rolling.LEVEL_DURATIONS, which is what the level is read against.
		Limit = #Rolling.LEVEL_DURATIONS,
		-- Level 1 is granted by the data template, so its 0 is only here to hold the array dense.
		Costs = {
			0,
			1_000,
			1_600,
			2_600,
			4_200,
			6_800,
			11_000,
			17_500,
			28_000,
			45_000,
			72_000,
			115_000,
			185_000,
			295_000,
			470_000,
			750_000,
			1_200_000,
			1_900_000,
			3_000_000,
			4_800_000,
			7_500_000,
		},
		-- Ten products over the twenty buyable levels, so each one covers a band of two. Banded rather
		-- than one per level so the Robux button never disappears part-way up the ladder, and the same
		-- id can sit on both rungs safely because a product only sets the price -- the server grants
		-- whatever the player's next level is (see Products.luau), so a receipt can't skip a level or
		-- hand out one already owned.
		--
		-- The bands run cheapest-first against the Bux costs above, which roughly double every rung
		-- while a tier's Robux price holds flat across its two. That's deliberate: the early levels are
		-- priced to be worth taking at all, and the deal only gets better the further up someone is.
		RobuxProductIds = {
			[2] = 3710074572, -- Tier 1
			[3] = 3710074572,
			[4] = 3710074618, -- Tier 2
			[5] = 3710074618,
			[6] = 3710074629, -- Tier 3
			[7] = 3710074629,
			[8] = 3710074638, -- Tier 4
			[9] = 3710074638,
			[10] = 3710074651, -- Tier 5
			[11] = 3710074651,
			[12] = 3710074661, -- Tier 6
			[13] = 3710074661,
			[14] = 3710074681, -- Tier 7
			[15] = 3710074681,
			[16] = 3710074698, -- Tier 8
			[17] = 3710074698,
			[18] = 3710074718, -- Tier 9
			[19] = 3710074718,
			[20] = 3710074728, -- Tier 10
			[21] = 3710074728,
		},
		-- Reads as what it does rather than as a count: "Roll Speed (1.7s)".
		FormatLevel = function(level: number): string
			return string.format("%.1fs", Rolling.GetRollDuration(level))
		end,
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
