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
tests each one against `Base:IsBlockFree` and hands back anything now off the ground its owner holds,
overlapping something already kept, or standing on the cells held for an unrepaired employee hut — the same
path the pickup hammer takes, so the structure returns to `OwnedStructures` and its contents to the player.
That's what a resized plot leaves behind. It bails out entirely on a base with no buildable ground, since
that's a broken base rather than a stranded build.

The hut is worth telling apart from the other two, since it takes cells on a base that was fine yesterday:
the sweep re-tests each stranded build against `Base:GetHutBlock` and names the hut in its notification
whenever it took any, rather than blaming the plots for it.

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

A cook paused by its owner leaving also carries the pair **`CookPausedElapsed`** and **`CookPausedAt`**: the
real seconds it had run at their last save, and the moment that save happened. `GrillerManager` restamps
`CookStartedAt` off both on their return, so the cook **runs on through the time away** — but only up to
`CookStates.GetOfflineStopBar`, a walk-up lead short of where Perfect opens. Offline time does the waiting;
the window itself can never be won or lost while nobody is watching. A cook already past that spot when its
owner left is simply frozen where it stood, since the alternative would be rewinding it. Both fields are
dropped by the write that resumes the cook, so a record only ever carries them while its owner is away.

**`SkewerStand`** — the sell stall's display: an array (max 6) of cooked skewers in placement order. One
stand per base, so a plain list rather than slot-keyed. A record a waiting custom order wants is held for
that customer by `Uid` while it walks over, and every other customer skips it. The hold itself is never
saved: it is read off the live order (`CustomOrderNpcManager:GetHeldStandSkewerUid`), so it can't outlive
the customer it was held for.

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

**`HiringBoard`** — the same shape for the worker board: `{ Seed, Hired }`, where `Hired` marks which of the
window's four slots this player has already taken. It rotates on its own clock at twelve and a half
minutes, and a stale `Seed` reads as nothing hired, so it self-cleans on every rotation rather than growing
forever.

`Hired` is a **dense array of booleans**, not a `{ [slot] = true }` map, and that is deliberate. Player data
round-trips through a DataStore, which hands integer keys back as strings — a sparse table saved as
`{ [2] = true }` returns as `{ ["2"] = true }`, and `Hired[2]` would silently read nil for a returning player.
The board is per-player rather than server-wide: the four candidates are shared, but hiring one doesn't take
them off anybody else's board.

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

**`ActiveCustomOrder`** — the order they are part-way through, absent when there isn't one. It has no
template entry: absent *is* the resting state, and a template default would make "no order" and "an order
with nothing in it" indistinguishable. Written by `SaveActiveOrder` the moment the order is owed — as the
offer card goes up, and again as the deal is struck — so it rides the ordinary auto-save rather than
depending on a last save that a crash or a shutdown can skip. `SaveActiveOrderOnLastSave` only restamps
the clock on the way out, so an order carries the time it actually had left rather than the time it had
when it was struck; miss that and you come back with a more generous clock, not with nothing. A customer
walking over to collect a BBQ held for it on the stand is still owed its order, so it banks as `Accepted`
too; the BBQ saves with the stand, and the restored customer claims it again before it steps aside. Cleared in
`_recordOutcome`, which every outcome funnels through — so a new outcome added later cannot forget to
clear it and leave a ghost customer returning forever. `_runGuardedVisit` clears it too when a restore
never gets its customer up, since a saved order both the roll and the next restore step over would
otherwise cost that player every order they were owed for the rest of the file's life.

`Phase` is `Pending` (asked, unanswered) or `Accepted` (deal struck, clock running), and it decides where
the restored visit re-enters: a pending one asks again with a fresh `OFFER_TIMEOUT`, an accepted one goes
straight back to waiting. An accepted one carries **`SecondsLeft`** rather than a deadline: the clock is
banked where it stood and restamped on return, so time offline never runs it down. A wall-clock deadline
would mean every rejoin found a dead order, since the clock is only three to five minutes — unlike
`LastCustomOrderVisit` beside it, which *is* wall-clock precisely because a cooldown should keep running
while you're away. This is the last of the three doctrines a saved clock can take, and the only one still
fully frozen: a cook's `CookPausedElapsed` banks the same way but then spends the time away against a
ceiling, because a cook has a safe place to stop at and an order does not.

`Counts` is deliberately not saved: it is `countIngredients(Ingredients)`, and keeping a second copy of
the same fact in the profile only creates something to fall out of step.

**`CustomOrderHistory`** — the last `Rating.ORDER_WINDOW` resolved orders, oldest first. This
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

