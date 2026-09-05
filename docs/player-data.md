# Player data schema

Notes on the keys in `PlayerDataManager/DataSettings.luau`. The template holds the shape and defaults;
this holds the reasoning behind the ones where the shape is a decision.

## Core game

**`Plots`** — plots bought, keyed by name in the base's Plots folder. The starting plot isn't here: it's
the `START` cell in `Config.Plots`' grid, owned from handover. A plot is priced off *how many* of these
there are rather than *which*, so the choice is where to expand and never how much for.

**`Structures`** — the player's build, keyed by a uid minted at placement. `Type` names a
`Config.Structures` entry. Position is a **grid cell and quarter-turn rather than a pose**, for two
reasons: a player is handed whichever base is free, and a saved pose would rebuild on the wrong one; and a
cell is exactly what the client sends and the server validates, so what's saved is what was checked.

The cell is the *base's*, not a plot's — one lattice across the whole base (see `Shared.GridUtil`), so
buying a plot opens up cells rather than starting a new grid.

`Grillers` and `StickStands` are keyed by these same uids: whatever is sitting on each.

**`StructureCellSize`** — a cell index only means a *distance* against the `Structures.CELL_SIZE` it was
saved at, so that size is stored beside the cells rather than assumed. `BaseManager:RescaleStructureCells`
reads it on handover and, when it doesn't match the config, multiplies every cell by the ratio and restamps
it — a build survives the grid being retuned instead of collapsing toward the base's corner. The template
default is `4` because that's what every profile written before the key existed used; a new profile rescales
an empty table and gets stamped, which costs nothing.

Cells are re-checked on every handover too, not only at placement. `BaseManager:ReclaimStrandedStructures`
tests each one against `Base:IsBlockFree` and hands back anything now off the ground its owner holds or
overlapping something already kept — the same path the pickup hammer takes, so the structure returns to
`OwnedStructures` and its contents to the player. That's what a resized plot leaves behind. It bails out
entirely on a base with no buildable ground, since that's a broken base rather than a stranded build.

**`OwnedStructures`** — structures owned but not yet placed. A structure is only ever in one of the two
places, and picking one back up returns it here, so nothing is lost to a bad spot.

Seeded with one of each, since a new player needs a griller and a stand to have a game at all. The griller
is the bottom rung on purpose (see `Config.Structures`) — learning the timing on an unsteady grill is what
makes the first upgrade worth buying. The ids must be ones the config still has: BuildManager's reconcile
silently skips an unknown one.

## Skewer records

A skewer record is `{ StickId, Ingredients, Cooked?, CookState?, CookProgress?, Sauce?, Mutation? }`, and
everything but the first two is permanent once set, following the skewer wherever it goes.

- **`Cooked`** flips true once it's off a griller at all; **`CookState`** says how well that went.
- A **raw pull** carries neither, so it's indistinguishable from one never cooked. What it carries instead
  is **`CookProgress`**: how far up the bar it got, as a *fraction*, so setting it back down resumes there
  and means the same on whatever bar it resumes on. Always below `CookStates.RAW_END`, since anything past
  that band settles into `CookState` and clears it. Adding an ingredient wipes it (deliberately — see
  `StickStandManager`).
- **`Sauce`** is applied at a dispenser after cooking, so it only appears on `FilledSticks` and
  `SkewerStand` records.
- **`Mutation`** is the grill's doing rather than the player's — stamped as a cook settles, off the
  structure it settled on — so a BBQ is only mutated by the grill it was cooked on, and a raw pull never
  gets one. It multiplies the sell value and adds its particles.

A skewer sitting on a structure that only *holds* it (the sell stall, a sauce plate) also carries **`Uid`**,
the key it had in `FilledSticks`, so taking it back hands over the same skewer rather than a fresh one —
anything seeded off the uid, like the estimate over a held skewer, would otherwise move on a round trip. A
grill and a stick stand mint instead, since what comes off them is not what went on.

**`Grillers`** — `[structureUid] = a skewer record on that griller`. Setting one down starts its cook, so a
record here almost always carries `Cooking`, `CookStartedAt` and `CookTime` (the whole 0→1 run in seconds),
plus optionally `CookWindowStretch` and the `CookInstability`/`CookInstabilityPhase` pair — all three bend
the bar (see `CookStates.GetBarElapsed`). Every one is **stamped as the skewer goes down** rather than read
at the take, so the bar bends the same way from first frame to last, a rejoin included. A record without
them is one whose cook has been bought out with the Robux skip, sitting settled until collected.

A cook frozen by its owner leaving also carries **`CookPausedElapsed`**: the real seconds it had run at
their last save, which `CookStartedAt` is restamped off on their return so time offline doesn't advance it
(see `GrillerManager`).

**`SkewerStand`** — the sell stall's display: an array (max 6) of cooked skewers in placement order. One
stand per base, so a plain list rather than slot-keyed.

