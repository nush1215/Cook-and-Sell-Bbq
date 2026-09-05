# Balance notes

Design rationale for the tuning configs under `src/Shared/Config/`. The configs hold the numbers; this
holds the reasoning behind them, so it stays findable without living as prose inside the code.

## Ingredients

An entry authors three knobs: its **Tier** (the band — cook time, sale multiplier, label colour, fallback
price), its **Price** (where in that band it sits), and its **Chance**, written as the player reads it:
1 in this many rolls.

### The 100% rule

`1/Chance` summed over every ingredient must come to 1. At 1.05 there is 5% more promised than a roll can
hand out, and every ingredient is really 5% rarer than its number — so adding one at "1 in 20" means
bumping others up to pay for it. Labels render the *real* odds (authored Chance scaled by that sum) and a
load-time warn says which way to nudge.

**This is not optional**: Roblox requires accurate odds on random items sold for Robux, and ingredients
are (`Ingredients.RobuxProductIds`).

Adding an ingredient is therefore never a local edit. A new entry's share has to come out of the others,
which in practice means re-solving the whole column rather than picking a number for the newcomer.

### The tier ladder

| Tier | Price | CookTime | ValueMultiplier | PityThreshold |
|---|---|---|---|---|
| Common | 100 | 10 | 1.3 | — |
| Uncommon | 3,000 | 24 | 1.1 | — |
| Rare | 18,000 | 40 | 1.07 | 65 |
| Epic | 65,000 | 60 | 1.05 | 350 |
| Legendary | 100,000 | 85 | 1 | 650 |
| Mythic | 400,000 | 110 | 1 | 1,500 (inert) |

**Price** is the anchor a tier's entries are priced *around* — move it to shift a whole tier, reprice the
entries to change how far apart they sit. Price is both what an ingredient costs off a stand and what its
sale value is figured from, so the two always move together: repricing changes how much is riding on a
roll, never whether it's a good deal.

The jump from Common to Uncommon is deliberate and it is not small. A common is pocket change and
everything above it is something to save for. What that buys is a rolling stand that can land on a thing
the player cannot pay for yet, which is the want the whole ladder runs on — the gap is the feature, not a
band that needs closing.

**CookTime and ValueMultiplier climb together**: the good stuff is the slow stuff, so a rare buys a longer
wait for a better return rather than a strictly better ingredient. Common doesn't move — near enough nine
rolls in ten land there, so it stays the quick baseline everything else is measured against. CookTime is
an anchor, not a flat rate: each entry names its own, fanned around the tier's number by what the food
actually is (dense things that must cook through at the top of the band, small wet things at the bottom).

**ValueMultiplier is the smaller half of what rarity pays, and it has to stay that way.** Price already
separates the tiers by more than a thousand times end to end, so this only decides how much better the
return is per dollar spent — 3.1x on a common against 5.3x on a legendary. It used to run to 4.2 at the
top, set when the price ladder was flat enough to need the help; against today's prices that was
multiplying an enormous gap by a large number, and the tail of the roster ran away with the economy.

Steepening this is almost never the fix: repricing a tier moves what it pays, this moves whether it's a
good deal, and only the second is what the knob is for.

Ballpark for a new entry — **Chance**: Common 9–51, Uncommon 55–137, Rare 170–450, Epic 700–1.2K,
Legendary ~2K, Mythic ~10K. **Price**: Common 75–260, Uncommon 1K–7K, Rare 10.5K–30K, Epic 50K–85K,
Legendary 100K; past that, omit Price and take the tier's. Mythic ships empty on purpose — headroom for
the luxurious stuff (wagyu, lobster, truffle) that costs nothing to leave sitting there. These bands are
what's left once the chance column is re-solved; they'll move again the next time the roster grows.

### Pity

A tier naming a `PityThreshold` gets a counter in player data; once that counter reaches it,
`IngredientRollingManager` forces the next roll to that tier. It is counted in **rolls**, not lever pulls,
so a six-stand base reaches it in a sixth of the pulls and the guarantee means the same to everybody.
Common and Uncommon name none — at 1 in 1.2 and 1 in 7 there's no drought to protect anyone from.

The thresholds are tight on purpose: short enough that the counter, not luck, is what mostly delivers the
rare tiers. Lamb averages 2,200 rolls on its own odds, and a guarantee at 650 means about three in four of
them arrive on the counter — a Legendary is something a player grinds *to* rather than gets lucky into,
which is the feel this ladder is tuned for. Rare at 65 against its 46-roll average is the mildest rung;
Epic and Legendary lean on pity progressively harder.

A counter watches "this tier **or better**", so it's walked rarest first: a Lamb clears the Rare counter
as well as its own, and pity can never force a Rare onto someone who just pulled a Legendary. What a
forced roll draws from is that tier's **own** entries, not the whole band — paying out the band instead
would hand Lamb out on Rare pity at about forty times its own rate (Lamb being a fortieth of the Rare band
by weight, while the Rare counter fires roughly twenty times as often as the Legendary one).

#### Real rates run ahead of the labels — on purpose

Chance is deliberately left alone to account for pity. Pity forces rolls that wouldn't otherwise have
landed, so a tracked tier turns up markedly more often than its label reads. At today's thresholds that is
not a rounding difference — measured over three million rolls:

| Band | Label | Really | Ratio |
|---|---|---|---|
| Rare | 1 in 52 | 1 in 40 | 1.30x |
| Epic | 1 in 442 | 1 in 297 | 1.49x |
| Legendary | 1 in 2,200 | 1 in 563 | 3.91x |

The labels are the authored odds and stay that way: pity is meant to be something the player feels rather
than reads. **So don't "fix" a rate that comes in ahead of its label** — the gap *is* the pity, and it
widens as a `PityThreshold` tightens. Re-measure it if the thresholds move; an earlier revision solved for
these rates and folded them back into Chance, and git history has that if a true-odds display ever wants
the numbers.

Worth knowing rather than acting on: understating odds is the forgiving direction for Roblox's accuracy
requirement — players get more than promised — but a 3.91x understatement on Lamb is a long way from the
authored number.

The thresholds don't re-solve themselves. Rebalance the chance column and the guarantees keep their old
numbers while the odds behind them move — which matters less here than it would on a loose ladder, since
the odds were never doing much of the work.

### Load-time checks

Three things are checked at load rather than left to be noticed in-game:

1. **Chance sum** within `CHANCE_SUM_TOLERANCE` of 100%. The tolerance is set where drift would start to
   show rather than at zero — a 1% miss turns "1 in 20" into "1 in 20.2", which still prints 20.
