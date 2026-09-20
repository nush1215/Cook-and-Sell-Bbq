-- The daily quest board: three quests, one per difficulty, rolled per player and replaced RESET_INTERVAL after the last was rolled. Each quest pays QUEST_REWARD when claimed, and claiming all three pays a random board reward on top. What a quest counts is its Type; DailyQuestManager does the counting, this only says what's on offer and how it reads.

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)
local RandomUtil = require(Shared.RandomUtil)
local Keywords = require(Shared.Config.Keywords)
local Ingredients = require(Shared.Config.Ingredients)
local Sticks = require(Shared.Config.Sticks)
local Mutations = require(Shared.Config.Mutations)
local CookStates = require(Shared.Config.CookStates)
local Crates = require(Shared.Config.Crates)
local DailyRewards = require(Shared.Config.DailyRewards)

--
export type QuestType = {
	-- Resolves the quest's Arg to the config entry it names; left out, the Type takes no Arg
	GetArg: ((id: string) -> any)?,
	-- The objective line under the title, off the quest's Target and its resolved Arg
	Describe: (target: number, arg: any) -> string,
}

export type Quest = {
	Id: string, -- what a rolled board saves, so it must never change once live
	Title: string,
	Type: string, -- a key of DailyQuests.Types, which says what counts toward it
	Target: number,
	Arg: string?, -- the ingredient, tier, stick, mutation or cook state its Type counts
	Difficulty: string, -- not authored below, back-filled from the list it's under
}

-- One quest on a player's board as saved: its Target is copied off the pool, so a retune can't move a board mid-day
export type BoardQuest = {
	Id: string,
	Target: number,
	Progress: number,
	Claimed: boolean,
}

export type Board = {
	Count: number,
	StartedAt: number,
	Quests: { BoardQuest },
	Reward: DailyRewards.Reward | false,
	RewardClaimed: boolean,
}

--
local DailyQuests = {}

-- The ScreenGui the board is shown on, and the HUD button that opens it
DailyQuests.UI_NAME = "QuestsUI"
DailyQuests.HUD_BUTTON = "Quests"

-- The ScreenGui in the owner's PlayerGui a worker board reward's three portraits are baked into, each named by slot
DailyQuests.PORTRAIT_FOLDER = "DailyQuestWorkerPortraits"

-- How long after a board is rolled the next replaces it
DailyQuests.RESET_INTERVAL = 24 * 60 * 60

-- Seconds a reset may land early, so the two clocks can't disagree over the moment a board rolls over
DailyQuests.CLAIM_GRACE = 0.5

-- The Bux each quest pays, flat and unboosted, so the tile's figure is what lands
DailyQuests.QUEST_REWARD = 1_000

-- Seeds are the UserId strided past the board count, offset half a stride so they never meet the daily rewards' own
DailyQuests.SEED_STRIDE = 1_000
DailyQuests.SEED_OFFSET = 500

-- Which difficulty each tile rolls its quest from, in tile order
DailyQuests.SLOT_DIFFICULTIES = { "Easy", "Medium", "Hard" }

table.freeze(DailyQuests.SLOT_DIFFICULTIES)

-- "a Customer" for one, "10 Customers" past it, with the number in the game's gold.
local function formatAmount(target: number, noun: string): string
	if target == 1 then
		local article = if string.find(noun, "^[AEIOUaeiou]") then "an" else "a"
		return `{article} {noun}`
	end

	return `{GuiUtil.Colorize(GuiUtil.ConvertNumberWithCommas(target), Keywords.NUMBER)} {noun}s`
end