## Ingredient rolling

**`PendingRolls`** — each stand's last unclaimed pull. Held with **no expiry**, so a player can go and earn
the currency for an expensive one and come back, a rejoin included. The claim is gated on the roll
animation having had time to play; `SpeedLevel` is stamped on the roll rather than read live, so a level
bought mid-pull can't move the goalposts under an animation already playing.

**`PityCounters`** — ingredient rolls since one landed at each tracked tier *or better* (see
`Ingredients.PITY_TIERS`). A counter reaching its tier's `PityThreshold` forces the next roll to that tier;
whatever lands then clears every counter at or below it, so a Legendary doesn't leave a forced Rare queued
up behind it. Watching "or better" while paying out the tier itself is what makes the guarantee a floor.

Counted **per ingredient roll rather than per lever pull**, since a pull on six stands is six shots at the
tier: per pull, a six-stand base would reach pity on the same count having had six times the chances. So a
bigger base reaches pity in fewer pulls and the same rolls.

**`IngredientIndex`** — `[ingredientId] = lifetime number obtained`; the key's presence marks it discovered.

## Crates

**`Crates`** — unopened crates, one stacking tool each. Opening spends them **up front, before the show
plays**: the roll is settled server-side at that moment and handed over when the animation finishes, or by
the server if that client never gets there.

**`TutorialCrateReadyAt`** — when the tutorial's crate can be opened. `-1` is none pending or already
claimed; a past value is one sitting ready. Absolute rather than a countdown, so it keeps running offline.

## Shops

**`StickShop`** / **`GrillStandShop`** — per-player purchases for the current restock window. `Seed` ties
`Bought` to the window it was counted in; a stale `Seed` means the window rolled over, so `Bought` reads as
empty and resets on the next buy. Each shop has its **own** `Seed` rather than a shared one: the two run
separate clocks and either can be re-rolled on its own by its restock product.

## Sell stall

**`LastRichVisit`** — when the last rich customer was sent. Wall-clock rather than session-clock, so a
rejoin — or a hop to a server that's never sent one — doesn't hand out a fresh one.

**`SaleRefusals`** — turned-down offers still counting against the player, and when the most recent was.
Each drags the next opening offer down and lengthens the wait, which is what stops a declined skewer being
a free reroll. Forgiven one per `SellNpc.REFUSAL_DECAY` seconds, and **the count written back is always the
already-decayed one**, so a single stamp carries the whole decay. Wall-clock, as above.

**`SeenHaggle`** — whether a customer has ever countered this player. Their first is *given* rather than
rolled for (`SellNpcManager:_negotiateSale`), because the tutorial hides the Decline button and so can't
teach it. Saved rather than session-scoped, so a rejoin neither re-hands the lesson nor skips it.

**`SeenRichCustomer`** — whether a rich customer has ever visited. Their first is given rather than rolled
for (`SellNpcManager:TrySendFirstRichVisit`) the moment their stand first holds `RichNpc.MIN_SKEWERS`,
because otherwise whether they ever meet one is down to luck. Saved for the same reason as above.

**`LastSaleAt`** — when they last completed a sale of any kind. Written in
`StatsManager:RecordSaleCompleted` rather than in `SellNpcManager`, so rich hauls and custom order
deliveries stamp it too — it answers "are they still playing the game", not "did the sell stand fire".
**0 means they have never sold**, which the checking-customer roll reads as a player still working towards
their first rather than one who has drifted off, and so leaves alone. Wall-clock, as above.

**`LastCheckingVisit`** — when the last customer was sent to *ask* whether they had any BBQ for sale.
Wall-clock for the same reason as `LastRichVisit`, and stamped *before* the visit runs, so a long wait
can't let another be rolled the moment this one leaves.

## Custom orders

**`LastCustomOrderVisit`** — when the last order was put to the player. Wall-clock rather than
session-clock, so a rejoin, or a hop to a server that has never sent one, doesn't hand out a fresh one.
Stamped *before* the visit runs, so a long order can't let another be rolled the moment this one leaves.

**`SeenCustomOrder`** — whether one has ever visited. Their first is *given* rather than rolled for
(`CustomOrderNpcManager:TrySendFirstCustomOrder`) the moment they reach the requirement, because
otherwise whether they ever meet the feature is down to luck — and a first one that arrives unexplained
teaches nothing. Saved rather than session-scoped, so a rejoin neither re-hands the introduction nor
skips it. Same reasoning as `SeenRichCustomer` and `SeenHaggle` above.

The grant is also latched in memory for the session, because the saved key is written behind a yield
and three separate signals can race to be the one that reaches it.

