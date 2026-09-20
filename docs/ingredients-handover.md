# Ingredients handover

State of the ingredient roster and its balance as of 2026-09-20, on branch `update-1.0`. Written for
whoever picks this up next. `src/Shared/Config/Ingredients.luau` is the source of truth — everything here
was read out of it, and it changes often, so re-derive before trusting any number below.

`docs/balance.md` is the wider balance document. Its Ingredients section was brought back in line with the
config in this session; the rest of it has not been audited (see Outstanding).

## What changed in this session

1. **12 ingredients added**, taking the roster from 53 live entries to 65. Across the whole branch that is
   **33 added** against `main`'s 33, so `update-1.0` roughly doubles the roster.
2. **Mythic opened.** The tier had shipped empty as headroom; Caviar and Mango Caviar are its first
   entries. Its `ValueMultiplier` went 1 to **1.18** (at 1 the rarest tier was the worst deal per dollar)
   and its `PityThreshold` 1,500 to **3,000**, which is no longer a placeholder — a populated tier gets a
   live counter.
3. **The chance column was re-solved on a different rule than last time** — see Decisions.
4. `ProductPriceBands` comment labels re-derived. No new band was needed; all 12 fell inside existing ones.

**The 12**, by tier:

- **Common** — Yellow Onion, Garbanzo
- **Uncommon** — Chicken Feet, Orange
- **Rare** — Sirloin
- **Epic** — Durian, Ribeye, Crocodile Meat
- **Legendary** — Beef Shank, Rib Rack
- **Mythic** — Mango Caviar, Caviar

## Rules that must hold

These are enforced at load by warnings in `Ingredients.luau`, or are conventions the file relies on.
Breaking them doesn't error — it warns, or silently misbehaves.

- **`Σ(1/Chance)` over all live entries must be ~1.** Tolerance is `CHANCE_SUM_TOLERANCE = 0.02`. Past
  that a load warning fires. Labels never lie regardless: `Chance` is corrected in place at load to the
  real odds, so a bad sum means the numbers you authored aren't the ones players see. Currently
  **99.9938%**. Roblox requires accurate odds on random items sold for Robux, so this isn't optional.
- **Each tier must be strictly rarer and strictly dearer than the one below it.** Two separate load
  warnings check this.
- **Within a tier, `Price` and `Chance` ascend together.** Convention, not checked. The cheapest entry in
  a tier is also its commonest.
- **`Id` must match the model name** under `Assets.Ingredients.Raw` *and* `.Cooked`. An entry missing
  either model is silently dropped at load — it won't roll and won't appear in the Index, with only a
  warning in the output. Display `Name` may differ (`BeefShank` → "Beef Shank").
- **`Icon` has no validation and no fallback.** A wrong or empty id renders nothing, and on an
  undiscovered Index cell that looks identical to the locked state, so it ships unnoticed.
- **Never change a shipped ingredient's `Price`.** The game is live; repricing changes the value of what
  players already hold. Only new entries get priced, fitted between existing neighbours. `Chance` is the
  exception — it moves so the column still sums to 100%.
- The file is **CRLF**. Tooling that rewrites it should preserve that.

## Current shape

| tier | entries | chance | price | cook | roll share |
|---|---|---|---|---|---|
| Common | 19 | 1 in 10–64 | 75–260 | 8–18s | 85.5791% |
| Uncommon | 21 | 1 in 122–285 | 1K–7K | 25–55s | 11.9940% |
| Rare | 12 | 1 in 365–1,175 | 10.5K–30K | 65–100s | 1.9092% |
| Epic | 7 | 1 in 1,350–2,400 | 55K–85K | 115–200s | 0.4004% |
| Legendary | 4 | 1 in 3,550–4,600 | 100K–150K | 225–280s | 0.1011% |
| Mythic | 2 | 1 in 17,000–24,000 | 300K–500K | 300–330s | 0.0100% |

Tier `ValueMultiplier` is 1.5 / 1.25 / 1.2 / 1.2 / 1.2 / 1.18 and `SALE_VALUE_MULTIPLIER` is 1, so a
perfect cook at a mid-range offer returns 2.57x on a Common, 2.14x on an Uncommon, 2.06x through
Legendary and 2.02x on a Mythic. The ladder **descends** — rarity is paid in price, not in rate of return.

Placement follows the ladder that was already there: garden veg and cheap staples in Common, everyday
fruit and cheap meats in Uncommon, showpiece produce and better cuts in Rare, luxury in Epic, whole roasts
in Legendary, and the two caviars alone in Mythic.

## Decisions taken, so they don't get undone by accident

- **The chance rule changed this batch.** The previous batch held every tier's roll share fixed, which
  split each share across more entries and made every individual ingredient rarer. That was rejected here,
  because Epic nearly doubled (4 → 7) and Legendary doubled (2 → 4) while the lower tiers barely grew, so
  the whole cost would have landed on the four things players chase — Lamb would have gone 1 in 3,550 to
  1 in 7,200, on top of 2,200 to 3,550 the batch before. Instead: **every shipped Epic and Legendary entry
  keeps its exact authored `Chance`**, those two bands widen to fit the newcomers (Epic 0.2295% →
  0.4004%, Legendary 0.0499% → 0.1011%), and Common pays for all of it. Uncommon and Rare hold their
  shares exactly, as before.