DailyQuests.Types = {
	ServeCustomers = {
		Describe = function(target: number)
			return `Serve {formatAmount(target, "Customer")}`
		end,
	},

	SellSkewers = {
		Describe = function(target: number)
			return `Sell {formatAmount(target, "BBQ")}`
		end,
	},

	ServeIngredient = {
		GetArg = Ingredients.GetIngredientFromId,
		Describe = function(target: number, ingredient)
			return `Serve {formatAmount(target, "BBQ")} with {ingredient.Name}`
		end,
	},

	-- Counts the tier or any rarer, so a Rare quest never turns away an Epic
	ServeIngredientTier = {
		GetArg = Ingredients.GetTierFromId,
		Describe = function(target: number, tier)
			return `Serve {formatAmount(target, "BBQ")} with {formatAmount(1, tier.Id)} or rarer Ingredient`
		end,
	},

	-- Every slot on its stick filled, so any stick can do it
	ServeFullSkewer = {
		Describe = function(target: number)
			return `Serve {formatAmount(target, "Fully Loaded BBQ")}`
		end,
	},

	ServeStick = {
		GetArg = Sticks.GetStickFromId,
		Describe = function(target: number, stick)
			local sticks = if target == 1 then formatAmount(1, `{stick.Name} Stick`) else `{stick.Name} Sticks`
			return `Serve {formatAmount(target, "BBQ")} on {sticks}`
		end,
	},

	ServeMutation = {
		GetArg = Mutations.GetMutationFromId,
		Describe = function(target: number, mutation)
			return `Serve {formatAmount(target, `{mutation.Name} BBQ`)}`
		end,
	},

	ServeCookState = {
		GetArg = CookStates.GetStateFromId,
		Describe = function(target: number, cookState)
			return `Serve {formatAmount(target, `{cookState.Name} BBQ`)}`
		end,
	},

	-- A skewer pulled off Raw isn't a cook, so it doesn't count
	CookBbqs = {
		Describe = function(target: number)
			return `Cook {formatAmount(target, "BBQ")}`
		end,
	},

	CookState = {
		GetArg = CookStates.GetStateFromId,
		Describe = function(target: number, cookState)
			return `Cook {formatAmount(target, `{cookState.Name} BBQ`)}`
		end,
	},

	DeliverCustomOrders = {
		Describe = function(target: number)
			return `Complete {formatAmount(target, "Custom Order")}`
		end,
	},

	-- An exact fill cooked Perfect, the same bar StatsManager's CustomOrdersPerfect counts
	PerfectCustomOrders = {
		Describe = function(target: number)
			return `Complete {formatAmount(target, "Perfect Custom Order")}`
		end,
	},

	RollIngredients = {
		Describe = function(target: number)
			return `Roll {formatAmount(target, "Ingredient")}`
		end,
	},

	BuySticks = {
		Describe = function(target: number)
			return `Buy {formatAmount(target, "Stick")}`
		end,
	},

	ServeRichCustomer = {
		Describe = function(target: number)
			return `Serve {formatAmount(target, "Rich Customer")}`
		end,
	},

	-- A sale that went through after the customer countered at least once
	AcceptCounteroffer = {
		Describe = function(target: number)
			return `Accept {formatAmount(target, "Counteroffer")}`
		end,
	},

	-- Counted in minutes online
	PlayTime = {
		Describe = function(target: number)
			return `Grill for {formatAmount(target, "Minute")}`
		end,
	},
} :: { [string]: QuestType }

table.freeze(DailyQuests.Types)