**`CustomOrderHistory`** — the last `CustomOrderNpc.HISTORY_LENGTH` resolved orders, oldest first. This
is the `RecentSales` idiom and it is here for the same reason: a rating has to be able to fall as well as
climb, which a lifetime tally never can, and it is **stored as facts rather than a score** so retuning
what a good order is worth re-rates the whole window rather than leaving old entries priced by old rules.

An entry is `{ At, Outcome, Slots, TierIndex, Matched, Extras, CookState?, Mutation?, StickId?, Seconds,
SecondsLeft, Quote, Paid }`. Nothing here computes a rating — it records what a rating would need, so the
formula can be written and changed later without re-instrumenting the feature:

| Axis | Read from |
|---|---|
| Accuracy | `Matched / Slots`, penalised by `Extras` |
| Quality | `CookState` across the window |
| Promptness | `SecondsLeft / Seconds` |
| Reliability | share of `Outcome == "Delivered"` |
| Difficulty | `Slots` and `TierIndex`, so a hard order can count for more |
| Value realised | `Paid / Quote` |

`SecondsLeft` is zero on anything that never got a clock, which is what tells a lapsed order from one
handed over on the buzzer. `Outcome` is `Delivered`, `Expired`, `Declined` or `Ignored` — and a refused
order is kept rather than dropped, because a rating blind to refusals can't tell a picky player from a
busy one. `Declined` and `Ignored` are split because they are different failures: one is an answer, the
other is an offer that never reached the player, and only the second says the ask itself went unseen.

The flat counters beside it (`CustomOrdersOffered` through `CustomOrderCookStateCounts`, under Stats) are
the lifetime half: what a badge or an index entry reads, where the window above is what a rating averages.
`CustomOrdersOffered` counts at the **ask**, not the acceptance, for the same reason.

## Boosts

**`Boosts`** — timed consumables, keyed by a uid minted at the grant, each `{ Type, Amount, ExpiresAt }`.
`Type` names a `Config.Boosts` entry. Wall-clock and **absolute** rather than a remaining duration, the same
reasoning as `LastRichVisit`: a boost has to survive a rejoin or a hop to another server, and time off has to
count against it. `workspace:GetServerTimeNow()` rather than `os.time()` because it is client-synced too, so
the HUD's countdown needs no server tick behind it.

A player holds several at once and **the biggest one applies**, falling to the next as it expires. That is
not stored: `BoostManager:GetBoostMultiplier` takes a max over the entries still in date, which promotes the
next one on its own. So there is no queue, no "active" flag, and nothing that can disagree with the icons —
the HUD sorts the same list by the same rule. Suppressed boosts keep counting down, so a stack is worth its
longest boost rather than the sum (see docs/balance.md).

Swept every `Boosts.SWEEP_INTERVAL` by one pass over the players rather than a timer per boost, and capped at
`Boosts.MAX_ACTIVE`, which drops the weakest first. Every reader re-checks `ExpiresAt` itself rather than
trusting the sweep, since a roll can land in the gap between two of them.

## Tutorial

**`TutorialCompleted`** — the onboarding runs once. Leaving before finishing wipes gameplay progress on the
way out (see `TutorialManager.PROGRESS_RESET_KEYS`), so a rejoin restarts the sequence on a clean base.

**`TutorialStep`** — furthest onboarding funnel step reached; written for analytics, never read back. An
index into the funnel of whichever variant they ran, so it doesn't compare across variants.

## Stats

Lifetime counters, only ever climbing, unlike the inventories above. **Flat at the top level** rather than
nested in a `Stats` table: `IncrementDataKey`, `ToLeaderstats` and the ordered leaderboards all index the
top level only.

**`CookStateCounts`** — `[cookStateId] = lifetime cooks settled in that state`; a key's presence marks it
reached at least once (the `IngredientIndex` idiom). Grows on demand, so adding a `CookStates` entry needs
nothing here.

**`SaleStateCounts`** — the sell-side counterpart. Kept apart because the two diverge: a charred skewer can
be cooked and never served, and a rich customer sells six at once. Distinct from `RecentSales`, which ages
entries out and so can't answer what the player has ever sold.

**`RecentSales`** — the last `StatsManager.RECENT_SALES` skewers sold, oldest first. What a stall
reputation averages over — a rolling window can fall as well as climb, which a lifetime tally never can.
Stored as **facts rather than a score**, so retuning what a good skewer is worth re-rates the whole window.

## Sauce dispensers (dormant)

**`SauceDispensers`** — `[slotId] = { Size, Sauce?, Remaining, Skewer? }`, a plated skewer carrying the
`Uid` it came in with. `Remaining` starts at the size's `Capacity` (and tops up on a size upgrade),
dropping one per skewer sauced. A pour in progress also carries `Saucing` and `SauceStartedAt`, so an
interrupted one still finishes across a rejoin.

**`SauceBottles`** — bottles carried, one stacking tool each. Using one on a dispenser loads that flavour
and fills it to the size's `Capacity`.
