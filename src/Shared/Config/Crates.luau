--[[
    Every crate in the game, what's inside it, and the shape of the animation that opens it.

    A crate is a stacking backpack item that pays out several things at once. What it pays out is
    authored as a list of slot groups: "three ingredients, all different" and "one stick" are two
    groups on the same crate, each with its own weighted pool. A group's Count is how many slots it
    fills, and every slot is drawn separately -- so the odds below are per slot, not per crate.

    Chances are percentages, not the "1 in X" the ingredient roster is authored in. A crate slot
    lands on something every time and there are only a handful of candidates, so 40% is the number
    worth reading; and with Distinct groups the draws are conditional on each other, which a single
    "1 in X" couldn't honestly describe anyway. Each group's chances have to add up to 100 for the
    same reason the ingredient roster's do -- a group promising 105% is really handing out every
    entry 5% rarer than its label -- and a load-time warn says by how much when it doesn't.

    Distinct means a group won't hand out the same thing twice in one crate: each draw excludes what
    the group has already given. That's what stops a three-slot crate coming out Pork/Pork/Pork. It
    needs at least Count entries to draw from, which is checked at load.

    Type says which config an id comes from, and it can sit on the group or on the entry. On the
    group it's shorthand for writing the same word on every entry below it, which is all a group of
    one kind of thing needs. A group whose entries name their own Type is a mixed pool -- one Count,
    one set of chances, sticks and ingredients drawn against each other -- and that's still one pool,
    so its chances add up to 100 across the whole thing rather than per kind. The entry's Type wins
    where both are there, and load back-fills the group's onto every entry that left it out, so
    nothing downstream has to know the group's was ever only a default.

    The animation constants at the bottom are shared because the server gates the claim on them
    (GetOpenDuration), the same way Config.Rolling does for the rolling stands -- retuning the feel
    can't silently desync the two.
]]

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Assets
local Assets = ReplicatedStorage.Assets
local CratesFolder = Assets.Crates

-- Shared
local Shared = ReplicatedStorage.Shared
local Ingredients = require(Shared.Config.Ingredients)
local Sticks = require(Shared.Config.Sticks)

--
export type RewardType = "Ingredient" | "Stick"

export type RewardEntry = {
	Type: RewardType?, -- which config this id comes from; only needed in a mixed group, since load
	-- back-fills the group's own Type onto every entry that leaves it out
	Id: string, -- an Ingredients or Sticks id, depending on the resolved Type
	Chance: number, -- percent this entry fills one of the group's slots; a group's chances sum to 100
}

export type SlotGroup = {
	Type: RewardType?, -- the Type every entry below takes unless it names its own, and which manager
	-- grants them. A mixed group leaves this out and writes it on each entry instead.
	Count: number, -- how many of the crate's slots this group fills
	Distinct: boolean?, -- draw without replacement, so the group never gives the same thing twice
	Rewards: { RewardEntry },
}

export type Crate = {
	Id: string, -- also the name of the model under Assets.Crates
	Name: string,
	Color: Color3, -- the crate's colour wherever it's named in text, the same way an ingredient has one
	ExplodeColor: Color3, -- the flat colour every part turns when the crate goes neon and pops
	Icon: string?, -- rbxassetid for the backpack slot; falls back to whatever the CrateTool template carries
	RobuxProductIds: { [number]: number }?, -- Robux dev-product id per bundle, keyed by how many crates
	-- it grants. Products.luau generates one product per entry; a crate with none isn't sold for Robux.
	Contents: { SlotGroup },
	Model: Model, -- not authored below, back-filled from Assets.Crates
}

-- One rolled slot: what came out and which config it came from. This is what the server rolls, what
-- it ships to the clients on the crate model, and what it grants back.
export type Reward = {
	Type: RewardType,
	Id: string,
}

--
local Crates = {}