-- Each tile draws one from its difficulty's list. Worker actions count too, so volume quests are tuned for staff
DailyQuests.Quests = {
	Easy = {
		{ Id = "OpenForBusiness", Title = "Open for Business", Type = "ServeCustomers", Target = 5 },
		{ Id = "StackEmUp", Title = "Stack 'Em Up", Type = "SellSkewers", Target = 8 },
		{ Id = "CornStar", Title = "Corn Star", Type = "ServeIngredient", Target = 1, Arg = "Corn" },
		{ Id = "VampireRepellent", Title = "Vampire Repellent", Type = "ServeIngredient", Target = 3, Arg = "Garlic" },
		{ Id = "WinnerWinner", Title = "Winner Winner", Type = "ServeIngredient", Target = 5, Arg = "Chicken" },
		{ Id = "FunGuy", Title = "Fun Guy", Type = "ServeIngredient", Target = 3, Arg = "Mushroom" },
		{ Id = "FeelTheHeat", Title = "Feel the Heat", Type = "ServeIngredient", Target = 3, Arg = "Jalapeno" },
		{ Id = "TearsOfJoy", Title = "Tears of Joy", Type = "ServeIngredient", Target = 5, Arg = "Onion" },
		{ Id = "VeggiePatch", Title = "Veggie Patch", Type = "ServeIngredient", Target = 5, Arg = "Carrot" },
		{ Id = "NoRoomLeft", Title = "No Room Left", Type = "ServeFullSkewer", Target = 3 },
		{ Id = "PerfectTiming", Title = "Perfect Timing", Type = "CookState", Target = 5, Arg = "Perfect" },
		{ Id = "SolidWork", Title = "Solid Work", Type = "CookBbqs", Target = 10 },
		{ Id = "MadeToOrder", Title = "Made to Order", Type = "DeliverCustomOrders", Target = 2 },
		{ Id = "FeelingLucky", Title = "Feeling Lucky", Type = "RollIngredients", Target = 10 },
		{ Id = "StockingUp", Title = "Stocking Up", Type = "BuySticks", Target = 5 },
		{ Id = "ArtOfTheDeal", Title = "Art of the Deal", Type = "AcceptCounteroffer", Target = 3 },
		{ Id = "ClockingIn", Title = "Clocking In", Type = "PlayTime", Target = 15 },
	},

	Medium = {
		{ Id = "LunchRush", Title = "Lunch Rush", Type = "ServeCustomers", Target = 12 },
		{ Id = "SkewerSlinger", Title = "Skewer Slinger", Type = "SellSkewers", Target = 20 },
		{ Id = "HogWild", Title = "Hog Wild", Type = "ServeIngredient", Target = 3, Arg = "Pork" },
		{
			Id = "ControversialTopping",
			Title = "Controversial Topping",
			Type = "ServeIngredient",
			Target = 2,
			Arg = "Pineapple",
		},
		{ Id = "BerryGood", Title = "Berry Good", Type = "ServeIngredient", Target = 2, Arg = "Strawberry" },
		{ Id = "FruitStand", Title = "Fruit Stand", Type = "ServeIngredient", Target = 3, Arg = "Banana" },
		{ Id = "MovingUp", Title = "Moving Up", Type = "ServeIngredientTier", Target = 5, Arg = "Uncommon" },
		{ Id = "FancyPlate", Title = "Fancy Plate", Type = "ServeIngredientTier", Target = 1, Arg = "Rare" },
		{ Id = "PackedToTheTip", Title = "Packed to the Tip", Type = "ServeFullSkewer", Target = 8 },
		{ Id = "ChefsKiss", Title = "Chef's Kiss", Type = "CookState", Target = 8, Arg = "Perfect" },
		{ Id = "QualityControl", Title = "Quality Control", Type = "ServeCookState", Target = 6, Arg = "Perfect" },
		{ Id = "BambooBoss", Title = "Bamboo Boss", Type = "ServeStick", Target = 5, Arg = "BambooStick" },
		{ Id = "SpecialRequests", Title = "Special Requests", Type = "DeliverCustomOrders", Target = 5 },
		{ Id = "FiveStarService", Title = "Five Star Service", Type = "PerfectCustomOrders", Target = 1 },
		{ Id = "HighRoller", Title = "High Roller", Type = "RollIngredients", Target = 40 },
		{ Id = "BigSpender", Title = "Big Spender", Type = "ServeRichCustomer", Target = 1 },
	},

	Hard = {
		{ Id = "LineAroundTheBlock", Title = "Line Around the Block", Type = "ServeCustomers", Target = 20 },
		{ Id = "GrillLegend", Title = "Grill Legend", Type = "SellSkewers", Target = 35 },
		{ Id = "TopShelf", Title = "Top Shelf", Type = "ServeIngredientTier", Target = 1, Arg = "Epic" },
		{ Id = "FlawlessGrill", Title = "Flawless Grill", Type = "CookState", Target = 12, Arg = "Perfect" },
		{ Id = "CopperCookout", Title = "Copper Cookout", Type = "ServeStick", Target = 2, Arg = "CopperStick" },
		{ Id = "ItsElectric", Title = "It's Electric", Type = "ServeMutation", Target = 1, Arg = "Shocked" },
		{ Id = "OrderUp", Title = "Order Up!", Type = "DeliverCustomOrders", Target = 6 },
		{ Id = "CriticsChoice", Title = "Critic's Choice", Type = "PerfectCustomOrders", Target = 2 },
		{ Id = "MoneyTalks", Title = "Money Talks", Type = "ServeRichCustomer", Target = 2 },
		{ Id = "FineDining", Title = "Fine Dining", Type = "ServeIngredientTier", Target = 3, Arg = "Rare" },
		{ Id = "MeatLover", Title = "Meat Lover", Type = "ServeIngredient", Target = 6, Arg = "Pork" },
		{ Id = "BambooForest", Title = "Bamboo Forest", Type = "ServeStick", Target = 6, Arg = "BambooStick" },
		{ Id = "AssemblyLine", Title = "Assembly Line", Type = "CookBbqs", Target = 25 },
		{ Id = "AllIn", Title = "All In", Type = "RollIngredients", Target = 100 },
		{ Id = "StuffedSkewers", Title = "Stuffed Skewers", Type = "ServeFullSkewer", Target = 12 },
	},
} :: { [string]: { Quest } }

-- What claiming all three rolls, by Weight. The same Reward shape as a daily reward, so it's granted and drawn alike
DailyQuests.BoardRewards = {
	-- Crates carry no image of their own, so each names the one its icon shows
	{ Type = "Crate", Id = "MeatCrate", Amount = 1, Weight = 35, Icon = "rbxassetid://115216469222978" },
	{ Type = "Crate", Id = "GrillStarterCrate", Amount = 1, Weight = 35, Icon = "rbxassetid://137521090377245" },
	{ Type = "Worker", Stars = 4, Weight = 20 },
	{ Type = "Worker", Stars = 4.5, Weight = 10 },
	{ Type = "Worker", Stars = 5, Weight = 5 },
} :: { DailyRewards.Reward }