- The cost of that is **+21.7% expected profit per roll on label odds** — but that overstates it, because
  pity already forces most Epic and Legendary rolls. The real figure needs the simulation re-run.
- **Tier price bands are user-set** and unchanged: Uncommon 1K–7K, Rare 10.5K–30K, Epic 55K–85K,
  Legendary 100K–150K. Common sits at 75–260. Mythic's 300K–500K straddles its 400K anchor. Beef Shank was
  priced at 110K specifically so it slots between Lamb and Rib Rack and **Legendary's band doesn't move**.
- **Durian went to the Epic floor (60K)**, not Legendary. It fills the gap between Cheese and Dragon Fruit
  without reshuffling anything, and Epic was the better tier to absorb a seventh entry than Legendary a
  fifth. Legendary at 135K was the alternative and was turned down.
- **Beef Shank's cook time is 240s on purpose.** Longer than Lamb because it's the braising cut, but held
  short enough that its profit per second (485) lands above Lamb's (470) instead of deepening the
  Epic/Legendary profit-per-second sag.
- **Prices inside a tier look close together on purpose.** They're evenly spaced; the bands are just
  narrow for the entry count. They can't be spread further without either widening the band (which moves
  existing prices) or reordering entries.
- **Cook time is per-entry and thematic**, fanned around the tier's `CookTime`, which is only the fallback
  for an entry that doesn't name one. Unlike price, a cook time doesn't have to fall between its
  neighbours.

## Outstanding

- **24 models needed** — Raw and Cooked for each of the 12 new ids, named exactly (`YellowOnion`,
  `ChickenFeet`, `CrocodileMeat`, `BeefShank`, `RibRack`, `MangoCaviar`). Any that are missing get dropped
  at load with only a warning. The previous batch's 42 may also still be outstanding.
- **Lettuce still has a placeholder icon** (`rbxassetid://0`, marked TODO). Until it's replaced its Index
  cell is indistinguishable from a locked one. Also on the release-1.0 audit as a must-fix.
- **The label palette is crowded.** Nine meats now sit in red-brown (Sausage, Beef, Bacon, Sirloin,
  Ribeye, Beef Shank, Rib Rack, Lamb, Goat Leg) and several entries in yellow-gold (Corn, Cheese, Mango,
  Mango Caviar, Yellow Onion). No two `Color` values are identical, but several are close enough to be
  hard to tell apart in the stick UI. Worth a human eye.
- **Mythic's real rate has never been measured.** At a 1-in-10,000 band against a 3,000-roll counter it
  will run further ahead of its label than any other tier. `docs/balance.md`'s measured-rates table is
  marked stale and needs the 3M-roll simulation re-run for Epic, Legendary and Mythic.
- **Blue Cheese** has an icon but no model, so it's still left out. It would fit Epic or Legendary.
- **Duck** needs its assets before the commented block can be restored, and restoring it means re-solving
  the chance column around it.
- **The Index grid now has 65 cells.** Its ScrollingFrame lives in the Studio place file, not the repo —
  if it has a fixed `CanvasSize` rather than automatic, the extra rows will be cut off.
- **`MeatCrate` in `Crates.luau`** claims to hold "every meat on the roster" and is further from that than
  ever — Turkey, Bacon, Ham, Goat Leg and now Sirloin, Ribeye, Crocodile Meat, Beef Shank, Rib Rack and
  Chicken Feet aren't in it. The everyday pool has one free slot (the odds frame fits five); the prime-cut
  pool is full. Left alone deliberately.
- **`EarlyBoost.THRESHOLD` is 150,000** and was sized against ingredient affordability milestones from an
  earlier price ladder. Worth re-checking where its fade now falls.
- **Mythic's profit per second is roughly 3x Legendary's** (1,024–1,551/s against 470–567/s). That is what
  the tier's own anchors imply — 400K at 300s — rather than something the entries introduced, but if it's
  too hot the levers are the tier's `Price` or `CookTime`, not the two entries.
- **Only balance.md's Ingredients section was re-derived.** Its Cook states, offline and shop sections
  were not checked against their configs.

## How to check your work

There's no lint step — `selene.toml` exists but selene isn't in `aftman.toml`, and there's no Luau
interpreter available, so nothing here is compile-checked. Verify by parsing the config and by loading
the place in Studio.

After any edit, confirm:

1. The chance column still sums to within 0.02 of 1, and no two entries share a `Chance`.
2. No tier overlaps the one below on either chance or price.
3. Price and chance still ascend together inside every tier.
4. No duplicate icon ids — two ingredients sharing one means one is showing the wrong picture.
5. Every entry is inside its tier's price and cook band.
6. Braces balance and the file is still CRLF.

Then load in Studio and **watch the output window**, since all the load-time checks warn rather than
error, and a missing model removes an ingredient without saying much.
