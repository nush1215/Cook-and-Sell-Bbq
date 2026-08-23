--
type LockStyle = "Layout" | "Ghost"

export type LayoutSpec = {
	MaxPerRow: number, -- copies per row before wrapping to the next; a "row" is just MaxPerRow high
	Padding: number, -- empty studs left between adjacent copies (added on top of the copy's size)
}

export type GamepassSlot = {
	Gamepass: string, -- the Config.Gamepasses id, which is also the tag its owners carry
	Name: string, -- what the slot's sign calls it
	SignUI: string, -- the Assets.UI template its unlock sign wears, in place of the group's usual one
	Mutation: string?, -- a Config.Mutations id every BBQ cooked on the slot comes off carrying
}

export type Unlock = {
	Id: string, -- also the key under Unlocks in player data
	Name: string, -- how it reads to the player, on the upgrade board and in the purchase notification
	Sound: string, -- the UI sound the purchase notification plays
	Path: { string }, -- folder, from a base model down, holding the single authored template
	LockStyle: LockStyle, -- Layout: template cloned into a centered grid. Ghost: faded, left in place.
	Layout: LayoutSpec?, -- present only on Layout entries
	SignsFolder: string?, -- Ghost only: per-slot folder holding UnlockSign / the upgrade sign (see below)
	SignAnchor: string?, -- Ghost only: the slot child a borrowed sign is positioned relative to
	HiddenWhileLocked: { string }?, -- Ghost only: slot children hidden outright while locked, not just faded
	Limit: number, -- highest level this can reach; caps render, purchase, and (for rolling) the roll
	Costs: { number }, -- Costs[n] is what level n costs to own; kept dense to at least Limit
	RobuxProductIds: { [number]: number }?, -- Robux dev-product id per level, keyed by the level it
	-- buys (level 1 is free, so these start at 2). Products.luau generates one product per entry; a
	-- level with no entry has no Robux option and its button stays hidden.
	GamepassSlots: { [number]: GamepassSlot }?, -- slots owned by holding a gamepass rather than by
	-- levelling the group up, keyed by slot number. They're deliberately authored past Limit, so the
	-- level-based render, sign and purchase paths can never reach them; the base reads ownership off
	-- the pass's tag instead, and their unlock sign is up whenever the pass isn't held -- from the
	-- moment a player takes the base, whatever the group's level is.
}

--
local BaseUnlocks = {}

-- How see-through a Ghost slot is while it's still locked. Applied as a floor, never a set, so a
-- part the place file authored invisible doesn't fade *into* view when it locks.
BaseUnlocks.GHOST_TRANSPARENCY = 0.7

-- How a Layout clone springs to its slot on the client (LayoutStand component). Damping/frequency
-- feed spr.target; Rise is how far below its slot a fresh clone starts, so it rises up into place;
-- EntranceScale is the size a fresh clone starts at before it springs up to full, for a pop-in.
BaseUnlocks.LAYOUT_DAMPING = 0.6
BaseUnlocks.LAYOUT_FREQUENCY = 3.5
BaseUnlocks.LAYOUT_RISE = 0.5
BaseUnlocks.LAYOUT_ENTRANCE_SCALE = 0.4

-- How far above its authored spot a sign starts when it's placed on a fresh unlock, so the client
-- springs it down and it reads as a sign being planted. Signs put up on a base that already owns the
-- slot (a rejoin) just snap.
BaseUnlocks.SIGN_DROP_HEIGHT = 6

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
--             locked, and restored when owned. A Ghost entry can also carry:
--               SignsFolder       -- a folder on each slot holding "UnlockSign" and one upgrade sign.
--                                    Signs are never faded; instead the base parents exactly one of
--                                    them in: the unlock sign on the next slot up for purchase, the
--                                    upgrade sign on slots already owned, and nothing on the rest.
--                                    Only one slot has to author them -- every other slot borrows a
--                                    copy, placed the same way relative to SignAnchor -- so adding a
--                                    slot to the place file doesn't mean copying its boards over too.
--               SignAnchor        -- the child of a slot borrowed signs are positioned against. It
--                                    has to be a part/model each slot has in the same spot (the grill
--                                    body, say), since that's what makes the copies line up.
--               HiddenWhileLocked -- slot children hidden outright (fully invisible, no collision)
--                                    while locked rather than ghosted, for parts that read as broken
--                                    when they're only faded.
--
-- Costs[n] is what level n costs to own, so a purchase reads Costs[currentLevel + 1] and being past
-- the end of the list means fully upgraded -- which also makes #Costs the max level. Levels the data
-- template already grants are never bought, so their entries never get read; they're kept anyway to
-- hold the array dense.
--
-- The grillers show one grill per level, so the cap is just how many costs are listed -- adding a grill
-- to the place file means adding another entry here and nothing else.
local GRILLER_COSTS = { 0, 2_500, 25_000, 100_000, 500_000 }

-- SkewerStand is deliberately absent: it isn't built yet, so nothing renders for it.
BaseUnlocks.Data = {
	{
		Id = "StickStand",
		Name = "Stick Stands",
		Sound = "Upgrade",
		Path = { "Interactables", "StickStand" },
		LockStyle = "Layout",
		Layout = { MaxPerRow = 5, Padding = 2 },
		Limit = 5,
		Costs = { 0, 1_000, 5_000, 25_000, 100_000 },
		RobuxProductIds = { [2] = 3709025165, [3] = 3709025236, [4] = 3709025263, [5] = 3709025285 },
	},
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
		Id = "Griller",
		Name = "Grillers",
		Sound = "BasePurchase",
		Path = { "Interactables", "Grillers" },
		LockStyle = "Ghost",
		SignsFolder = "Signs",
		SignAnchor = "GrillModel", -- the grill body, which every griller slot has in the same spot
		HiddenWhileLocked = { "Knob" }, -- a half-faded stove knob reads as a bug, so it goes entirely
		Limit = #GRILLER_COSTS,
		Costs = GRILLER_COSTS,
		RobuxProductIds = { [2] = 3709024838, [3] = 3709024881, [4] = 3709024945, [5] = 3709024971 },
		-- The Golden Grill: one past the ladder, sold as a pass rather than bought up to, and the only
		-- grill that mutates what comes off it.
		GamepassSlots = {
			[6] = {
				Gamepass = "GoldenGrill",
				Name = "Golden Grill",
				SignUI = "GoldenGrillUI",
				Mutation = "Golden",
			},
		},
	},
	-- Sauce dispensers are postponed to a future update and their models are out of the workspace, so
	-- the unlock is out of the list too -- otherwise every base warns about the missing path and the
	-- sign sells something that can't be built. Un-comment it alongside SauceDispenserManager.
	--[==[
	{
		Id = "SauceDispenser",
		Name = "Sauce Dispenser",
		Sound = "BasePurchase",
		Path = { "Interactables", "SauceDispenser" },
		LockStyle = "Ghost",
		SignsFolder = "Signs",
		SignAnchor = "SpawnPart", -- the bottle's mount, which every dispenser slot has in the same spot
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

-- The gamepass slot spec for one slot of an unlock group, or nil when that slot is an ordinary one
-- bought off the group's ladder. Every caller that has to tell the two apart goes through here.
function BaseUnlocks.GetGamepassSlot(unlockId: string, slotNumber: number?): GamepassSlot?
	local unlock = slotNumber and BaseUnlocks.GetUnlockFromId(unlockId)
	return unlock and unlock.GamepassSlots and unlock.GamepassSlots[slotNumber]
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