table.freeze(DailyQuests.BoardRewards)

-- Back-fills each quest's Difficulty and indexes it by Id, warning on an Id used twice or an Arg the configs don't have
local questsById = {}

for difficulty, quests in DailyQuests.Quests do
	for _, quest in quests do
		quest.Difficulty = difficulty

		if questsById[quest.Id] then
			warn(`Daily quest Id {quest.Id} is used twice, a saved board can only resolve one of them`)
		end
		questsById[quest.Id] = quest

		local questType = DailyQuests.Types[quest.Type]
		if not questType then
			warn(`Daily quest {quest.Id} has a Type the config doesn't have ({quest.Type})`)
		elseif questType.GetArg and not questType.GetArg(quest.Arg) then
			warn(`Daily quest {quest.Id} counts a {quest.Type} the config doesn't have ({quest.Arg})`)
		end
	end

	table.freeze(quests)
end

table.freeze(DailyQuests.Quests)
table.freeze(questsById)

for _, reward in DailyQuests.BoardRewards do
	if reward.Type == "Crate" and not Crates.GetCrateFromId(reward.Id) then
		warn(`Daily quest board reward is a crate the config doesn't have ({reward.Id}), it can't be given`)
	end
end

function DailyQuests.GetQuestFromId(id: string): Quest?
	return questsById[id]
end

-- The objective line a quest's tile reads, with its number in gold.
function DailyQuests.GetDescription(quest: Quest, target: number): string
	local questType = DailyQuests.Types[quest.Type]
	local arg = if questType.GetArg then questType.GetArg(quest.Arg) else nil
	return questType.Describe(target, arg)
end

-- The seed behind the board rolled at `count`, for both its roll and its worker reward's faces.
function DailyQuests.GetSeed(userId: number, count: number): number
	return userId * DailyQuests.SEED_STRIDE + DailyQuests.SEED_OFFSET + count
end

-- Rolls the board a player's `count`th is: one quest per difficulty in tile order, and the reward for claiming all three.
function DailyQuests.RollBoard(userId: number, count: number): ({ BoardQuest }, DailyRewards.Reward)
	local rng = Random.new(DailyQuests.GetSeed(userId, count))

	local quests = {}
	for _, difficulty in DailyQuests.SLOT_DIFFICULTIES do
		local quest = RandomUtil.GetRandomFromArray(DailyQuests.Quests[difficulty], nil, rng)
		table.insert(quests, { Id = quest.Id, Target = quest.Target, Progress = 0, Claimed = false })
	end

	local weighted = {}
	for _, entry in DailyQuests.BoardRewards do
		table.insert(weighted, { entry, entry.Weight })
	end

	-- Cloned off the frozen pool without its Weight, since this copy is what the board saves
	local reward = table.clone((RandomUtil.GetResultFromWeight(weighted, rng)))
	reward.Weight = nil

	return quests, reward
end

-- The image a board reward shows, read off the pool entry it was rolled from so a board saved before an Icon was added still gets it.
function DailyQuests.GetRewardIcon(reward: DailyRewards.Reward): string?
	for _, entry in DailyQuests.BoardRewards do
		if entry.Type == reward.Type and entry.Id == reward.Id and entry.Stars == reward.Stars and entry.Icon then
			return entry.Icon
		end
	end

	local _, icon = DailyRewards.GetRewardDisplay(reward)
	return icon
end

-- Whether every quest on the board has reached its Target. False on a board never rolled.
function DailyQuests.IsBoardComplete(board: Board): boolean
	if #board.Quests == 0 then
		return false
	end

	for _, boardQuest in board.Quests do
		if boardQuest.Progress < boardQuest.Target then
			return false
		end
	end

	return true
end

-- Whether every quest on the board has been claimed, which is what owes the board reward. False on a board never rolled.
function DailyQuests.IsBoardClaimed(board: Board): boolean
	if #board.Quests == 0 then
		return false
	end

	for _, boardQuest in board.Quests do
		if not boardQuest.Claimed then
			return false
		end
	end

	return true
end

-- Whether the board's worker reward is waiting on a pick off its cards.
function DailyQuests.IsWorkerPickOwed(board: Board): boolean
	return DailyQuests.IsBoardClaimed(board)
		and board.Reward ~= false
		and board.Reward.Type == "Worker"
		and not board.RewardClaimed
end

return DailyQuests