## Employee hut

**`HutRepaired`** — whether the hut has been repaired, as a plain top-level boolean rather than an `Unlocks`
entry. It isn't an unlock because no `LockStyle` swaps one model for another, and because the repaired hut
isn't rendered from a level at all: repairing hands the player a `RepairedHut` **structure**, so from that
moment it lives in `Structures`/`OwnedStructures` like any other build and moves with the hammer. The flag is
only what stops it being bought twice.

**`HutRepairEndsAt`** — when a running repair lands, absolute on `workspace:GetServerTimeNow()` so it
finishes while the player is offline, with `-1` as the resting value. The two keys together make three states:

| `HutRepaired` | `HutRepairEndsAt` | State |
|---|---|---|
| `false` | `-1` | broken, buyable |
| `false` | a stamp | repairing |
| `true` | `-1` | repaired, and the hut is a placed structure |

Nothing sweeps it. `EmployeeHutManager` arms a `task.delay` for convenience, but `CompleteRepair` re-reads
the stamp and is the only authority, so a missed or doubled timer costs nothing — and a stamp already in the
past on handover simply completes there, which is the whole offline case. The deadline is republished onto the
base model as an attribute because player data only reaches its owner and a *visitor* has to see the countdown
too, the same reason griller cook stamps are mirrored onto their slot.

The broken hut is base furniture rather than a structure, posed by `Base:ApplyHut` onto the cell
`Base:_cacheHutBlock` works out from `EmployeeHut.CELL_X`/`CELL_Z`/`CELL_ROTATION` in the base's own lattice —
there is no marker part, so both hut states measure off the same cell and the repair swaps the model without
moving it. It reserves the cells the repaired one will land on (`Base:IsBlockFree` takes `HutRepaired` so
nothing can be built there first), and the reservation lifts the instant the flag is written — which is why
`EmployeeHutManager:CompleteRepair` writes it *before* placing the hut.

It's in `TutorialManager`'s `PROGRESS_RESET_KEYS` alongside `Plots`, which is less obvious than it looks:
`PurchasePlot` blocks unfinished players, but `GrantPlotFromProduct` calls it with `skipCurrencyCost`, which
skips the tutorial check — so a Robux plot buyer can own plot 1 mid-tutorial and repair the hut. Keeping it
would leave a repaired hut with no plot under it.

**`Employees`** — the hired staff, keyed by a uid minted at hire. Each entry is
`{ Role, Skill, Body, Name, Cosmetics, Slot?, Carrying?, Load?, HiredAt }`.

`Skill` is stored **0-1, not as stars**. `Rating.ToStars` is what turns it into the 4.25 the player reads, so
the star scale lives in exactly one place and retuning `Rating.MAX_STARS` moves everyone already hired rather
than stranding them on an old scale. Every behaviour number is derived from it and none are stored — a
`Config.Employees` curve is a worst value at 0 stars, a best at 5 and a gamma bending between them, so
rebalancing employees is a config edit and never a migration.

`Role` is one of `Config.Employees.ROLES` and never changes. An employee works one station, so its star means
one thing; a base is staffed by hiring three of them, not by assigning three jobs to one.

**`Slot`** is the hut slot that worker is equipped in, `1` upward, and absent while unequipped. Only an
equipped worker is on `EmployeeManager`'s roster with a rig in the world; an unequipped one is nothing but its
record, so equipping it later is an ordinary add. Owning is uncapped — a worker hired is kept for good, and
every hire starts unequipped — while how many can be out is how many slots are unlocked. Which worker sits in
a slot is **scanned for rather than stored a second time** on the slot side, since a second copy would only be
something to fall out of step. Unequipping leaves `Carrying` and `Load` on the record, so a worker put back
to work picks straight back up what it was holding.

**`HutSlotsUnlocked`** — how many hut slots are unlocked, counted from slot 1, so `3` means slots 1 to 3. A
**count rather than a set** because slots are bought strictly in order: `EmployeeHutManager:PurchaseHutSlot`
only ever sells the next one, and the price of each slot is `Config.EmployeeHut.SLOT_PRICES[slot]`. The
default is `1` because slot 1 comes with the repair; equipping into any slot still requires `HutRepaired`.

Slots 2 and 3 are also sold for Robux (`Config.EmployeeHut.SLOT_PRODUCT_IDS`), and a receipt grants **whichever
slot is next when it lands**, not the slot its button showed — the same doctrine as the `BaseUnlocks` products.
A paid receipt can't be refused, so it must never name a slot that a currency buy or a second receipt has
already unlocked; the product only sets the price.

