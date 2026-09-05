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
	-- buys, from level 2. An id may repeat across levels -- a product only sets the price, the server grants
	FormatLevel: ((level: number) -> string)?, -- how a level reads on the upgrade board. Defaults to
	-- the bare number, which is right for a group whose level *is* a count of something.
	TutorialLocked: boolean?, -- held off the currency button until the tutorial is finished. The run's
	-- the tutorial's beats measure against these, and buying spends money the sequence still needs
}

--
local BaseUnlocks = {}

-- How a Layout clone springs to its slot: it rises from Rise below, popping up from EntranceScale. Placed structures ride the same spring the other way up (see Structures.PLACE_DROP_HEIGHT).
BaseUnlocks.LAYOUT_DAMPING = 0.6
BaseUnlocks.LAYOUT_FREQUENCY = 3.5
BaseUnlocks.LAYOUT_RISE = 0.5
BaseUnlocks.LAYOUT_ENTRANCE_SCALE = 0.4

-- How long the server waits out the client's rise before settling its own copy, having no signal for it.
BaseUnlocks.LAYOUT_SETTLE_TIME = 3

-- The gold flash a bought slot wears, so what you just paid for stands out. Fed to HighlightPulse.
BaseUnlocks.UNLOCK_PULSE_COLOR = Color3.fromRGB(255, 205, 65)
BaseUnlocks.UNLOCK_PULSE_START_TRANSPARENCY = 0
BaseUnlocks.UNLOCK_PULSE_DURATION = 1.2

-- Each Unlocks key's render folder. Layout clones one template into a centred grid; Ghost fades the single real model while locked. Costs[n] is what level n costs, so #Costs is the max.
BaseUnlocks.Data = {
	{
		Id = "RollingStands",
		Name = "Ingredient Rolls",
		Sound = "Upgrade",
		Path = { "Rolling", "Stands" },
		LockStyle = "Layout",
		Layout = { MaxPerRow = 3, Padding = 3 },
		Limit = 6,
		Costs = { 0, 5_000, 18_000, 200_000, 500_000, 1_500_000 },
		-- Level 6 has no product made for it yet, so that last step is currency-only
		RobuxProductIds = { [2] = 3709025046, [3] = 3709025081, [4] = 3709025105, [5] = 3709025123, [6] = 3710581384 },
		TutorialLocked = true,
	},
	{
		Id = "RollSpeed",
		Name = "Roll Speed",
		Sound = "Upgrade",
		LockStyle = "Stat",
		-- One rung per entry in Rolling.LEVEL_DURATIONS, which is what the level is read against
		Limit = #Rolling.LEVEL_DURATIONS,
		-- The first six rungs are impulse-priced, since a slow roll gates everything; from 8 the ladder ramps 1.6x toward 2x, so there's no single wall
		Costs = {
			0,
			100,
			200,
			350,
			600,
			1_000,
			1_600,
			2_500,
			4_000,
			7_000,
			12_000,
			21_000,
			38_000,
			70_000,
			130_000,
			245_000,
			465_000,
			900_000,
			1_750_000,
			3_500_000,
			7_000_000,
		},
		-- Ten products over twenty levels, so the Robux button never disappears part-way up. The bands hold flat while Bux costs double, so the deal improves the further up you are
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
		-- Reads as what it does rather than as a count: "Roll Speed (1.7s)"
		FormatLevel = function(level: number): string
			return string.format("%.1fs", Rolling.GetRollDuration(level))
		end,
		TutorialLocked = true,
	},
	-- Dormant while sauce dispensers are postponed; un-comment alongside SauceDispenserManager
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

-- Every unlock at level 0, so a base renders unowned and the next player can't inherit a build.
BaseUnlocks.NO_UNLOCKS = {}
for _, unlock in BaseUnlocks.Data do
	BaseUnlocks.NO_UNLOCKS[unlock.Id] = 0
end

table.freeze(BaseUnlocks.Data)
table.freeze(BaseUnlocks.NO_UNLOCKS)

-- The Products id for one unlock level, built in one place so the config and the prompt can't drift.
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
