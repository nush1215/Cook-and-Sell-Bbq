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

		-- Plots bought, keyed by name in the base's Plots folder. The starting plot isn't here -- it's the
		-- START cell in Config.Plots' grid, owned from handover. A plot is priced off how many of these
		-- there are rather than which, so the choice is where to expand and never how much for.
		Plots = {}, -- [plotId] = true

		-- The player's build, keyed by a uid minted at placement. Type names a Config.Structures entry;
		-- position is a grid cell and quarter-turn rather than a pose, because a player is handed whichever
		-- base is free and a saved pose would rebuild on the wrong one -- and because a cell is exactly
		-- what the client sends and the server validates, so what's saved is what was checked.
		--
		-- The cell is the base's, not a plot's: one lattice across the whole base (see Shared.GridUtil),
		-- so buying a plot opens up cells rather than starting a new grid.
		--
		-- Grillers and StickStands below are keyed by these same uids -- whatever is sitting on each.
		Structures = {}, -- [uid] = { Type, CellX, CellZ, Rotation }
		-- Structures owned but not yet placed. A structure is only ever in one of the two places, and
		-- picking one back up returns it here, so nothing is lost to a bad spot.
		--
		-- Seeded with one of each, since a new player needs a griller and a stand to have a game at all.
		-- The griller is the bottom rung on purpose (see Config.Structures) -- learning the timing on an
		-- unsteady grill is what makes the first upgrade worth buying. The ids must be ones the config
		-- still has: BuildManager's reconcile silently skips an unknown one.
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
		-- Each stand's last unclaimed pull. Held with no expiry, so a player can go and earn the currency
		-- for an expensive one and come back, a rejoin included. The claim is gated on the roll animation
		-- having had time to play; SpeedLevel is stamped on the roll rather than read live, so a level
		-- bought mid-pull can't move the goalposts under an animation already playing.
		PendingRolls = {}, -- [standId] = { IngredientId, RolledAt, SpeedLevel }

		-- Index
		-- [ingredientId] = lifetime number obtained; the key's presence marks it discovered
		IngredientIndex = {},

		-- Sticks (cooking). A skewer record is { StickId, Ingredients, Cooked?, CookState?, CookProgress?,
		-- Sauce?, Mutation? }, and everything but the first two is permanent once set, following the skewer
		-- wherever it goes.
		--
		-- Cooked flips true once it's off a griller at all; CookState says how well that went. A raw pull
		-- carries neither, so it's indistinguishable from one never lit -- what it carries instead is
		-- CookProgress, how far up the bar it got as a *fraction*, so the next light resumes there and
		-- means the same on whatever bar it resumes on. Always below CookStates.RAW_END, since anything
		-- past that band settles into CookState and clears it. Adding an ingredient wipes it (deliberately;
		-- see StickStandManager).
		--
		-- Sauce is applied at a dispenser after cooking, so it only appears on FilledSticks and SkewerStand
		-- records. Mutation is the grill's doing rather than the player's -- stamped as a cook settles, off
		-- the structure it settled on -- so a BBQ is only mutated by the grill it was cooked on, and a raw
		-- pull never gets one. It multiplies the sell value and adds its particles.
		Sticks = {}, -- [stickId] = amount owned
		-- [structureUid] = { StickId, Ingredients = { ingredientId }, Cooked? } placed on that stand
		StickStands = {},
		-- The sell stall's display: an array (max 6) of cooked skewers in placement order. One stand per
		-- base, so a plain list rather than slot-keyed.
		SkewerStand = {}, -- { { StickId, Ingredients = { ingredientId }, Cooked = true, Sauce?, Mutation? }, ... }
		FilledSticks = {}, -- [uid] = { StickId, Ingredients, Cooked?, Sauce?, Mutation? } held as a distinct tool
		-- [structureUid] = a skewer record sitting on that griller. A running cook also carries Cooking,
		-- CookStartedAt and CookTime (the whole 0 -> 1 run in seconds), plus optionally CookWindowStretch
		-- and the CookInstability/CookInstabilityPhase pair -- all three bend the bar (see
		-- CookStates.GetBarElapsed). Every one is stamped at the light rather than read at the stop, so the
		-- bar bends the same way from first frame to last, across a rejoin included.
		Grillers = {},

		-- Sauce Dispenser
		-- [slotId] = { Size, Sauce?, Remaining, Skewer? }. Remaining starts at the size's Capacity (and tops
		-- up on a size upgrade), dropping one per skewer sauced. A pour in progress also carries Saucing
		-- and SauceStartedAt, so an interrupted one still finishes across a rejoin.
		SauceDispensers = {},
		-- Bottles carried, one stacking tool each. Using one on a dispenser loads that flavour and fills
		-- it to the size's Capacity.
		Sauces = {}, -- [sauceId] = bottles owned

		-- Crates
		-- Unopened crates, one stacking tool each. Opening spends them up front, before the show plays --
		-- the roll is settled server-side at that moment and handed over when the animation finishes, or
		-- by the server if that client never gets there.
		Crates = {}, -- [crateId] = amount owned
		-- When the tutorial's crate can be opened. -1 is none pending or already claimed; a past value is
		-- one sitting ready. Absolute rather than a countdown, so it keeps running while offline.
		TutorialCrateTimer = -1,

		-- Stick Shop
		-- Per-player purchases for the current restock window. Seed ties Bought to the window it was counted
		-- in; a stale Seed means the window rolled over, so Bought reads as empty and resets on the next buy.
		StickShop = { Seed = 0, Bought = {} }, -- Bought = [stickId] = amount bought this window

		-- Grill & Stand Shop
		-- The same per-window ledger, for structures. Its own Seed rather than a shared one: the two shops
		-- run separate clocks and either can be re-rolled on its own by its restock product.
		GrillStandShop = { Seed = 0, Bought = {} }, -- Bought = [structureId] = amount bought this window

		-- Sell Stall
		-- When the last rich customer was sent. Wall-clock rather than session-clock, so a rejoin -- or a
		-- hop to a server that's never sent one -- doesn't hand out a fresh one.
		LastRichVisit = 0,
		-- Turned-down offers still counting against the player, and when the most recent was. Each drags
		-- the next opening offer down and lengthens the wait, which is what stops a declined skewer being a
		-- free reroll. Forgiven one per SellNpc.REFUSAL_DECAY seconds, and the count written back is always
		-- the already-decayed one, so a single stamp carries the whole decay. Wall-clock, as above.
		SaleRefusals = { Count = 0, At = 0 },
		-- Whether a customer has ever countered this player. Their first is given rather than rolled for
		-- (SellNpcManager:_negotiateSale), because the tutorial hides the Decline button and so can't teach
		-- it. Saved rather than session-scoped, so a rejoin neither re-hands the lesson nor skips it.
		SeenHaggle = false,
		-- Whether a rich customer has ever visited this player. Their first is given rather than rolled for
		-- (SellNpcManager:TrySendFirstRichVisit) the moment their stand first holds RichNpc.MIN_SKEWERS,
		-- because otherwise whether they ever meet one is down to luck. Saved rather than session-scoped, so
		-- a rejoin neither re-hands the visit nor skips it.
		SeenRichCustomer = false,

		-- Codes
		RedeemedCodes = {}, -- code strings already claimed, one claim each forever

		-- Group Reward
		GroupRewardClaimed = false, -- one claim per player, forever; also hides the HUD's Gift button

		-- Tutorial
		-- The onboarding runs once. Leaving before finishing wipes gameplay progress on the way out (see
		-- TutorialManager.PROGRESS_RESET_KEYS), so a rejoin restarts the sequence on a clean base.
		TutorialCompleted = false,
		-- Furthest onboarding funnel step reached; written for analytics, never read back. An index into
		-- the funnel of whichever tutorial variant they ran, so it doesn't compare across variants.
		TutorialStep = 0,

		-- Stats
		-- Lifetime counters, only ever climbing, unlike the inventories above. Flat at the top level rather
		-- than nested in a Stats table: IncrementDataKey, ToLeaderstats and the ordered leaderboards all
		-- index the top level only.
		SkewersCooked = 0, -- cooks settled at a griller, however they turned out
		SkewersSold = 0, -- skewers a customer walked off with, counting each one of a bulk haul
		SalesCompleted = 0, -- customers served; a rich customer clearing the stand is one of these, not six
		SalesDeclined = 0, -- offers turned down or left to lapse, so a stall that turns people away shows it
		IngredientsBought = 0, -- ingredients claimed off a rolling stand
		SticksBought = 0, -- sticks bought from the stick shop, however they were paid for
		SkewersSauced = 0, -- skewers that came off a dispenser with a flavour on them
		TotalEarned = 0, -- every dollar ever taken in, boosts included; Currency is only what's left of it
		-- [cookStateId] = lifetime cooks settled in that state, a key's presence marking it reached at least
		-- once (the IngredientIndex idiom). Grows on demand, so adding a CookStates entry needs nothing here.
		CookStateCounts = {},
		-- The sell-side counterpart. Kept apart because the two diverge: a charred skewer can be cooked and
		-- never served, and a rich customer sells six at once. Distinct from RecentSales below, which ages
		-- entries out and so can't answer what the player has ever sold.
		SoldCookStateCounts = {},
		-- The last StatsManager.RECENT_SALES skewers sold, oldest first. What a stall reputation averages
		-- over -- a rolling window can fall as well as climb, which a lifetime tally never can. Stored as
		-- facts rather than a score, so retuning what a good skewer is worth re-rates the whole window.
		RecentSales = {},
	},

	ToLeaderstats = {
		Currency = { UseSuffix = true, Name = "Bux", Prefix = "$" },
	},
}
