--[[
    All the numbers that control the rich customer -- the rare bulk buyer.

    How a rich visit goes: every CHECK_INTERVAL the server looks over each player. If their stand holds
    at least MIN_SKEWERS, their last rich visit was more than COOLDOWN ago, and a SPAWN_CHANCE roll
    lands, one rich customer walks over, takes every skewer off the stand at once, and offers a single
    lump sum for the lot. The player haggles over that one number the same way they would over one
    skewer.

    Unlike a normal customer it never says no. The visit is rare and gated, so a wasted one would read
    as a punishment for stockpiling rather than a reward -- the rarity is the tension, not a coin flip.

    Anything ending in MIN and MAX is one setting with a random range, not two settings.

    What isn't here: how it walks, fades, stands and eats, all of which it shares with the normal
    customers and reads off SellNpc. Only what makes it rich lives here.

    One gotcha: SPAWN_CHANCE and COUNTER_CHANCE are both out of 100, matching the cook states' own
    CounterChance rather than SellNpc's INTERESTED_CHANCE (which is out of 1).
]]

--
local RichNpc = {}

-- Seconds between sweeps of the players on the server, and the chance out of 100 that any one eligible
-- player draws a rich customer on a given sweep. Together with COOLDOWN these set how often a rich one
-- turns up: past the cooldown, the expected wait is (100 / SPAWN_CHANCE) * CHECK_INTERVAL, so 150s at
-- these numbers -- about 5 minutes between visits once the cooldown is counted.
-- Higher CHANCE = rich customers become the main way to sell and normal ones stop mattering.
-- Lower = the stand fills up and stays full because nobody comes to clear it.
RichNpc.CHECK_INTERVAL = 10
RichNpc.SPAWN_CHANCE = 60

-- How many skewers have to be on the stand before a rich customer is worth sending. A bulk buyer that
-- turns up for one skewer is the whole feature wasted, so the roll doesn't even happen below this.
-- Higher = rich visits get rarer and bigger, and a player has to commit to hoarding for one.
-- Lower = they come more often for smaller hauls and the moment stops feeling special.
RichNpc.MIN_SKEWERS = 2

-- Seconds after a rich visit starts before that player can draw another. This is what stops a lucky
-- run of rolls from turning into a queue of rich customers.
-- Higher = a longer dry spell after each one, so the stand refills properly between visits.
-- Lower = they can chain, and stockpiling stops being the point.
RichNpc.COOLDOWN = 150

-- Seconds the rich customer spends looking over the haul before it names a price. Stands in for the
-- normal customer's decide beat, which it doesn't run -- it's already made up its mind.
-- Higher = more of a pause to read the RichUI and see what's happening. Lower = it gets straight to
-- the number.
RichNpc.APPRAISE_DURATION_MIN = 2
RichNpc.APPRAISE_DURATION_MAX = 3

-- The premium on top of the batch. Every skewer in the haul is first priced by its own cook state
-- (CookStates.Data's OfferMin/OfferMax), exactly as a normal customer would price it, and the total is
-- then multiplied by this -- so cooking well still pays, and selling in bulk pays on top of that.
-- On six $1,000 skewers that's roughly $7,050 of normal offers turned into about $11,280 in one go,
-- against the several minutes of queue those six sales would otherwise take.
-- Higher = hoarding for a rich customer beats selling normally by so much that the stand sits unused.
-- Lower = there's no reason to wait for one.
RichNpc.BULK_MULTIPLIER = 1.6

-- Chance out of 100 that declining gets a better price instead of the rich customer walking off. Set
-- above a cooked skewer's 80 because it wants the whole haul and can afford it, so pushing a rich one
-- is the better gamble. It still decays per round by SellNpc.COUNTER_CHANCE_FALLOFF.
-- Higher = declining is nearly free and players will always push. Lower = the first decline usually
-- ends a sale worth several normal ones, which stings.
RichNpc.COUNTER_CHANCE = 85

-- The most a rich customer will ever pay, as a multiple of the haul's total sell value, and how much of
-- the distance left to it each better price closes. A mixed haul has no single cook state, so the ceiling
-- lives here rather than coming off CookStates.Data's CounterCap the way a normal customer's does -- the
-- same reason COUNTER_CHANCE above is its own number.
--
-- The increases are a smaller share of the gap than a normal customer's because BULK_MULTIPLIER has already
-- carried the opening offer most of the way up: a haul opening around 1.96x against a 2.4x ceiling still has
-- a wide gap left, and closing a normal customer's share of it would move the lump sum by 10% at a time on
-- the largest number in the game. These land it at 2-6% a round instead, and a haul that opened high has
-- least left to gain -- the same way a well-cooked skewer does.
--
-- The cap has to stay above the highest opening a haul can roll (every skewer perfect, 1.35 * 1.6 = 2.16x),
-- or the gap a counter-offer works off would go negative.
-- Higher INCREASE = each haggle round is a bigger jump. Lower = slow gains.
-- Higher CAP = a lucky haggle pays out enormously, and every round jumps further. Lower = pushing
-- flattens out early.
RichNpc.COUNTER_INCREASE_MIN = 0.05
RichNpc.COUNTER_INCREASE_MAX = 0.1
RichNpc.OFFER_CAP_FACTOR = 2.4

-- How many times a rich customer will sweeten its offer, matching an ordinary one's cap for the same
-- reason -- see SellNpc.MAX_COUNTER_ROUNDS.
RichNpc.MAX_COUNTER_ROUNDS = 3

-- Seconds the rich customer waits for an answer before giving up. Shorter than a normal customer's,
-- since the whole stand is off the shelf while it waits and nothing else can sell.
-- Higher = players can wander off mid-offer and still come back to it.
-- Lower = the stand frees up sooner, but a slow player loses the biggest sale on offer.
RichNpc.OFFER_TIMEOUT = 25

return RichNpc