-- Most crates a player can open in one go, and the cooldown that open costs them. The cooldown
-- scales with the batch so a single open frees up almost immediately while a full ten holds them
-- for the length of the show. Shared so the client's own debounce and the server's authoritative
-- one agree.
Crates.MAX_OPEN_AT_ONCE = 10
Crates.OPEN_COOLDOWN_BASE = 1
Crates.OPEN_COOLDOWN_PER_CRATE = 0.2

-- How far a group's chances can add up to short of or past 100% before the load-time warn fires,
-- in percentage points.
Crates.CHANCE_SUM_TOLERANCE = 0.5

Crates.Data = {
	{
		Id = "MeatCrate",
		Name = "Meat Crate",
		Color = Color3.fromRGB(228, 96, 96),
		ExplodeColor = Color3.fromRGB(255, 214, 214),
		RobuxProductIds = { [1] = 3709025712, [3] = 3709025743, [10] = 3709025774 },
		Contents = {
			-- Every meat on the roster, and the one crate a Common belongs in: five draws is enough that
			-- chicken reads as the bulk of a haul rather than as a dud slot. Deliberately not Distinct --
			-- there are exactly five entries here, so drawing without replacement would hand out one of
			-- each every single time and the crate would stop being a roll at all. The load-time check
			-- below can't catch that (it only warns when there are fewer entries than slots), so it's
			-- written down here instead.
			{
				Type = "Ingredient",
				Count = 5,
				Rewards = {
					{ Id = "Chicken", Chance = 40 },
					{ Id = "Pork", Chance = 30 },
					{ Id = "Beef", Chance = 18 },
					{ Id = "Shrimp", Chance = 9 },
					{ Id = "Salmon", Chance = 3 },
				},
			},
		},
	},

	{
		Id = "GrillStarterCrate",
		Name = "Grill Starter Crate",
		Color = Color3.fromRGB(255, 138, 51),
		ExplodeColor = Color3.fromRGB(255, 219, 186),
		RobuxProductIds = { [1] = 3709322187, [3] = 3709322222, [10] = 3709322255 },
		Contents = {
			-- The one mixed pool in the game: every slot draws sticks and ingredients against each other,
			-- so a crate can come out all gear or all food. That's what it's for -- the meat crate sells
			-- ingredients and the stick shop sells sticks, and this is the one thing that sells both at
			-- once, which is what somebody who has just started grilling actually needs.
			--
			-- It floors at copper rather than bamboo because this is also the crate the tutorial drops
			-- (TUTORIAL_CRATE_ID below), so for most players it's the first one they ever open: no slot in
			-- it should read as a dud. Gold is the chase because +20% on everything the stick carries is
			-- the biggest single thing a stick does, and diamond stays out of it, being the one stick
			-- you're meant to have to buy.
			--
			-- Deliberately not Distinct, for the reason written on the meat crate above: five entries into
			-- five slots drawn without replacement would hand out one of each every single time.
			{
				Count = 5,
				Rewards = {
					{ Type = "Stick", Id = "CopperStick", Chance = 40 },
					{ Type = "Ingredient", Id = "Pork", Chance = 30 },
					{ Type = "Stick", Id = "TitaniumStick", Chance = 18 },
					{ Type = "Ingredient", Id = "Beef", Chance = 9 },
					{ Type = "Stick", Id = "GoldStick", Chance = 3 },
				},
			},
		},
	},
}

--[[
    Animation shape, shared because the server measures the open against it.

    The crate arcs out of the player's hands and lands, then starts to rattle -- jolting harder and
    climbing a little further off its slot on every beat. It hops once more, slams back down, and
    bursts on the impact: snapping to POP_SCALE while turning neon and fading out. Its contents come
    out of that flash, rise into a row centred on where the crate stood, hover, and fly into the
    player one after another.
]]

-- The throw out to the crate's slot on the ground.
Crates.THROW_START_HEIGHT = 2.5 -- studs above the owner's root the crate leaves from, roughly head height
Crates.THROW_DURATION = 0.4
Crates.THROW_ARC_HEIGHT = 10
Crates.THROW_STAGGER = 0.12 -- delay per crate in a batch, so ten don't all launch on the same frame
Crates.SETTLE_DURATION = 0.25 -- beat between landing and the first twitch