2. **Pity threshold order**, compared against the tier below rather than each tier's own drought. At these
   thresholds the drought barely gets a say, and warning about that would be warning about the design.
   Whatever a tier's odds say, it can't arrive more often than its counter allows — so a rarer tier given
   the shorter threshold really does turn up more often than the commoner one above it, and the whole
   ladder reads backwards.
3. **Tier overlap**, on both Chance and Price. A Common typed at 1 in 40 next to an Uncommon at 1 in 30
   reads as a bug to anyone who sees a "rare" turn up more than an uncommon; a Common at $600 next to an
   Uncommon at $400 makes the cheaper thing the rarer one. Every tier must be strictly dearer and strictly
   rarer than the one under it, so the room to fan an entry out is whatever sits between its tier and the
   next.

### Other knobs

- `SALE_VALUE_MULTIPLIER` (1.45) — the global economy dial, on top of every tier's ValueMultiplier. Raise
  it to make selling more lucrative across the board; retune ValueMultiplier to change how steeply rarity
  pays.
- `ADDITIONAL_SLOT_FACTOR` (0.75) — what each slot past the slowest adds, as a fraction of its own
  CookTime. The skewer cooks in one piece, so the slowest ingredient sets the length and the rest only add
  heat to shift, which is what makes capacity worth paying for: a full stick isn't a full stick's worth of
  waiting. Short of 1 so filling a stick pays, and clear of 0 so it still costs something — value has no
  falloff at all, so at 0 an extra slot would be free money.
- `ProductPriceBands` — thresholds rather than a band named per entry, so a new ingredient places itself
  from its Price alone. The last repricing moved every entry above Common by ten times or more and this
  list never needed touching, which is the point of it. The `T1: Corn - Jalapeno` style labels go stale on
  any repricing and are worth re-deriving rather than trusting.
- `COOL_TIER_INDEX` — where the ladder starts being worth making a fuss over: a landing here or above gets
  the cool sting, and it's the floor a teaser draws from. A position rather than a list of ids, so a tier
  added above Rare is celebrated automatically.

## Cook states

A skewer passes through three bands along the 0–1 cooking bar, then two more that only a skewer nobody
came back for reaches. The first three are fixed fractions of the bar, so a client reads them straight off
the progress it already derives from `CookStartedAt` — only the bar's *length* varies per skewer. Past the
end of the bar, states take over on `Overtime`: wall-clock seconds rather than a fraction, so a quick
skewer and a slow one get the same time to notice and react.

`RAW_END` also sizes the cook itself: an ingredient's `CookTime` is the seconds until it first reads
cooked, so a run is that stretched over the whole bar. Widening the gap between `RAW_END` and
`PERFECT_END` is what makes the window more forgiving.

| State | Ends | Multiplier | OfferMin–Max | CounterChance | CounterCap |
|---|---|---|---|---|---|
| Raw | RAW_END | 1 | 1 – 1.05 | 30 | 1.1 |
| Perfect | PERFECT_END | 1.8 | 1.1 – 1.35 | 90 | 1.55 |
| Cooked | 1 | 1.35 | 1.05 – 1.3 | 80 | 1.45 |
| Overcooked | +20s | 0.9 | 1 – 1.15 | 50 | 1.26 |
| Charred | +60s | 0.8 | 1 – 1.05 | 40 | 1.14 |

### The negotiation gap

Every `OfferMin` sits at or above 1, so an offer never comes in under the estimate the player was shown —
a bad cook is punished through `Multiplier` rather than a second lowball on top. `OfferMax` must stay
above its own `OfferMin`; the pair goes straight to `Random:NextNumber`.

`CounterCap` must sit above `OfferMax`, and **the gap between them is the whole negotiation**: each round
closes a fraction of the distance left to the cap. That gap narrows down the quality ladder (0.2x perfect
to 0.05x raw), which is why the cap is per state — one global cap would let a charred skewer haggle harder
than a perfect one. Keep some gap even at the bottom, or a counter spends a bubble and moves nothing.

Per-state notes:

- **Raw** barely clears what its ingredients cost — a loss to eat, not a wall to hit. `CounterChance` is
  higher than it deserves because this is what a brand-new player is selling and the counter-offer has to
  be *shown* rather than told. The cap keeps that honest: 0.05x of headroom moves the price by under 1%,
  so they meet the mechanic without raw skewers becoming worth haggling. It is also the only band asking
  for a `StopHold` — the take prompt is up for the whole cook, and a stray press here throws away the run
  rather than settling it. Its toast is the one about what *didn't* happen: the cook is banked, not lost.
- **Perfect** is the baseline every ingredient price is tuned against, not a bonus on top of one.
- **Cooked** — overshooting is a nick, not a penalty: a player who looked away still has a sellable skewer.
- **Overcooked** — past the bar the haggle narrows rather than the offer dipping under the estimate.
- **Charred** has the narrowest range of any state, and the narrowness lives in the cap rather than the
  chance: a customer counters happily, there's just nothing above 1.05 to reach into. A counter that
  visibly moves nothing teaches the state's worth better than a roll that silently fails.

### The bar warps (`GetBarElapsed`)

All three warps live in one function because it is the one place the server's stop and the client's bar
both derive from — a caller that skipped one would draw a bar the stop doesn't resolve against.

- **`windowStretch`** widens the perfect window in real time without moving where it sits on the bar, so
  the bar still fills on the same second and Overtime still starts there. Absent or 1 is the identity.
- **`instability`** swings the rate either side of 1 all the way up the bar, so the fill surges and stalls.
  It too leaves the fill second untouched.
- **`cookProgress`** enters the timeline part-way along, for a cook resumed from an earlier raw pull.

`cookProgress` is added **before** both warps: a bank is a head start along the cook, not a position on
this grill's bar, and both warps can only keep the bar filling on `cookTime` if the total they're handed
is what has to reach it. The cost is that a bank measured off a wobbling bar is spent on the steady axis
underneath — under a second of drift at the tuned figures, across a relight that resets everything visible
anyway. `windowStretch` is applied **after** the wobble, since `windowStart` is a fraction of `cookTime`
*on the bar*, so the stretch has to be handed bar seconds.

#### The instability curve

The rate is a sinusoid, `rate(t) = 1 + a*sin(w*t + phase)`. What's applied is its integral, in closed form
so a client joining mid-cook draws exactly the bar one that watched it all is drawing:

```
bar(t) = t + (a / w) * (cos(phase) - cos(w*t + phase)),   w = 2*pi*cycles / cookTime
```

Three properties of that shape are the point:

