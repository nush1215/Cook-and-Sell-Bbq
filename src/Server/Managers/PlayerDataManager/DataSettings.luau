return {
	PlayerDataTemplate = {
		Currency = 100,
		TotalPlaytime = 0,

		-- Core Game
		Unlocks = {
			SauceDispenser = 0, -- the Sauce Dispenser
			RollingStands = 1, -- The gambling thing
			RollSpeed = 1, -- how long one pull takes; level 1 is the slowest (see Config.Rolling)
		},

		-- Plots bought, keyed by folder name. Priced off how many, not which -- see docs/player-data.md
		Plots = {}, -- [plotId] = true

		-- The build, keyed by a uid minted at placement. Cells and quarter-turns, not poses -- see docs/player-data.md
		Structures = {}, -- [uid] = { Type, CellX, CellZ, Rotation }
		-- Owned but unplaced. Seeded with one of each, since a new player needs both to have a game at all
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
		-- Each stand's last unclaimed pull, held with no expiry. SpeedLevel is stamped on the roll, not read live
		PendingRolls = {}, -- [standId] = { IngredientId, RolledAt, SpeedLevel }
		-- Rolls since each tracked tier or better landed. Counted per roll, not per pull -- see docs/player-data.md
		Pity = {}, -- [tierId] = ingredient rolls since that tier or better

		-- Index
		-- [ingredientId] = lifetime number obtained; the key's presence marks it discovered
		IngredientIndex = {},

		-- Sticks. A record is { StickId, Ingredients, Cooked?, CookState?, CookProgress?, Sauce?, Mutation?, Uid? } -- see docs/player-data.md
		Sticks = {}, -- [stickId] = amount owned
		-- [structureUid] = { StickId, Ingredients, Cooked? } placed on that stand
		StickStands = {},
		-- The sell stall's display: up to 6 cooked skewers in placement order. One stand per base, so a plain list
		SkewerStand = {}, -- { { Uid, StickId, Ingredients = { ingredientId }, Cooked = true, Sauce?, Mutation? }, ... }
		FilledSticks = {}, -- [uid] = { StickId, Ingredients, Cooked?, Sauce?, Mutation? } held as a distinct tool
		-- [structureUid] = the skewer on that griller, with its cook stamps. See docs/player-data.md
		Grillers = {},

		-- Sauce Dispenser
		-- [slotId] = { Size, Sauce?, Remaining, Skewer? }; a pour in progress adds Saucing and SauceStartedAt
		SauceDispensers = {},
		-- Bottles carried, one stacking tool each; using one loads that flavour and fills to Capacity
		Sauces = {}, -- [sauceId] = bottles owned

		-- Crates
		-- Unopened crates. Opening spends them up front, before the show plays, and settles the roll server-side
		Crates = {}, -- [crateId] = amount owned
		-- When the tutorial's crate can be opened; -1 is none pending. Absolute, so it runs while offline
		TutorialCrateTimer = -1,

		-- Stick Shop
		-- Per-window purchases; a stale Seed means the window rolled over, so Bought reads as empty
		StickShop = { Seed = 0, Bought = {} }, -- Bought = [stickId] = amount bought this window

		-- Grill & Stand Shop
		-- The same per-window ledger for structures, with its own Seed since the two shops run separate clocks
		GrillStandShop = { Seed = 0, Bought = {} }, -- Bought = [structureId] = amount bought this window

		-- Sell Stall
		-- When the last rich customer was sent. Wall-clock, so a rejoin can't hand out a fresh one
		LastRichVisit = 0,
		-- Standing refusals and when the last was. The count written back is the decayed one -- see docs/player-data.md
		SaleRefusals = { Count = 0, At = 0 },
		-- Whether a customer has ever countered them; the first is given, since the tutorial can't teach declining
		SeenHaggle = false,
		-- Whether a rich customer has ever visited; the first is given, so meeting one isn't down to luck
		SeenRichCustomer = false,

		-- Codes
		RedeemedCodes = {}, -- code strings already claimed, one claim each forever

		-- Group Reward
		GroupRewardClaimed = false, -- one claim per player, forever; also hides the HUD's Gift button

		-- Tutorial
		-- The onboarding runs once; leaving unfinished wipes gameplay progress on the way out
		TutorialCompleted = false,
		-- Furthest funnel step reached, for analytics only. An index into that variant's own funnel
		TutorialStep = 0,

		-- Stats
		-- Lifetime counters, flat at the top level because IncrementDataKey and the leaderboards index it only
		SkewersCooked = 0, -- cooks settled at a griller, however they turned out
		SkewersSold = 0, -- skewers a customer walked off with, counting each one of a bulk haul
		SalesCompleted = 0, -- customers served; a rich customer clearing the stand is one of these, not six
		SalesDeclined = 0, -- offers turned down or left to lapse, so a stall that turns people away shows it
		IngredientsBought = 0, -- ingredients claimed off a rolling stand
		SticksBought = 0, -- sticks bought from the stick shop, however they were paid for
		SkewersSauced = 0, -- skewers that came off a dispenser with a flavour on them
		TotalEarned = 0, -- every dollar ever taken in, boosts included; Currency is only what's left of it
		-- [cookStateId] = lifetime cooks settled there; grows on demand, so a new CookStates entry needs nothing
		CookStateCounts = {},
		-- The sell-side counterpart, kept apart because the two diverge -- see docs/player-data.md
		SoldCookStateCounts = {},
		-- The last RECENT_SALES skewers sold, oldest first. Stored as facts, so retuning re-rates the whole window
		RecentSales = {},
	},

	ToLeaderstats = {
		Currency = { UseSuffix = true, Name = "Bux", Prefix = "$" },
	},
}