-- The twitch: a random rotation jolt per beat, accelerating, with the crate gaining a little height
-- each time so the rattle visibly builds instead of just getting faster.
Crates.TWITCH_COUNT = 12
Crates.TWITCH_INITIAL_WAIT = 0.3
Crates.TWITCH_WAIT_DECREMENT = 0.03
Crates.TWITCH_MIN_WAIT = 0.06
Crates.TWITCH_ANGLE = 20 -- max degrees off true on each axis
Crates.TWITCH_LIFT_PER_BEAT = 0.4 -- studs the crate climbs on each beat
Crates.TWITCH_LIFT_MAX = 4 -- as high as the rattle alone ever gets it
Crates.TWITCH_SETTLE = 0.25 -- held at the top of the rattle before the wind-up, so the hop reads

-- The wind-up and the slam: one last hop clear of everything, then straight back down onto the slot,
-- which is where it bursts.
Crates.WINDUP_LIFT = 3 -- studs above wherever the rattle left it
Crates.WINDUP_DURATION = 0.3
Crates.SLAM_DURATION = 0.2

-- The pop, on the frame the slam lands: scale up, go neon, fade out.
Crates.POP_SCALE = 1.5
Crates.POP_FADE_DURATION = 0.3
-- How long the faded shell hangs around before it's destroyed. It has to outlive the land burst that
-- fires with the pop, because those particles are parented to the shell's own PrimaryPart and go with
-- it -- which is why this is a good deal longer than the fade itself.
Crates.POP_LINGER = 1

-- The yellow every crate flash is drawn in: the land highlight, the pulse on each twitch, the one
-- before the hop, and the burst on each reward. One colour so the whole open reads as one thing.
Crates.FLASH_COLOR = Color3.fromRGB(255, 255, 117)

-- How long after a beat its effect lands: the dust under an idle hop trails the hop itself, and a
-- reward's burst trails the reward appearing, so neither reads as simultaneous.
Crates.LAND_EFFECT_DELAY = 0.13
Crates.SHOW_LOOT_DELAY = 0.1

-- The rewards rising out of the pop into their row.
Crates.REWARD_START_LIFT = 1 -- studs above the crate's own slot they set off from, so they leave from
-- inside the crate rather than from the ground under it
Crates.REWARD_START_SCALE = 0.2
Crates.REWARD_DISPLAY_SIZE = 4 -- studs across; every reward is scaled to this so a grape and a
-- gold stick read the same size in the row
-- Long enough for the climb to read as a float rather than a snap. Short values fight the bob fading
-- in over the same window, so if this drops much below half a second the rise gets twitchy again.
Crates.REWARD_RISE_DURATION = 0.8
Crates.REWARD_HOVER_HEIGHT = 5
-- Gap between the centres of neighbouring rewards. Has to stay clear of REWARD_DISPLAY_SIZE or the
-- row overlaps itself -- two round ingredients each reach half their size either side of centre, so
-- the daylight between a pair is this minus the size. Raising one means raising the other.
Crates.REWARD_HOVER_SPACING = 5.5
Crates.REWARD_HOVER_DURATION = 3
Crates.REWARD_BOB_AMPLITUDE = 0.25
Crates.REWARD_BOB_SPEED = 2
Crates.REWARD_SPIN_SPEED = 0.8

-- The rewards flying into the player, one after another.
Crates.REWARD_COLLECT_STAGGER = 0.1
Crates.REWARD_COLLECT_DURATION = 0.4
Crates.REWARD_COLLECT_ARC_HEIGHT = 8

-- Slack on the server's claim gate, sized past a bad ping so an honest claim is never turned away.
Crates.CLAIM_GRACE = 0.5

--[[
    The crate that finishing the tutorial drops.

    It doesn't go into the backpack -- it crashes into the player's base like a meteor, sits there
    bobbing behind a countdown, and is opened where it landed. The whole base watches it come down
    and watches it open; only its owner gets the prompt and the rewards.

    The countdown is an absolute server-time stamp rather than a duration, which is what lets it
    keep running while the player is offline: log off at fourteen minutes remaining and it's ready
    when you come back.
]]