It belongs to the **player, not a hut**. `HutStorage` is keyed by structure uid, but picking a hut up and
placing it again mints a new uid, and slots paid for with currency can't be allowed to vanish on a move. It's
in `TutorialManager`'s `PROGRESS_RESET_KEYS` beside `Employees`.

Portraits are **not** saved. `EmployeeManager:BakeEmployeePortrait` dresses one per worker on handover and at
hire, into a disabled `EmployeePortraits` ScreenGui in the owner's `PlayerGui` — which only that player is
sent — and the hut panel clones them into its viewports.

**`Cosmetics`** is `{ Hair?, Hat?, Face? }`, asset ids grouped by the `HumanoidDescription` field each is
written to rather than by what it looks like — a fair few classic hairs are catalogued as hats, and one
applied as hair is silently dropped. It is copied off the board's roll at hire, so a worker keeps the face it
was advertised with long after that board has rotated away.

**`Carrying`** is the non-obvious one: the skewer in that employee's hands between stations, in
`StickModel.StickRecord` shape. It is deliberately **not** written into `FilledSticks` — that key materialises
a Tool in the owner's backpack and force-equips it, which is not what a skewer being carried across the base
by someone else should do. Keeping it here instead means a rejoin or a server restart mid-pipeline resumes
rather than destroying the skewer, and it is what makes the state machine's `Idle` state a pure router: an
employee always boots into `Idle`, and what it is carrying decides where it goes. Firing one hands whatever it
holds back through `StickManager:AddFilledStick`, so nothing goes off the books.

**`Load`** is the maker's equivalent: the stick and loose ingredients it drew out of a hut store and is
carrying to a stand, as `{ HutUid, StickId?, Ingredients }`. It exists for the same reason as `Carrying` —
stock that has left a hut but not yet reached a stand is in flight and would otherwise vanish on a crash or a
rejoin. Firing a maker returns it to the player's inventory rather than to the hut, since the hut it came from
may since have been picked up.

Nothing about where an employee *is* — its state, the station it has claimed, when its cook is due — is saved.
That is all re-derived on load, which is why a state id is only ever mirrored onto the rig as an attribute.

**`HutStorage`** — what each placed hut holds for the staff, `[structureUid] = { Ingredients, Sticks }`, both
halves shaped `[id] = amount` exactly as the player's own `Ingredients` and `Sticks` are.

**Keyed per hut, not per player.** A base can carry several huts, and each fills its own store, so they can be
stocked differently for different jobs. That also puts it in the same family as `Grillers` and `StickStands`:
a structure that holds something keys it by uid, and `BaseManager.STRUCTURE_CONTENTS` hands it back when the
structure is picked up. The entry is written on the **first deposit**, so an untouched hut has no entry at all
and that pickup path skips it outright.

It is deliberately **not** the player's own inventory. Employees only ever spend what was put in a hut, which
is what stops a maker helping itself to a Mythic the player was saving. The prompt takes loose ingredients and
empty sticks only — a filled skewer is the cooker's to carry, and carries a whole record besides.

Returning a hut's stock on pickup writes the counts back **directly** rather than through
`IngredientManager:GrantIngredient`. That method records an obtain against `IngredientIndex`, so routing a
player's own stored stock through it would count everything as newly discovered and inflate their index.

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

**`RecentSales`** — the last `Rating.SALE_WINDOW` skewers sold, oldest first. What a stall
reputation averages over — a rolling window can fall as well as climb, which a lifetime tally never can.
Stored as **facts rather than a score**, so retuning what a good skewer is worth re-rates the whole window.

An entry is `{ StickId, Ingredients, CookState, Sauce?, Mutation?, Value }`. `StickId` and `Ingredients`
are what the **Menu** trait reads — how varied the menu is, how dear, and how full the skewers go out.
Entries written before that trait existed carry neither and **cannot be backfilled**, since the ingredients
were never recorded; `Rating.ScoreMenu` skips those rather than scoring them zero, and the window heals
itself as they age out.

## Sauce dispensers (dormant)

**`SauceDispensers`** — `[slotId] = { Size, Sauce?, Remaining, Skewer? }`, a plated skewer carrying the
`Uid` it came in with. `Remaining` starts at the size's `Capacity` (and tops up on a size upgrade),
dropping one per skewer sauced. A pour in progress also carries `Saucing` and `SauceStartedAt`, so an
interrupted one still finishes across a rejoin.

**`SauceBottles`** — bottles carried, one stacking tool each. Using one on a dispenser loads that flavour
and fills it to the size's `Capacity`.
