-- The week of daily rewards: one claim every CLAIM_INTERVAL, counted from the last, never reset by a missed day. What each claim hands out is derived from the player's UserId and claim count rather than stored, so the client draws the same week the server grants. See docs/balance.md.

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)
local RandomUtil = require(Shared.RandomUtil)
local Keywords = require(Shared.Config.Keywords)
local Crates = require(Shared.Config.Crates)
local Sticks = require(Shared.Config.Sticks)
local Structures = require(Shared.Config.Structures)

--
export type RewardType = "Bux" | "Crate" | "Stick" | "Structure" | "Worker"

export type Reward = {
	Type: RewardType, -- which manager grants it, and which config the Id below comes from
	Id: string?, -- a Crates, Sticks or Structures id, for those three Types
	Amount: number?, -- the Bux, crates, sticks or structures handed over
	Stars: number?, -- a Worker's rating; which of the three roles is the player's pick off the cards
	Icon: string?, -- the tile image, over whatever the reward's own config carries
	Weight: number?, -- this entry's share of its day's Pool roll
	Pool: { Reward }?, -- what the day rolls from once the weeks randomize; left out, the day repeats as listed
}

--
local DailyRewards = {}

-- The ScreenGui the week is shown on
DailyRewards.UI_NAME = "DailyRewardUI"

-- The ScreenGui in the owner's PlayerGui a worker day's three portraits are baked into, each named by slot
DailyRewards.PORTRAIT_FOLDER = "DailyRewardWorkerPortraits"

-- How long after a claim the next day unlocks
DailyRewards.CLAIM_INTERVAL = 24 * 60 * 60

-- Seconds a claim may land early, so the two clocks can't disagree over the moment a day unlocks
DailyRewards.CLAIM_GRACE = 0.5

-- Borrowed from Stop-The-Timer's daily rewards until this game has an icon of its own
DailyRewards.TOPBAR_ICON = "rbxassetid://100722723335796"

-- The tile image for a worker day
DailyRewards.WORKER_ICON = "rbxassetid://121105918005378"

-- Stride between one player's claim seeds, matching the shops': two players' seeds can't meet inside a thousand claims
DailyRewards.SEED_STRIDE = 1_000

-- Whether the weeks after the first roll each day off its Pool. Off, every week hands the days out as listed
DailyRewards.RANDOMIZE_AFTER_FIRST_WEEK = false

-- One entry per day in order; the length is the week
DailyRewards.Days = {
	{ Type = "Bux", Amount = 500 },
	{ Type = "Crate", Id = "MeatCrate", Amount = 1, Icon = "rbxassetid://115216469222978" },
	{ Type = "Stick", Id = "GoldStick", Amount = 3 },
	{ Type = "Worker", Stars = 3 },
	{ Type = "Structure", Id = "SolarGrill", Amount = 1 },
	{ Type = "Bux", Amount = 100_000, Icon = "rbxassetid://104249415354239" },
	{ Type = "Worker", Stars = 5 },
}

-- Warns when a reward names a crate, stick or structure the config doesn't have. Warned rather than dropped, since dropping a day would shift every one after it.
local function warnIfMissing(reward: Reward, source: string)
	local exists = if reward.Type == "Crate"
		then Crates.GetCrateFromId(reward.Id) ~= nil
		elseif reward.Type == "Stick" then Sticks.GetStickFromId(reward.Id) ~= nil
		elseif reward.Type == "Structure" then Structures.GetStructureFromId(reward.Id) ~= nil
		else true

	if not exists then
		warn(`Daily reward {source} is a {reward.Type} the config doesn't have ({reward.Id}), it can't be given`)
	end
end

for day, reward in DailyRewards.Days do
	warnIfMissing(reward, `Day {day}`)

	for _, entry in reward.Pool or {} do
		warnIfMissing(entry, `Day {day}'s pool`)
	end
end

table.freeze(DailyRewards.Days)

-- The day of the week a player with `claimedCount` claims behind them is on, 1 to #Days.
function DailyRewards.GetDay(claimedCount: number): number
	return claimedCount % #DailyRewards.Days + 1
end

-- The seed behind the claim after `claimedCount`, for both its Pool roll and its worker faces. Never the bare UserId the free three roll off.
function DailyRewards.GetSeed(userId: number, claimedCount: number): number
	return userId * DailyRewards.SEED_STRIDE + claimedCount
end

-- What the claim after `claimedCount` hands out: the day as listed, or once the weeks randomize, a roll off that day's Pool.
function DailyRewards.GetReward(userId: number, claimedCount: number): Reward
	local reward = DailyRewards.Days[DailyRewards.GetDay(claimedCount)]

	-- The first week is always the one listed, so a new player gets the week they were shown
	if not DailyRewards.RANDOMIZE_AFTER_FIRST_WEEK or claimedCount < #DailyRewards.Days or not reward.Pool then
		return reward
	end

	local weighted = {}
	for _, entry in reward.Pool do
		table.insert(weighted, { entry, entry.Weight })
	end

	return (RandomUtil.GetResultFromWeight(weighted, DailyRewards.GetSeed(userId, claimedCount)))
end

-- A reward as its tile reads it: the title, and the image where the entry or its config has one.
function DailyRewards.GetRewardDisplay(reward: Reward): (string, string?)
	if reward.Type == "Bux" then
		return `${GuiUtil.ConvertNumberWithSuffix(reward.Amount)}`, reward.Icon
	elseif reward.Type == "Crate" then
		local crate = Crates.GetCrateFromId(reward.Id)
		-- The entry's own, since a crate's config Icon is its backpack slot's too
		return `x{reward.Amount} {crate.Name}`, reward.Icon or crate.Icon
	elseif reward.Type == "Stick" then
		local stick = Sticks.GetStickFromId(reward.Id)
		return `x{reward.Amount} {stick.Name} Stick`, reward.Icon or stick.Icon
	elseif reward.Type == "Structure" then
		local structure = Structures.GetStructureFromId(reward.Id)
		return `x{reward.Amount} {structure.Name}`, reward.Icon or structure.Icon
	end

	-- The rating in the game's number gold, so it reads as what the worker is worth
	return `{GuiUtil.Colorize(`{reward.Stars} Star`, Keywords.NUMBER)} Worker`, reward.Icon or DailyRewards.WORKER_ICON
end

return DailyRewards