-- The same crate the shop sells in bundles, given away once: a crate the player can go on to buy
-- more of reads as an offer, where a tutorial-only crate would be a one-off they never see again.
Crates.TUTORIAL_CRATE_ID = "GrillStarterCrate"

-- The BasePart under a base's Core that the crate lands on. Every base needs one.
Crates.METEOR_SPAWN_PART = "CrateMeteorSpawn"

-- How long the crash takes, and how long the crate then holds out before it can be opened.
Crates.METEOR_FALL_DURATION = 3
Crates.TUTORIAL_TIMER_DURATION = 15 * 60

-- How hard the camera pulls toward the falling crate each frame, 0-1. Deliberately soft, so the
-- player keeps control -- the camera is never made Scriptable, only locked to first person.
Crates.METEOR_FOCUS_ALPHA = 0.25
-- Slack past the fall before the camera is released regardless, covering a crate that vanishes
-- mid-flight.
Crates.METEOR_CAMERA_RELEASE_SLACK = 0.4

-- The impact: rock debris, a crater, and a shake.
Crates.METEOR_EXPLOSION_ROCKS = 18
Crates.METEOR_EXPLOSION_MIN_SIZE = 1.25
Crates.METEOR_EXPLOSION_MAX_SIZE = 3
Crates.METEOR_CRATER_RADIUS = 8
Crates.METEOR_CRATER_MIN_ROCKS = 15
Crates.METEOR_CRATER_MAX_ROCKS = 20
Crates.METEOR_SHAKE = { Magnitude = 6, Roughness = 10, FadeIn = 0.1, FadeOut = 0.5 }

-- The Open prompt that replaces the countdown once it runs out.
Crates.TUTORIAL_PROMPT_HOLD = 1
Crates.TUTORIAL_PROMPT_DISTANCE = 12

-- How long to wait for a crate's PrimaryPart to replicate before giving up on its billboard.
Crates.PRIMARY_PART_WAIT = 5

-- Each entry pulls its own model out of Assets.Crates, matched on Id, and every reward id is checked
-- against the config it names. A crate whose model is missing is dropped rather than left half-built,
-- so a typo'd Id can't be granted and then error the moment someone opens it; a reward pointing at an
-- ingredient or stick that doesn't exist is dropped from its group for the same reason, rather than
-- rolling fine and then failing to build a model mid-reveal.
for index = #Crates.Data, 1, -1 do
	local crate = Crates.Data[index]
	local model = CratesFolder:FindFirstChild(crate.Id)

	if not model then
		warn(`Crate {crate.Id} has no model in Assets.Crates, it won't be given`)
		table.remove(Crates.Data, index)
		continue
	end

	crate.Model = model

	for _, group in crate.Contents do
		for rewardIndex = #group.Rewards, 1, -1 do
			local reward = group.Rewards[rewardIndex]

			-- Resolved onto the entry once, here, so no reader downstream has to know the group's Type was
			-- ever only a default -- everything past this point sees a Type on every reward.
			reward.Type = reward.Type or group.Type

			if not reward.Type then
				warn(
					`Crate {crate.Id} rewards {reward.Id} without a Type, and its group has none to fall back on `
						.. `-- give the entry a Type, or the group one for all of its entries to take`
				)
				table.remove(group.Rewards, rewardIndex)
				continue
			end

			local exists = if reward.Type == "Ingredient"
				then Ingredients.GetIngredientFromId(reward.Id) ~= nil
				else Sticks.GetStickFromId(reward.Id) ~= nil

			if not exists then
				warn(
					`Crate {crate.Id} rewards a {reward.Type} the config doesn't have ({reward.Id}), it won't be rolled`
				)
				table.remove(group.Rewards, rewardIndex)
			end
		end
	end
end

