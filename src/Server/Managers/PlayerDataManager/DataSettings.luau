return {
	PlayerDataTemplate = {
		--
		Currency = 100,
		TotalPlaytime = 0,

		-- Core Game
		Unlocks = {
			SauceDispenser = 0, -- the Sauce Dispenser
			RollingStands = 1, -- The gambling thing
			RollSpeed = 1, -- how long one pull takes; level 1 is the slowest (see Config.Rolling)
		},

		-- Which plots on their base the player has bought, keyed by the plot's name in the base's Plots
		-- folder. The starting plot isn't in here -- it's the START cell in Config.Plots' grid, owned
		-- from the moment the base is handed over, and it's what makes the three plots touching it the
		-- first ones on offer. What a plot costs is priced off how many of these there are rather than
		-- which ones, so the player's choice is where to expand and never how much for.
		Plots = {}, -- [plotId] = true

		-- Everything the player has built on their base, keyed by a uid minted at placement
		-- (HttpService:GenerateGUID(false), the same as a FilledStick's). Type is a Config.Structures id,
		-- naming the Assets.Structures model it's cloned from. Where it sits is the grid cell it starts at
		-- and how many quarter-turns it's been rotated -- relative rather than absolute, because a player
		-- is handed whichever base is free and an absolute pose would rebuild on the wrong one.
		--
		-- The cell is the base's rather than any one plot's: a single lattice runs across the whole base,
		-- measured off the starting plot's floor, and the plots below say which of its cells may be built
		-- on (see Shared.GridUtil). So a structure standing over the seam between two plots is an
		-- ordinary pair of numbers, and buying a plot opens up cells rather than starting a new grid.
		--
		-- Cells rather than a pose because that's exactly what the client sends and the server checks, so
		-- what's saved is what was validated: the build comes back on a rejoin on the same cells with no
		-- drift.
		--
		-- Grillers and StickStands below are keyed by these same uids: the structure is the thing, and
		-- those are whatever is sitting on it.
		Structures = {}, -- [uid] = { Type, CellX, CellZ, Rotation }
		-- Structures the player owns but hasn't put down yet, held as a stacking tool each. A structure
		-- is only ever in one of the two places: counted here, or standing on a plot above. Placing one
		-- spends it from here and picking it back up puts it back, so nothing is lost to a bad spot.
		--
		-- Seeded with one of each because a new player needs a griller and a stand to have a game at all,
		-- and the Grill & Stand Shop is somewhere to spend money rather than somewhere to get started.
		-- The griller is the bottom rung of the ladder on purpose (see Config.Structures): a new player
		-- learns the timing on a grill that won't hold a steady rate, so the first thing money buys is an
		-- Iron Grill that behaves. The ids have to be ones the config still has -- BuildManager's tool
		-- reconcile silently skips one it doesn't, which hands the player nothing at all rather than
		-- erroring.
		OwnedStructures = { RustyGrill = 1, WoodenStickStand = 1 }, -- [structureId] = amount owned

		-- Core Shop Stuff
		StarterPackStart = 0,
		PurchasedOnceProducts = {},
		GiftedGamepasses = {},
		PurchaseLogs = {},

		-- Daily Rewards
		DailyRewardStreak = 0,
		LastDailyRewardClaim = 0,

		-- Ingredient Rolling
		Ingredients = {}, -- [ingredientId] = amount owned
		-- What the player's last pull landed on each stand and hasn't bought yet. A roll is held until
		-- it's claimed -- there's no expiry, so someone can go and earn the currency for an expensive
		-- one and come back to it, a rejoin included. RolledAt is workspace:GetServerTimeNow(), and the
		-- claim is gated on the roll animation having had time to play out. SpeedLevel is the
		-- Unlocks.RollSpeed the pull was made at, which is how long that window is -- stamped on the roll
		-- rather than read live, so a level bought while a pull is in the air can't move the goalposts
		-- under the animation every client is already playing.
		PendingRolls = {}, -- [standId] = { IngredientId, RolledAt, SpeedLevel }

		-- Index
		-- [ingredientId] = lifetime number obtained; the key's presence marks it discovered
		IngredientIndex = {},

		-- Sticks (cooking). A skewer record is { StickId, Ingredients, Cooked?, CookState?, CookProgress?,
		-- Sauce?, Mutation? }; Cooked flips true once it's come off a griller cooked at all and stays with the skewer
		-- wherever it goes (tool, stand, re-placed), and CookState is a CookStates id saying how well that
		-- cook went -- an overcooked one is tinted burnt and sells for less. A skewer pulled off raw carries
		-- neither, so on everything that reads those two it's indistinguishable from one that was never lit.
		-- What it does carry is CookProgress: how far up the bar that pull got, as a fraction of it, so the
		-- next light resumes there instead of starting from cold. A fraction rather than seconds, so it
		-- means the same thing however long the bar it resumes on runs; only ever below CookStates.RAW_END,
		-- since any cook that gets past that band settles into CookState and clears this. Adding an
		-- ingredient wipes it -- a trip through a stick stand drops it on purpose (see StickStandManager).
		-- Sauce is a Sauces id, applied at a dispenser once it's cooked and likewise permanent -- so it only
		-- ever appears on FilledSticks and SkewerStand records, never on a stick stand or griller.
		-- Mutation is a Mutations id and permanent too, but it's the grill's doing rather than the
		-- player's: it's stamped when a cook settles, off the structure it settled on (the Golden Grill is
		-- the one that carries one), so a BBQ is only ever mutated by the grill it was actually cooked on.
		-- A raw pull never gets one, for the same reason it carries neither of the two above. It multiplies
		-- what the skewer sells for and puts its particles on it.
		Sticks = {}, -- [stickId] = amount owned
		-- [structureUid] = { StickId, Ingredients = { ingredientId }, Cooked? } placed on that stand
		StickStands = {},
		-- The sell stall's SkewerStand: an array (max 6) of cooked skewers on display, in placement order.
		-- One stand per base, so this is a plain list rather than slot-keyed; each entry is a full skewer record.
		SkewerStand = {}, -- { { StickId, Ingredients = { ingredientId }, Cooked = true, Sauce?, Mutation? }, ... }
		FilledSticks = {}, -- [uid] = { StickId, Ingredients, Cooked?, Sauce?, Mutation? } held as a distinct tool
		-- [structureUid] = { StickId, Ingredients = { ingredientId }, Cooked?, CookState?, CookProgress?, Mutation? } sitting
		-- on that griller. While it's cooking it also carries Cooking = true, CookStartedAt =
		-- workspace:GetServerTimeNow() and CookTime = the whole 0 -> 1 run in seconds. The player decides
		-- when to stop it, so a cook nobody comes back for still ends on schedule -- burnt -- even across a
		-- rejoin. It may also carry CookWindowStretch, how many times longer this one cook's perfect window
		-- runs (see CookStates.GetBarElapsed) -- stamped at the light and absent on every ordinary cook.
		-- CookInstability and CookInstabilityPhase are the other pair that bends the same bar: how far the
		-- grill's cook rate swings either side of 1, and where in that swing the stove happened to be lit.
		-- Both come off the grill it was lit on (only the Rusty Grill has one today) and the phase is
		-- rolled per cook, so no two cooks on it surge in the same places. Stamped at the light rather
		-- than read at the stop for the same reason CookTime is: the bar has to bend the same way from its
		-- first frame to its last, across a rejoin included.
		Grillers = {},

		-- Sauce Dispenser
		-- [slotId] = { Size = "Small", Sauce = sauceId?, Remaining = number, Skewer? }. Remaining starts at the
		-- size's Capacity (and tops back up on a size upgrade) and drops by one per skewer sauced. Skewer is
		-- the cooked skewer record sitting on the dispenser's plate; while it's being poured on the record
		-- also carries Saucing = true and SauceStartedAt = workspace:GetServerTimeNow(), so an interrupted
		-- pour still finishes across a rejoin.
		SauceDispensers = {},
		-- The sauce bottles the player is carrying, held as a stacking tool each. Equipping one and using
		-- it on a dispenser loads that dispenser with the flavor and fills it to its size's Capacity,
		-- spending one bottle.
		Sauces = {}, -- [sauceId] = bottles owned

		-- Crates
		-- Unopened crates, held as a stacking tool each. Opening some spends them up front, before any
		-- of the show plays -- what they rolled is settled server-side at that moment and handed over
		-- when the animation finishes, or by the server itself if that client never gets there.
		Crates = {}, -- [crateId] = amount owned
		-- workspace:GetServerTimeNow() the crate that crashed in for finishing the tutorial can be
		-- opened at. -1 is none pending or already claimed; a value in the past is one sitting ready.
		-- Absolute rather than a countdown on purpose -- that's what keeps it running while the player
		-- is offline, so logging off with fourteen minutes left doesn't pause it.
		TutorialCrateTimer = -1,

		-- Stick Shop
		-- Per-player purchases for the current restock window. Seed ties Bought to the window it was
		-- counted in (the shop's global stock re-rolls each window off that same seed); a stale Seed
		-- means the window rolled over, so Bought is treated as empty and reset on the next purchase.
		StickShop = { Seed = 0, Bought = {} }, -- Bought = [stickId] = amount bought this window

		-- Grill & Stand Shop
		-- The same per-window ledger as StickShop above, for the shop that sells structures. Its own
		-- Seed rather than a shared one: the two shops run separate clocks and either can be re-rolled
		-- on its own by its restock product, so a window that rolled over on one hasn't on the other.
		GrillStandShop = { Seed = 0, Bought = {} }, -- Bought = [structureId] = amount bought this window

		-- Sell Stall
		-- workspace:GetServerTimeNow() the last rich customer was sent to the stall at. The cooldown
		-- between them is wall-clock rather than session-clock, so rejoining -- or hopping to a server
		-- that's never sent them one -- doesn't hand out a fresh one.
		LastRichVisit = 0,
		-- Offers the player has turned down that still count against them, and the
		-- workspace:GetServerTimeNow() of the most recent one. Every standing refusal drags the next
		-- customer's opening offer down and lengthens the wait before it arrives, which is what stops a
		-- declined skewer -- it goes back on the stand and another customer comes for it -- from being a
		-- free reroll of the price. They're forgiven one per SellNpc.REFUSAL_DECAY seconds, and the count
		-- written back is always the already-decayed one, so the single stamp carries the whole decay.
		-- Wall-clock rather than session-clock for the same reason as LastRichVisit above.
		SaleRefusals = { Count = 0, At = 0 },
		-- Whether a customer has ever come back with a better offer after this player turned one down.
		-- Their first one is given rather than rolled for (see SellNpcManager's _negotiateSale), because
		-- the tutorial can't teach declining -- it hides the button -- so the first no would otherwise be
		-- answered on the cook state's own chance, which is 15% on the raw skewers a new player makes.
		-- Saved rather than session-scoped so a rejoin neither re-hands the lesson nor skips one the
		-- player never got.
		SeenHaggle = false,

		-- Codes
		RedeemedCodes = {}, -- code strings already claimed, one claim each forever

		-- Group Reward
		GroupRewardClaimed = false, -- one claim per player, forever; also hides the HUD's Gift button

		-- Tutorial
		-- The onboarding runs once and never again. Anyone who leaves before finishing has their
		-- gameplay progress wiped on the way out (see TutorialManager.PROGRESS_RESET_KEYS), so a
		-- rejoin always starts the sequence over on a clean base rather than dropping them halfway
		-- through a loop they never saw the start of.
		TutorialCompleted = true,
		TutorialStep = 0, -- furthest onboarding funnel step reached; written for analytics, never read back

		-- Stats
		-- Lifetime counters, only ever climbing. Distinct from the inventories above, which rise and fall
		-- as things are made and spent -- these are the record of everything the player has ever done, and
		-- what any future progression, badge or reputation feature reads off. Flat top-level numbers rather
		-- than a Stats table on purpose: IncrementDataKey, ToLeaderstats and the ordered leaderboards all
		-- index the top level only, so nesting them would put every one of them out of reach.
		SkewersCooked = 0, -- cooks settled at a griller, however they turned out
		SkewersSold = 0, -- skewers a customer walked off with, counting each one of a bulk haul
		SalesCompleted = 0, -- customers served; a rich customer clearing the stand is one of these, not six
		SalesDeclined = 0, -- offers turned down or left to lapse, so a stall that turns people away shows it
		IngredientsBought = 0, -- ingredients claimed off a rolling stand
		SticksBought = 0, -- sticks bought from the stick shop, however they were paid for
		SkewersSauced = 0, -- skewers that came off a dispenser with a flavour on them
		TotalEarned = 0, -- every dollar ever taken in, boosts included; Currency is only what's left of it
		-- [cookStateId] = lifetime cooks that settled in that state, so a key's presence marks that state
		-- as reached at least once -- the same idiom as IngredientIndex above. It grows on demand rather
		-- than being seeded, so adding a state to CookStates needs nothing here.
		CookStateCounts = {},
		-- [cookStateId] = lifetime skewers sold in that state, the sell-side counterpart to the above. Kept
		-- apart from it because the two diverge: a charred skewer can be cooked and never served, and a rich
		-- customer clearing the stand sells six at once. Grows on demand the same way, so adding a state to
		-- CookStates needs nothing here. Distinct from RecentSales below, which ages entries out by design
		-- and so can't answer what the player has ever sold.
		SoldCookStateCounts = {},
		-- The last StatsManager.RECENT_SALES skewers sold, oldest first: { CookState, Sauce?, Value }. This
		-- is what a stall reputation gets averaged over -- a rating off a rolling window can fall as well as
		-- climb, which a lifetime tally never can, so a bad run costs something and a good one wins it back.
		-- Facts rather than a score: the rating stays a pure function of them, so retuning what a good
		-- skewer is worth re-rates the whole window instead of needing the old entries rewritten.
		RecentSales = {},
	},

	ToLeaderstats = {
		Currency = { UseSuffix = true, Name = "Bux", Prefix = "$" },
	},
}