1. **Strictly increasing** for any `a < 1` (that's just `rate(t) > 0`), so the bar never runs backwards and
   a stop can't settle a band the player watched go by. `MAX_INSTABILITY` is what holds it there — at
   exactly 1 the bar stalls dead at the bottom of a cycle, and past it the bar runs *backwards*,
   un-browning food. It is clamped where it's read, not where it's authored, so a typo can't break it.
2. **`cycles` is a whole number**, so `bar(cookTime) == cookTime` whatever the phase — an unstable grill
   costs the timing, not the cook. Never below one, so even the shortest skewer gets a lurch.
3. **Identity past the bar**, which Overtime's wall-clock seconds require. The rate jumps at that seam
   unless phase is zero, but the fill is pinned full from there so nothing shows it.

The phase is stamped per cook: fixed at zero, the surges would land on the same places every time and each
recipe would be one lottery drawn once rather than something to watch.

#### `GetBarRate` and `GetElapsedForBar`

`GetBarRate` is taken as a central difference rather than differentiated by hand, for two reasons: the
warps live in exactly one place and the stretch leg is piecewise, so a written-out derivative would be a
second copy of that shape to keep in step with; and the slope genuinely jumps at each stretch seam, which
a difference smears across one frame instead of snapping. `RATE_EPSILON` is one frame, so the sample spans
what the eye does — much finer and the difference of two near-equal seconds is float noise. Cheap enough
to call per frame.

`GetElapsedForBar` is the other direction, and is solved by **bisection** rather than rearranged: the
instability term is `t` plus a cosine of `t`, which has no closed form (Kepler's equation). Exact rather
than approximate, because the map is strictly increasing for any amplitude under 1, so the target sits in
exactly one place. It is *not* per-frame cheap, and every argument is fixed for the cook's whole run, so
it is solved once as the cook opens.

## Selling — ordinary customers

`Shared/Config/SellNpc.luau`. A sale: skewer goes on the stand → a customer walks over → thinks about it
→ leaves (and another comes) or offers → the player accepts or declines → declining may get a better
price, up to `MAX_COUNTER_ROUNDS` times → it pays, steps back, and eats.

A MIN/MAX pair is one setting with a random range, not two settings. The opening offer, haggle chance and
haggle ceiling are **not** here — they vary by cook state and live on `CookStates.Data`. Gotcha:
`INTERESTED_CHANCE` is out of 1, but `CounterChance` there is out of 100.

### Sell value

A skewer's sell value is its ingredients' shop cost, plus a slice of the stick's
(`Sticks.SALE_RETURN_FACTOR`), times the stick's tier boost, its sauce and its cook state. So $1,000 of
ingredients on a $2,500 gold stick is **$4,163 cooked perfectly** and **$1,850 charred**. Sauce is a
no-op today — `Sauces.Data` ships empty.

`HELD_ESTIMATE` — the billboard guess over a held skewer, as a multiple of sell value. Kept at or below 1
while every state's `OfferMin` sits at or above it, so an opening offer always beats the guess. Each
skewer's spot in the range is fixed by its own id, so the number never changes on re-equip. Higher = the
guess creeps toward the real price; past 1, skewers sell for less than they were promised.

### Tuning guide

| Knob | Higher | Lower |
|---|---|---|
| `SPAWN_DELAY` | slower money | customers appear almost instantly |
| `RETRY_DELAY` | rejections hurt more | barely noticeable |
| `ARRIVE_DISTANCE` | they stop short, disconnected from the stand | they can get stuck on the last step |
| `STAND_SPACING` | the line spreads past the stand | they overlap |
| `STAND_ROW_OFFSET` | a deeper stagger | the rows flatten into one line |
| `WALK_TIMEOUT` | stuck customers hang around longer | long walks get cut off early |
| `DECIDE_DURATION` | more suspense, slower selling | snappier, less of a moment |
| `DECIDE_FLICK` | calmer flicking | faster, more frantic (equal = no wind-down) |
| `INTERESTED_CHANCE` | nearly everyone buys, the thinking moment stops mattering | tenser but slower |
| `LEAVE_DELAY` | time to read it | they leave right away |
| `COUNTER_CHANCE_FALLOFF` | long haggles stay possible | the second decline nearly always ends it |
| `COUNTER_INCREASE` | jumpier rounds eating most of the gap at once | pushing barely moves the number |
| `MAX_COUNTER_ROUNDS` | the ceiling comes back into reach | it's unreachable and `CounterCap` is decorative |
| `HAGGLE_PITCH_STEP` | obvious escalation, cartoonish fast | rounds stop sounding distinct |
| `OFFER_TIMEOUT` | players can step away mid-offer | the queue frees sooner, slow players lose offers |
| `OFFER_NUDGE_INTERVAL` | fewer reminders, more offers lost | nagging, and the toast crowds the screen |
| `MIN_OFFER_SPREAD` | the penalty stops biting near 1 | those states go deterministic |
| `EAT_BACK_DISTANCE` | they get out of the way properly | they eat in front of the stand |
| `EAT_SPREAD` | eaters fan out wider | they stay closer to straight behind |
| `EAT_DURATION` | the place looks busy | they clear out fast |
| `NPC_POOL_SIZE` | more rigs in memory, fewer built during a rush | leaner, but a busy server clones extras |
| `FADE_DURATION` | a slower, softer fade | closer to an instant pop |

`SPAWN_DELAY` and `INTERESTED_CHANCE` are what an *established* player faces — a new one's spawn wait is
scaled by `EarlyBoost.MAX_SPAWN_SPEEDUP` and their walk-off share cut by
`EarlyBoost.MAX_DECLINE_REDUCTION`. `GUARANTEED_SPAWN_DELAY` is its own number because the range above is
balance and this is pacing: short enough not to read as the tutorial hanging, long enough that the
customer still walks up rather than materialising.

`COUNTER_INCREASE` is a fraction of the distance left to the cook state's `CounterCap` — **not** a
multiple of sell value. Closing a share of the remaining gap makes a haggle decelerate and can't overshoot
the ceiling, so nothing needs clamping. It is sized against `REFUSAL_OFFER_PENALTY` rather than on feel: a
push that lands has to be worth more than a push that misses costs, or haggling is a losing move and the
whole mechanic is decoration. Keep the pair low — reach for `CookStates.CounterChance` first, which makes
haggling reliable without making any one round bigger.

### The refusal penalty

Without it a reroll is free: the skewer goes back on the stand and the next customer prices it from the
full range again. Each standing refusal shifts the next opening range down by `REFUSAL_OFFER_PENALTY` of
sell value and adds `REFUSAL_RETRY_DELAY` to the wait — money removes the reason to reroll, time is the
half that can't feel unfair. The shifted range is floored at plain sell value, so declining stops paying a
bonus but never becomes a loss.

It is deliberately smaller than a landed counter-offer pays: if a refusal cost more than a push earns, the
arithmetic would tell the player never to haggle. What it must still beat is the free reroll — declining
everything to fish for a high opening roll.

`REFUSAL_GRACE` is how many refusals cost nothing. Declining once is the mechanic working as onboarding
taught it, so charging for that would teach them not to; the penalty is aimed at repeat refusals. `GRACE`
and `PENALTY_MAX` move together — the most anyone pays is `(PENALTY_MAX - GRACE)`. A completed sale sheds
one (`ForgiveSaleRefusal`). Stored in player data on the synced clock, so a rejoin can't wipe the slate.

| Knob | Higher | Lower |
|---|---|---|
| `REFUSAL_OFFER_PENALTY` | a couple of refusals gut the offer | the reroll is profitable again |
| `REFUSAL_DECAY` | the penalty hangs over a session | waiting it out beats selling |
| `REFUSAL_GRACE` | declining stays free for longer | the first no costs |
| `REFUSAL_PENALTY_MAX` | the floor is reached, nothing left to lose by declining forever | — |

`MIN_OFFER_SPREAD` is the narrowest the penalty may squeeze an opening range. Without it the ends
converge and the states opening at 1 quote the same number every time, which reads as a broken customer
rather than a penalised one. The penalty still lands; it just can't flatten the roll out of existence.

## Selling — rich customers

`Shared/Config/RichNpc.luau`. Every `CHECK_INTERVAL` the server looks over each player. If their stand
holds at least `MIN_SKEWERS`, their last rich visit was more than `COOLDOWN` ago, and a `SPAWN_CHANCE`
roll lands, one rich customer walks over, takes **every** skewer off the stand at once, and offers a
single lump sum for the lot. The player haggles over that one number as they would over one skewer.

Unlike a normal customer it never says no. The visit is rare and gated, so a wasted one would read as a
punishment for stockpiling rather than a reward — the rarity is the tension, not a coin flip.

Only what makes it rich lives in this config; how it walks, fades, stands and eats it reads off `SellNpc`.
Gotcha: `SPAWN_CHANCE` and `COUNTER_CHANCE` are both out of 100, matching the cook states' own
`CounterChance` rather than `SellNpc.INTERESTED_CHANCE` (out of 1).

Past the cooldown, the expected wait is `(100 / SPAWN_CHANCE) * CHECK_INTERVAL` — 150s at today's
numbers, about 5 minutes between visits once the cooldown is counted.

`BULK_MULTIPLIER` is the premium on top of the batch. Every skewer is first priced by its own cook state
exactly as a normal customer would price it, and the total is then multiplied by this — so cooking well
still pays, and selling in bulk pays on top of that. On six $1,000 skewers that's roughly **$7,050 of
normal offers turned into about $11,280 in one go**, against the several minutes of queue those six sales
would otherwise take.

`COUNTER_CHANCE` is set above a cooked skewer's 80 because a rich customer wants the whole haul and can
afford it, so pushing one is the better gamble. It still decays per round by
`SellNpc.COUNTER_CHANCE_FALLOFF`.

`OFFER_CAP_FACTOR` and `COUNTER_INCREASE` live here rather than on `CookStates.Data` because a mixed haul
has no single cook state. The increases are a **smaller** share of the gap than a normal customer's,
because `BULK_MULTIPLIER` has already carried the opening offer most of the way up: a haul opening around
1.96x against a 2.4x ceiling still has a wide gap left, and closing a normal customer's share of it would
move the lump sum by 10% at a time on the largest number in the game. These land it at 2–6% a round
instead, and a haul that opened high has least left to gain — the same way a well-cooked skewer does.

**The cap has to stay above the highest opening a haul can roll** (every skewer perfect, `1.35 * 1.6 =
2.16x`), or the gap a counter-offer works off would go negative.

| Knob | Higher | Lower |
|---|---|---|
| `SPAWN_CHANCE` | rich customers become the main way to sell | the stand fills and stays full |
| `MIN_SKEWERS` | rarer and bigger visits, commit to hoarding | more often, smaller hauls, less special |
| `COOLDOWN` | a longer dry spell, the stand refills between visits | they chain, stockpiling stops being the point |
| `APPRAISE_DURATION` | more of a pause to read the RichUI | it gets straight to the number |
| `BULK_MULTIPLIER` | hoarding beats normal selling so much the stand sits unused | no reason to wait for one |
| `COUNTER_CHANCE` | declining is nearly free, players always push | the first decline ends a sale worth several |
| `COUNTER_INCREASE` | each haggle round is a bigger jump | slow gains |
| `OFFER_CAP_FACTOR` | a lucky haggle pays enormously, every round jumps further | pushing flattens out early |
| `OFFER_TIMEOUT` | players can wander off and still come back | the stand frees sooner, slow players lose the biggest sale |

## Selling — checking customers

`Shared/Config/CheckingNpc.luau`. The only customer sent *because* there's nothing to sell. Every
`CHECK_INTERVAL` the server looks over each player: if their stand is empty, their last completed sale was
more than `SALE_IDLE_TIME` ago, their last checking visit was more than `COOLDOWN` ago and a `SPAWN_CHANCE`
roll lands, one walks in, waits out of the queue lane asking whether there's any BBQ going, and leaves
after `WAIT_DURATION`. If the player stocks the stand while it waits, it walks over and buys through the
ordinary flow — decide flip, offer, haggle, payout, all priced off `CookStates` exactly as any other sale.

It costs nothing to ignore, which is the point: it is a nudge back to the grill, not a demand. Past the
cooldown the expected wait is `(100 / SPAWN_CHANCE) * CHECK_INTERVAL` — 20s at today's numbers, so about
3 minutes between visits once `COOLDOWN` is counted, and only while the stand stays empty.

**A player who has never sold anything never draws one.** `LastSaleAt` starts at 0, and a zero stamp is
read as "still working towards their first" rather than "drifted off" — otherwise every new player would
be pestered while cooking their opener, and the tutorial (which sets `_guaranteed`) is skipped outright.

Only the cadence lives in this config; how it walks, fades and haggles it reads off `SellNpc`, the same
way `RichNpc` does. Gotcha: `SPAWN_CHANCE` is out of 100, matching the other two NPC configs.

| Knob | Higher | Lower |
|---|---|---|
| `SALE_IDLE_TIME` | only a real lapse draws one, most players never see it | one turns up between ordinary sales, and nagging starts |
| `SPAWN_CHANCE` | the lapse is noticed almost at once | the empty stand sits a while before anyone asks |
| `COOLDOWN` | one ask per lapse, easily missed | they queue up on a player who has genuinely stopped |
| `WAIT_DURATION` | there's time to run to the grill and cook one, so it converts | it's gone before the player reaches the stand |
| `ASK_INTERVAL` | it asks once and stands quietly | the bubbles overlap and it reads as spam |
| `LOITER_BACK_DISTANCE` | it hangs back, easy to miss from the grill | it crowds the lane a buying customer needs |

## Selling — custom orders

`Shared/Config/CustomOrderNpc.luau`. A rarer customer that skips the stand entirely: it names a recipe,
quotes one number, and gives the player a clock to roll for what they're missing, build it, cook it and
hand it over. It is the only thing in the game that makes a *named* ingredient worth wanting — everywhere
else the roster is a lottery to be cashed in.

Gated on 2 placed grillers **or** 2 ingredient roll stands, because an order is only a request if the
player has the machinery to fill it. Past the cooldown the expected wait is
`(100 / SPAWN_CHANCE) * CHECK_INTERVAL` — 75s at today's numbers, so about six minutes between orders
once `COOLDOWN` is counted. Deliberately rarer than a rich visit: this one interrupts what the player was
doing, where a rich one rewards what they already did.

Only what makes it a custom order lives in this config; how it walks, fades, stands and eats it reads off
`SellNpc`, the same way `RichNpc` does. Gotcha: `SPAWN_CHANCE` and `INSPECT_CHANCE` are out of 100.

**`SPAWN_CHANCE` does not govern the first one.** The moment a player reaches the requirement their
first order is *given* rather than rolled for, forced to the Direct variation and carrying a two-part
explanation of what a custom order is — the same guarantee `RichNpc` gets, for the same reason: whether
a player ever meets the feature should not be luck. So this dial sets the pace *after* the introduction,
and lowering it makes orders rarer without ever making the first one rarer. Its Direct variation is not
a coincidence either: opening a player's first encounter on a Not Interested verdict over their own
stand reads as a rejection. See `SeenCustomOrder` in docs/player-data.md.

### What it asks for

Slots are rolled 2--3 and then **capped by the roomiest stick the player owns**, so an order is never
wider than anything they could build it on. Each slot rolls a tier off `TIER_WEIGHTS` and then draws from
that tier's entries that are either already in stock or priced under `Currency * AFFORD_FACTOR`; a tier
with nothing reachable in it steps *down* rather than failing, so a poor player gets a common order
instead of no order.

`OWNED_WEIGHT_BONUS` is what stops an order reading as a shopping list: stock weighs three times as
heavily, so most orders start part-filled and the clock is spent on one or two things rather than all of
them.

### The quote, and what it is actually worth

The quote is **what a perfect exact fill earns**, priced off the requested ingredients on the player's
best owned stick cooked Perfect, times
`min(BASE_MULTIPLIER + TIER_STEP * (averageTierIndex - 1), MULTIPLIER_CAP)`. An all-common order badges
about `[+140%]`, a mixed-uncommon one about `[+152%]`, and a Legendary request reaches the cap. Against a
normal customer's 1.1--1.35x opening that is roughly 1.8x what the same skewer fetches off the stand.

**If it plays as too thin for the interruption, `BASE_MULTIPLIER` is the dial, not `TIER_STEP`** — the
first moves what an order pays, the second only moves how much better a rare request is than a common
one, which is a different question.

**Nothing is ever refused.** Any skewer can be handed over, and what it earns is graded:

```
payout = max(quote * accuracy * cookFactor, GetSellValue(delivered))
```

- `cookFactor` is `CookStates.GetMultiplier(delivered) / CookStates.GetMultiplier("Perfect")` — derived
  rather than authored again, so a cook state is worth the same *relatively* here as it is anywhere else
  in the economy, and retuning the ladder retunes this with it. Perfect 1, Cooked 0.75, Raw 0.56,
  Overcooked 0.5, Charred 0.44.
- `accuracy` is the share of the recipe that landed, less `EXTRA_INGREDIENT_PENALTY` per ingredient
  nobody asked for. Padding a stick out with cheap commons must not pay.
- **The floor is plain sell value**, the same doctrine as the refusal penalty above: a wholly wrong
  skewer banks exactly what it is worth, so it is never a loss, and never a premium either. Dumping junk
  on the customer is quietly *worse* than selling it off the stand, which is the incentive doing the work
  that a refusal would otherwise have to do — and a refusal on a timer would read as the feature
  punishing a player who did turn up with something.

The quote assumes their best owned stick, so delivering on a worse one slightly overpays. That is
deliberate: pricing off the delivered stick would let an order go unfulfillable.

### The clock

`Ingredients.GetTotalCookTime(ids) / CookStates.RAW_END + LEEWAY_BASE + LEEWAY_PER_INGREDIENT * slots`.

The division is not optional: `GetTotalCookTime` is *ingredient* seconds and the bar runs that over
`RAW_END`, exactly as `GrillerManager:StartCookRecord` does it. A clock built on the undivided figure
would be short by two thirds of the cook.

The leeway is split because the two costs scale differently: `LEEWAY_BASE` covers walking, building and
the trip to a grill however big the order is, while `LEEWAY_PER_INGREDIENT` covers rolling for and
claiming each slot, which is per-ingredient by nature. A 3-slot order with a Rare in it lands around
`5m 20s`.

### Biasing the rolls

While an order is live the rolling stand is steered toward what it still wants — but as a **pity
counter, not a reweighted table**. After `ROLL_PITY_THRESHOLD` rolls without one landing, the next is
forced to a still-missing ingredient, which is the same forced-roll path `DrawPityIngredient` already
uses. It sits *under* the tier guarantees, which are owed from hundreds of rolls back rather than from
this order, and *above* the teaser, which is only window-shopping.

This matters for the same reason the section above does: the authored `Chance` column stays the odds on
the label, and what changes is only how often a forced roll fires — which is already the documented gap
between the labels and the real rates. A flat reweighting would instead make every *other* ingredient
rarer than its printed number, which is the direction the 100% rule exists to protect.

| Knob | Higher | Lower |
|---|---|---|
| `SPAWN_CHANCE` | orders become the main way to earn | they're a novelty nobody plans around |
| `COOLDOWN` | orders are an event | they chain, and the normal loop stops mattering |
| `MIN_GRILLERS` / `MIN_ROLLING_STANDS` | opens later, when the player can definitely cope | opens onto a player who can't fill one |
| `INSPECT_CHANCE` | more visits open at the stand | they all cut straight to the ask |
| `SLOT_COUNT` | bigger recipes, longer clocks | orders stop feeling like recipes |
| `TIER_WEIGHTS` | rarer requests, more rolling | every order is commons |
| `OWNED_WEIGHT_BONUS` | orders are nearly filled already | every order is a shopping trip |
| `AFFORD_FACTOR` | orders reach past what they can pay for | only what's already in the box |
| `BASE_MULTIPLIER` | orders outpay everything else | not worth the interruption |
| `TIER_STEP` / `MULTIPLIER_CAP` | a rare request pays much better | tier stops mattering to the price |
| `EXTRA_INGREDIENT_PENALTY` | padding a stick is ruinous | padding is free |
| `LEEWAY_BASE` / `LEEWAY_PER_INGREDIENT` | comfortable, the clock stops biting | unfillable, and the timer is the whole feature |
| `OFFER_TIMEOUT` | players can wander off mid-ask | the cooldown frees sooner, slow players lose orders |
| `ROLL_PITY_THRESHOLD` | the steer is barely felt | the stand may as well hand it over |
| `HURRY_THRESHOLD` | a long anxious run-out | no warning worth having |

## Crates

`Shared/Config/Crates.luau`. A crate rolls one entry per slot from each of its groups; a group's chances
must add up to 100%, warned at load within `CHANCE_SUM_TOLERANCE` percentage points.

`MAX_OPEN_AT_ONCE` and the open cooldown are shared so the client's own debounce and the server's
authoritative one agree. The cooldown scales with the batch, so a single open frees up almost immediately
while a full ten holds the player for the length of the show.

### Meat crate

Every meat on the roster, and the one crate a Common belongs in: five draws is enough that chicken reads
as the bulk of a haul rather than as a dud slot.

**Deliberately not `Distinct`** — there are exactly five entries here, so drawing without replacement
would hand out one of each every single time and the crate would stop being a roll at all. The load-time
check can't catch that (it only warns when there are *fewer* entries than slots), so it is written down
here instead.

### Starter crate

The one **mixed pool** in the game: every slot draws sticks and ingredients against each other, so a crate
can come out all gear or all food. That's what it's for — the meat crate sells ingredients and the stick
shop sells sticks, and this is the one thing that sells both at once, which is what somebody who has just
started grilling actually needs.

It floors at **copper rather than bamboo** because this is also the crate the tutorial drops
(`TUTORIAL_CRATE_ID`), so for most players it's the first one they ever open: no slot in it should read as
a dud. **Gold is the chase**, because +20% on everything the stick carries is the biggest single thing a
stick does. **Diamond stays out of it**, being the one stick you're meant to have to buy.

Also deliberately not `Distinct`, for the same reason as the meat crate.

### The tutorial crate

The same crate the shop sells in bundles, given away once: a crate the player can go on to buy more of
reads as an offer, where a tutorial-only crate would be a one-off they never see again.

### Animation notes

- `SHELL_LINGER` has to outlive the land burst that fires with the pop, because those particles are
  parented to the shell's own PrimaryPart and go with it — which is why it is a good deal longer than the
  fade itself.
- `REWARD_RISE_TIME` must be long enough for the climb to read as a float rather than a snap. Short values
  fight the bob fading in over the same window, so below about half a second the rise gets twitchy again.
- `REWARD_SPACING` has to stay clear of `REWARD_DISPLAY_SIZE`, or the row overlaps itself — two round
  ingredients each reach half their size either side of centre, so the daylight between a pair is spacing
  minus size. Raising one means raising the other.
- The crash camera pull is deliberately soft, so the player keeps control — the camera is never made
  `Scriptable`, only locked to first person.
- The claim gate's slack is sized past a bad ping, so an honest claim is never turned away.

## Structures

`Shared/Config/Structures.luau`. The griller ladder is cheapest first. **A rung buys one of three things:
speed, steadiness, or what it stamps on the result.** A grill carrying none of them is the baseline.

- **Rusty Grill** is the only rung that's *worse* than the baseline rather than better: down on pace, and
  down on being able to time the window at all. Cheapest rung, so the first thing money buys is a grill
  that behaves. It is what a new player is seeded with (see `DataSettings`) — learning the timing on an
  unsteady grill is what makes the first upgrade worth buying.
- **The baseline grill** carries no `CookSpeed` or `CookInstability` on purpose; every other rung is
  written against it. Its line only reads as an upgrade because the Rusty rung sits under it.
- **The Shocked grill** takes a *chance* rather than the Golden Grill's promise, so it's priced as the
  gamble it is, and Shocked is worth less than Golden to match. Its `CookSpeed` sits deliberately below
  the Solar Grill's 1.5 — this rung isn't bought for pace.
- **The Golden Grill** is never charged in currency: `Restockable = false` keeps it out of the shop
  entirely, so its dev product is the only way to get one.

`CookSpeed` divides the **whole bar** rather than one band, so speed is a trade: the perfect window shrinks
with it. The burn past the bar doesn't scale — it's wall-clock seconds in `CookStates`.

`CookInstability` **costs no cook time** — the swing integrates out and the bar fills on the second it
always would (see `CookStates.GetBarElapsed`) — so it takes away the ability to *time* the window, not to
reach it. Held under `CookStates.MAX_INSTABILITY`: at 1 the bar stalls dead, past it it runs backwards.

`Mutation`/`MutationChance` live here rather than in `Mutations` so the stamp is read off the grill the
cook actually happened on. A missing `MutationChance` means it stamps every time, which is what separates
a grill whose mutation *is* the grill from one where it's an occasional bonus. Rolled server-side as the
cook settles, so it's neither predictable nor forgeable.

### Placement geometry

`CELL_SIZE` is studs per grid cell — a coarser grid is easier to place onto and blockier about what fits.
Keep it a whole divisor of a plot floor's width: extents round to the nearest cell, so a floor that isn't a
multiple of it leaves the lattice seams half a cell off the physical plot seams and the outer cells hanging
over the edge.

**Retuning it rewrites saved builds.** Data stores cells, not poses, and a cell index only means a distance
against the size it was saved at — so halving `CELL_SIZE` would otherwise collapse every existing build to
half its spread. `StructureCellSize` in player data records what each build was written under and
`BaseManager:RescaleStructureCells` rescales it on handover; anything that no longer fits afterwards is
handed back by `ReclaimStrandedStructures`. See `docs/player-data.md`.

A structure is measured against its **`Hitbox`** if it has one, else the model's bounding box. A Hitbox is
how a model *states* what it occupies rather than having it guessed, which is what lets a chimney hang off
the side without reserving a phantom cell. It must be a direct child, not found by descendant search — a
griller has models inside it and shouldn't inherit one of their hitboxes.

The footprint snaps to the **nearest** whole cell, not rounded up: rounding up reserves a phantom cell for
a slightly-oversized box, which makes two flush neighbours read as overlapping. It is derived from type
and rotation rather than stored, so data holds only what the player chose and can't disagree with the
config about how big a thing is.

Collision is plain integer AABB overlap and is the whole model: nothing is ever queried against the world,
so only the cells a structure claimed matter.

A structure drops in **from above at full size** — the opposite of a bought unlock rising out of the
ground (see `BaseUnlocks.LAYOUT_RISE`). The spring is shared, so only the start differs. The server waits
`PLACE_SETTLE_DELAY` before settling its own copy, because the drop is the client's to play and the server
has no signal for when the spring landed; that wait is also what makes a late-arriving client spring from
the settled pose (a no-op) rather than replay the drop on a structure built minutes ago.

## The early boost

`Shared/Config/EarlyBoost.luau`. A new player's head start: four dials that all fade out together over
lifetime earnings. Each dial says how high it starts; `THRESHOLD` is the one number saying how long they
all run. There is deliberately no dial for the curve between them.

### The dials

- **`MAX_INCOME_BONUS`** (0.5) — the bonus at nothing earned, as a fraction of the base amount: half again
  on every sale. Raise it to make the opening more generous *without* moving where it stops — it lifts the
  whole curve rather than lengthening it.
- **`MAX_SPAWN_SPEEDUP`** (0.3) — how much of the wait for a customer comes off at nothing earned, so
  `SellNpc`'s 8–15s range lands at roughly 5.6–10.5s for a brand-new player. It scales the whole range, so
  the spread stays proportional rather than the floor closing on the top. Higher = the opening sells
  faster; lower = it keeps the established pace and only the money differs.
- **`MAX_DECLINE_REDUCTION`** (0.5) — how much of the walk-off chance comes off, so `SellNpc`'s 1-in-5
  refusal is 1-in-10 for a brand-new player. It scales the *refusal share* rather than lifting
  `INTERESTED_CHANCE`, so 1 is the ceiling by construction and it can't overshoot into never refusing.
- **`MAX_TEASER_CHANCE`** (8%) — how often a pull is given over to showing off something out of reach:
  about one pull in twelve. Cheap to be generous with — it costs the one ingredient that stand would have
  rolled, and the lever is free — but it is still a pull that fed them nothing, so it wants to stay well
  short of common enough to read as the stand wasting their time.

**`TEASER_AFFORD_FACTOR`** — how many times over their Bux a teased ingredient must cost to count as out
of reach. At 1 it would only have to be a dollar clear and the next sale would close it, which makes it a
purchase they were about to make rather than something to play towards — the want is the whole point.

Measured against what they're **holding** rather than what they've earned, so it tracks a player who just
spent everything on a plot. That also means the pool climbs the ladder on its own as they get richer: $100
in hand draws from the whole cool roster, $10,000 from Lamb alone, and past $20,000 there's nothing dear
enough left to show them — the teaser bowing out on its own, before the fade gets to it.

### THRESHOLD, and why it is where it is

`THRESHOLD` (150,000) is the lifetime earnings at which the bonus has run out entirely — the length of the
head start. It is **in dollars rather than minutes on purpose**: a player who found a good loop gets
through it sooner than one still learning, which is the right way round.

What sets it is **where the fade is steepest, not where it ends**. Smoothstep sheds the bonus fastest at
the halfway mark, so what this has to do is land that on something the player is buying anyway — the
biggest drop wants covering by the biggest step up, rather than falling part-way between two of them where
nothing arrives to soften it.

What that something is has changed. This used to be sized at twice the fourth plot, back when plots were
the expensive thing; **ingredients are now**, and the ladder that matters is what a roll can land on and
be afforded. Traced against a fresh base, the steep part of the fade falls between roughly ten and fifteen
minutes in — exactly the stretch where Rare (about 6 min) gives way to Epic (about 10) and then Legendary
(about 17). Income sagging there is paid for by a roster that just got several times more valuable, so the
drop lands on an upgrade rather than on nothing.

**The number is the same 150,000 it was; the reason is not**, which matters because the old reason would
send anyone re-tuning this at the plot costs. Re-size it against ingredient affordability, and check what
the new midpoint lands on — moving a milestone onto it is as good a fix as moving the threshold.

### The curve

`getFade` is a **smoothstep**, so the fade is flat at both ends: the head start barely moves over the
opening, gives way through the middle, and eases into zero rather than arriving there still on a slope.

This used to be a tunable exponent, which is what made the early game read as *the game slowing down*. An
exponent can only ever be flat at one end, so whichever way it was set there was a stretch where income
visibly fell away — and the start is the worst place for that, being where the player has the fewest
upgrades of their own to cover the drop.

Every dial runs off this one fade, so none of them can drift onto its own curve or threshold. Each getter
returns the identity at and past `THRESHOLD` (0 for the additive ones, 1 for the multiplicative), so a
caller can apply it unconditionally.

## Boosts

`Shared/Config/Boosts.luau`. Timed consumables, held several at a time. **The biggest live one applies and
the rest sit under it**, each counting down on its own wall clock — so a stack is worth its longest boost,
not the sum of them, and nothing is banked by being suppressed. That falls out of the storage rather than
being enforced: `BoostManager:GetBoostMultiplier` is a max over the unexpired entries, which promotes the
next one on its own as the top expires. There is no queue, and so no queue to get out of step with the HUD.

Not to be confused with the *permanent* income boosts — gamepasses, friends in-server and the early boost —
which live on `CurrencyManager:GetPlayerBoostFraction` and are a different system entirely. A timed cash
boost would be an entry here that that function reads; the two compose rather than merge.

Expiry is stored **absolute, on `workspace:GetServerTimeNow()`** — the `LastRichVisit` doctrine, so a boost
survives a rejoin or a server hop and keeps running while offline. That the clock is client-synced is the
second half of it: the HUD counts down against the same number with no server tick behind it.

The one grant a player doesn't ask for is the reclaim apology. When `BaseManager:ReclaimStrandedStructures`
has to hand builds back because the plots no longer fit them, `GrantReclaimCompensation` gives a flat
**Luck 1.5x for 8 minutes**. Flat rather than scaled to how much was lost: it's an apology for the
interruption, not a valuation of the build — the structures and everything on them come back in full
regardless (see `docs/player-data.md`). `GrantBoost` announces itself, so the sweep's own toast only has to
say why the boost is coming.

### Luck

The one boost today. It scales the ingredient roll's weights and **nothing else** — the tier guarantees,
the custom-order steer and the teaser all sit above the weighted roll in `IngredientRollingManager` and are
left alone.

```
adjustedWeight = baseWeight ^ (1 / luck ^ LUCK_STEEPNESS)
```

`Ingredients.Weight` is already `1 / authoredChance`, so this is one exponent on a number the config
derives anyway. **At `luck = 1` it returns the weight bit-for-bit unchanged**, which is what lets the
roller apply it unconditionally with no branch — and is the regression test worth keeping: luck 1 must
reproduce today's table exactly.

**`LUCK_STEEPNESS` runs the opposite way to its name, and this is the trap.** A bigger value means a bigger
`luck ^ S`, means a *smaller* exponent, means *more* flattening. Legendary at 1.5x luck: `0.25` → 0.071%,
`0.5` → 0.106%, `0.75` → 0.152%. **0.25 is the gentle one.** Set the dial by measuring, never by the name.

Measured over three million rolls, with pity running:

| luck | Rare | Epic | Legendary | Common share |
|---|---|---|---|---|
| 1x | 1 in 40 | 1 in 297 | 1 in 563 | 85.1% |
| 1.25x | 1 in 34 | 1 in 236 | 1 in 517 | 82.7% |
| 1.5x | 1 in 30 | 1 in 195 | 1 in 472 | 80.7% |
| 2x | 1 in 25 | 1 in 144 | 1 in 391 | 77.5% |
| 3x | 1 in 19 | 1 in 95 | 1 in 281 | 73.1% |

**Luck does most for Epic and least for Legendary** — 52% against 19% at 1.5x — which is the opposite of
what a player buying it expects. The reason is the section above: 74% of Legendaries already arrive on the
pity counter, and luck doesn't touch pity. This is the accepted cost of leaving the guarantee alone. If it
ever needs fixing, the lever is scaling `PityThreshold` by luck as well, not steepening this.

### Why `MAX_LUCK` is 3

**Luck eats pity.** The share of Legendaries arriving on the counter goes 74% → 51% at 1.5x → 13% at 3x. Past
3x the guarantee stops being the floor it was built as, and the ladder goes back to being luck-delivered —
which is the thing this economy is deliberately not. Clamped in `GetLuckWeight`, where it is *read* rather
than where it is granted (the `MAX_INSTABILITY` precedent), so a bad grant can't reach the economy.

There is a second ceiling worth knowing before anyone raises this dial. **As luck climbs, every adjusted
weight converges on 1** — that is, on a flat draw over the roster. So the asymptote is shaped by *how many
entries a tier has*, not by rarity: Legendary tops out at 1 in 33 because Lamb is one entry of 33, and
Common at 45% because it has fifteen. Two consequences, both bad:

- Adding five commons weakens what maximum luck means, without touching a single `Chance`.
- Mythic ships empty, so it stays at 0% at any luck — and the day it gets one entry it inherits Lamb's
  ceiling exactly.

It also saturates: 100x to 1000x moves Legendary from 2.1% to 2.7%. A luck ladder built past ~10x would
have several rungs that feel identical. None of this bites in the 1.25x–3x band the boost ships in, which
is why the formula is fine as it stands — but going higher means solving the ceiling first, not raising the
clamp.

## Sticks

`Shared/Config/Sticks.luau`. Entries are ordered lowest to highest — array order *is* the tier, so wooden
is the cheapest and diamond the best. `Id` matches the model name under `Assets.Sticks`.

### `SALE_RETURN_FACTOR`

What slice of a stick's own Price comes back in the sale of the skewer built on it, so the tier a player
skewered on shows up in the payout rather than only in how many slots they got. **A sale destroys the
stick, so this is the stick being liquidated, never a refund.**

Higher = expensive sticks pay more of themselves off per sale. Past the point where the slice comes back
bigger than the Price it's a slice of, **the shop is a money loop**.

Where that ceiling sits depends on the whole multiplier stack, because the slice sits *inside* it (see
`StickModel.GetSellValue`) — so it's every multiplier a skewer can carry at once, on the luckiest sale:
`ValueBoost`, sauce, mutation, cook state, and a haggle run to `CounterCap`.

As the game ships today, with `Sauces.Data` empty, the worst case is the diamond on a golden grill cooked
perfect and haggled to the cap. Holding that case under 1 would need this at or below **0.105**, and it
sits above that on purpose:

| Case | Return on the stick's price |
|---|---|
| Gold, cooked perfect | 0.61x |
| Gold, haggled to the cap | 0.77x |
| Gold on a Shocked cook | 1.16x |
| Gold on a Golden cook | 1.35x |
| Diamond on a Golden cook | 1.43x |

An ordinary sale still cannot fund the stick; it takes a mutation stacked on a near-cap haggle to cross.
Golden Grill stamps every cook rather than rolling for it, so that one is a **standing edge rather than a
tail case** — it is Robux-gated and capped by how fast its owner can cook and sell, which is why it is
allowed to stand. What this must never do is cross on a plain sale; that is the loop the ceiling guards.

**Restoring `Sauces.Data` puts a 2.25x back into that stack and multiplies every figure above by it.** So
re-enabling sauces means dropping `SALE_RETURN_FACTOR` to ~0.045 in the same change, or the shop starts
printing.

This is the smaller of the two ways a tier reaches the payout; the other is `ValueBoost`, which scales the
whole skewer rather than crediting back a flat slice. Raise them together with care.

### `ValueBoost`

Set so **every stick pays for itself on Common ingredients** — the tier near enough nine rolls in ten land
on. That's the rule the ladder is built to, and it's what stops an upgrade from being a trap: buying up is
never worse than the stick below it, whatever the player happens to have to put on it.

It is *solved* rather than picked — the boost at which a stick's cost, its liquidated slice and its share
of the skewer's value cancel at a common's worth per slot — which is why the numbers aren't round.
**Reprice a stick and its boost has to be re-solved with it**, or that tier quietly goes back to losing
money on the only ingredients most players have.

Above common the boost is pure profit, and that's where the tiers are meant to be told apart. Wooden and
bamboo carry none on purpose: at $3 and $17 a slot their price is already noise, and what they sell is
capacity.