-- The two ways a group can be mis-authored, both checked here rather than left to turn up in-game. A
-- group whose chances don't add up to 100% hands out every entry in it rarer (or commoner) than its
-- label says, and a Distinct group with fewer entries than slots can never fill them all.
for _, crate in Crates.Data do
	for _, group in crate.Contents do
		-- A mixed group has no Type of its own to name it by, and every warn below is about the group as a
		-- whole rather than any one entry in it, so "mixed" is what it gets called.
		local groupName = group.Type or "mixed"

		local total = 0
		for _, reward in group.Rewards do
			total += reward.Chance
		end

		if math.abs(total - 100) > Crates.CHANCE_SUM_TOLERANCE then
			local direction = if total > 100 then "rarer" else "commoner"
			local fix = if total > 100 then "lower" else "raise"

			-- Rounded because summing decimals lands on 99.99999 rather than 100 often enough to make
			-- the message itself look like the bug
			local percent = math.round(total * 10) / 10

			warn(
				`Crate {crate.Id}'s {groupName} chances add up to {percent}% instead of 100%, so every one of them `
					.. `lands {math.abs(percent - 100)}% {direction} than authored -- {fix} some Chances to bring them back`
			)
		end

		if group.Distinct and #group.Rewards < group.Count then
			warn(
				`Crate {crate.Id}'s {groupName} group draws {group.Count} distinct rewards from only {#group.Rewards} `
					.. `entries, so it can't fill every slot -- add more entries or drop its Count`
			)
		end
	end
end

table.freeze(Crates.Data)

-- The Products.luau string id for buying a bundle of a crate with Robux ("3MeatCrate"). Built in one
-- place so the config that generates the product, the client that prompts it, and the shop card's
-- button frames -- which are named for the product they buy -- can't drift apart.
function Crates.GetProductStringId(crateId: string, amount: number): string
	return `{amount}{crateId}`
end

function Crates.GetCrateFromId(id: string): Crate?
	for _, crate in Crates.Data do
		if crate.Id == id then
			return crate
		end
	end

	return nil
end

function Crates.GetAllCrates(): { Crate }
	return Crates.Data
end

-- How many things one crate pays out, summed over its groups. Drives the reveal row's width and the
-- server's claim gate, so both read it off the config rather than counting the rolled list.
function Crates.GetRewardCount(crate: Crate): number
	local count = 0

	for _, group in crate.Contents do
		count += group.Count
	end

	return count
end

-- The cooldown (seconds) opening `count` crates at once costs the player.
function Crates.GetOpenCooldown(count: number): number
	return Crates.OPEN_COOLDOWN_BASE + math.max(count, 1) * Crates.OPEN_COOLDOWN_PER_CRATE
end

-- Wall-clock seconds from a crate being spawned to its last reward landing on the player, summed from
-- the same constants the client animates on. The server gates claims on this, so retuning the
-- animation can't leave the two disagreeing. `openIndex` is the crate's place in its batch, which is
-- how long the client waits before throwing it at all.
function Crates.GetOpenDuration(crate: Crate, openIndex: number?): number
	local duration = (math.max(openIndex or 1, 1) - 1) * Crates.THROW_STAGGER
	duration += Crates.THROW_DURATION + Crates.SETTLE_DURATION

	local waitTime = Crates.TWITCH_INITIAL_WAIT
	for _ = 1, Crates.TWITCH_COUNT do
		duration += waitTime
		waitTime = math.max(waitTime - Crates.TWITCH_WAIT_DECREMENT, Crates.TWITCH_MIN_WAIT)
	end

	duration += Crates.TWITCH_SETTLE + Crates.WINDUP_DURATION + Crates.SLAM_DURATION

	-- The pop's fade runs alongside the rise -- the rewards burst out of the flash rather than after
	-- it -- so it isn't counted here.
	duration += Crates.REWARD_RISE_DURATION + Crates.REWARD_HOVER_DURATION
	duration += (Crates.GetRewardCount(crate) - 1) * Crates.REWARD_COLLECT_STAGGER
	duration += Crates.REWARD_COLLECT_DURATION

	return duration
end

return Crates
