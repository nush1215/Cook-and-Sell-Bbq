-- Every crate and what it can pay out. A group's chances must add up to 100%; see docs/balance.md.

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
	-- grants them. A mixed group leaves this out and writes it on each entry instead
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
	-- it grants. Products.luau generates one product per entry; a crate with none isn't sold for Robux
	Contents: { SlotGroup },
	Model: Model, -- not authored below, back-filled from Assets.Crates
}

-- One rolled slot: what came out and which config it came from -- rolled, shipped and granted as this
export type Reward = {
	Type: RewardType,
	Id: string,
}

--
local Crates = {}

-- Most crates opened at once and the cooldown it costs, scaled by batch. Shared, so both debounces agree
Crates.MAX_OPEN_AT_ONCE = 10
Crates.OPEN_COOLDOWN_BASE = 1
Crates.OPEN_COOLDOWN_PER_CRATE = 0.2

-- How far a group's chances may sit off 100% before the load-time warn fires, in percentage points
Crates.CHANCE_SUM_TOLERANCE = 0.5

Crates.Data = {
	{
		Id = "MeatCrate",
		Name = "Meat Crate",
		Color = Color3.fromRGB(228, 96, 96),
		ExplodeColor = Color3.fromRGB(255, 214, 214),
		RobuxProductIds = { [1] = 3709025712, [3] = 3709025743, [10] = 3709025774 },
		Contents = {
			-- Every meat, and the one crate a Common belongs in. Not Distinct on purpose -- see docs/balance.md
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
			-- The one mixed pool: every slot draws sticks and ingredients against each other. See docs/balance.md
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

-- The open animation: throw, rattle, slam, pop, then the reward row. See docs/balance.md.

-- The throw out to the crate's slot on the ground
Crates.THROW_START_HEIGHT = 2.5 -- studs above the owner's root the crate leaves from, roughly head height
Crates.THROW_DURATION = 0.4
Crates.THROW_ARC_HEIGHT = 10
Crates.THROW_STAGGER = 0.12 -- delay per crate in a batch, so ten don't all launch on the same frame
Crates.SETTLE_DURATION = 0.25 -- beat between landing and the first twitch

-- A random jolt per beat, accelerating and gaining height, so the rattle visibly builds
Crates.TWITCH_COUNT = 12
Crates.TWITCH_INITIAL_WAIT = 0.3
Crates.TWITCH_WAIT_DECREMENT = 0.03
Crates.TWITCH_MIN_WAIT = 0.06
Crates.TWITCH_ANGLE = 20 -- max degrees off true on each axis
Crates.TWITCH_LIFT_PER_BEAT = 0.4 -- studs the crate climbs on each beat
Crates.TWITCH_LIFT_MAX = 4 -- as high as the rattle alone ever gets it
Crates.TWITCH_SETTLE = 0.25 -- held at the top of the rattle before the wind-up, so the hop reads

-- The wind-up and the slam: one last hop, then straight back down onto the slot, where it bursts
Crates.WINDUP_LIFT = 3 -- studs above wherever the rattle left it
Crates.WINDUP_DURATION = 0.3
Crates.SLAM_DURATION = 0.2

-- The pop, on the frame the slam lands: scale up, go neon, fade out
Crates.POP_SCALE = 1.5
Crates.POP_FADE_DURATION = 0.3
-- How long the shell lingers -- it must outlive the land burst parented to its own PrimaryPart
Crates.POP_LINGER = 1

-- One yellow for every crate flash, so the whole open reads as one thing
Crates.FLASH_COLOR = Color3.fromRGB(255, 255, 117)

-- How long an effect trails its beat, so neither reads as simultaneous
Crates.LAND_EFFECT_DELAY = 0.13
Crates.SHOW_LOOT_DELAY = 0.1

-- The rewards rising out of the pop into their row.
Crates.REWARD_START_LIFT = 1 -- studs above the slot they set off from, so they leave from inside the crate
Crates.REWARD_START_SCALE = 0.2
Crates.REWARD_DISPLAY_SIZE = 4 -- studs across; every reward scales to this, so a grape and a gold stick match
-- Long enough to read as a float rather than a snap; below ~0.5s it fights the bob fading in
Crates.REWARD_RISE_DURATION = 0.8
Crates.REWARD_HOVER_HEIGHT = 5
-- Gap between reward centres. Must stay clear of REWARD_DISPLAY_SIZE or the row overlaps itself
Crates.REWARD_HOVER_SPACING = 5.5
Crates.REWARD_HOVER_DURATION = 3
Crates.REWARD_BOB_AMPLITUDE = 0.25
Crates.REWARD_BOB_SPEED = 2
Crates.REWARD_SPIN_SPEED = 0.8

-- The rewards flying into the player, one after another.
Crates.REWARD_COLLECT_STAGGER = 0.1
Crates.REWARD_COLLECT_DURATION = 0.4
Crates.REWARD_COLLECT_ARC_HEIGHT = 8

-- Slack on the server's claim gate, sized past a bad ping so an honest claim is never turned away
Crates.CLAIM_GRACE = 0.5

-- The tutorial crate: crashed into the base like a meteor, held behind a countdown. See docs/balance.md.

-- The crate the shop also sells, so it reads as an offer rather than a one-off never seen again
Crates.TUTORIAL_CRATE_ID = "GrillStarterCrate"

-- The BasePart under a base's Core that the crate lands on. Every base needs one
Crates.METEOR_SPAWN_PART = "CrateMeteorSpawn"

-- How long the crash takes, and how long the crate then holds out before it can be opened
Crates.METEOR_FALL_DURATION = 3
Crates.TUTORIAL_TIMER_DURATION = 15 * 60

-- How hard the camera pulls toward the falling crate. Soft, so the player keeps control
Crates.METEOR_FOCUS_ALPHA = 0.25
-- Slack past the fall before the camera is released regardless, covering a crate lost mid-flight
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

-- Resolves each crate's model and checks every reward id, dropping anything that can't be built.
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

			-- Resolved once, so everything past this point sees a Type on every reward
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

-- Warns on a group whose chances miss 100%, or a Distinct group with fewer entries than slots.
for _, crate in Crates.Data do
	for _, group in crate.Contents do
		-- A mixed group has no Type to name it by, and these warns are about the group as a whole
		local groupName = group.Type or "mixed"

		local total = 0
		for _, reward in group.Rewards do
			total += reward.Chance
		end

		if math.abs(total - 100) > Crates.CHANCE_SUM_TOLERANCE then
			local direction = if total > 100 then "rarer" else "commoner"
			local fix = if total > 100 then "lower" else "raise"

			-- Rounded, since summing decimals lands on 99.99999 often enough to make the message look like the bug
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

-- The Products id for a crate bundle, built in one place so the config, the prompt and the card can't drift.
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

-- How many one crate pays out, off the config rather than the rolled list, so the row and the gate agree.
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

-- Wall seconds from spawn to the last reward landing, off the same constants the client animates on.
function Crates.GetOpenDuration(crate: Crate, openIndex: number?): number
	local duration = (math.max(openIndex or 1, 1) - 1) * Crates.THROW_STAGGER
	duration += Crates.THROW_DURATION + Crates.SETTLE_DURATION

	local waitTime = Crates.TWITCH_INITIAL_WAIT
	for _ = 1, Crates.TWITCH_COUNT do
		duration += waitTime
		waitTime = math.max(waitTime - Crates.TWITCH_WAIT_DECREMENT, Crates.TWITCH_MIN_WAIT)
	end

	duration += Crates.TWITCH_SETTLE + Crates.WINDUP_DURATION + Crates.SLAM_DURATION

	-- The pop's fade runs alongside the rise, so it isn't counted here
	duration += Crates.REWARD_RISE_DURATION + Crates.REWARD_HOVER_DURATION
	duration += (Crates.GetRewardCount(crate) - 1) * Crates.REWARD_COLLECT_STAGGER
	duration += Crates.REWARD_COLLECT_DURATION

	return duration
end

return Crates
