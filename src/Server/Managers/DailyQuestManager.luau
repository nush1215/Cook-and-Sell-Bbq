-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local StickModel = require(Shared.StickModel)
local RandomUtil = require(Shared.RandomUtil)
local DailyQuests = require(Shared.Config.DailyQuests)
local DailyRewards = require(Shared.Config.DailyRewards)
local FreeWorkers = require(Shared.Config.FreeWorkers)
local Keywords = require(Shared.Config.Keywords)
local Ingredients = require(Shared.Config.Ingredients)
local Sticks = require(Shared.Config.Sticks)

-- Managers
local PlayerDataManager = require(script.Parent.PlayerDataManager)
local CurrencyManager = require(script.Parent.CurrencyManager)
local NotificationManager = require(script.Parent.NotificationManager)
local DailyRewardManager = require(script.Parent.DailyRewardManager)
local FreeWorkersManager = require(script.Parent.FreeWorkersManager)
local BaseManager = require(script.Parent.BaseManager)
local SellNpcManager = require(script.Parent.SellNpcManager)
local CustomOrderNpcManager = require(script.Parent.CustomOrderNpcManager)
local HungryJoeNpcManager = require(script.Parent.HungryJoeNpcManager)
local GrillerManager = require(script.Parent.GrillerManager)
local IngredientRollingManager = require(script.Parent.IngredientRollingManager)
local StickShopManager = require(script.Parent.StickShopManager)

-- Seconds between PlayTime ticks, which is what makes its Target count minutes
local PLAY_TIME_INTERVAL = 60

-- The daily quest board: three quests counted off the gameplay signals, a flat payout per claim, and a board reward once all three are claimed. The board is rolled after the tutorial and again RESET_INTERVAL after each roll, settling whatever was finished but left unclaimed. A worker board reward is claimed by picking one of three cards, and only the slot number comes back.

--
local DailyQuestManager = {
	ClaimDailyQuestEvent = Network.Event("ClaimDailyQuest", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 4 },
	}), -- client -> server (questSlot)
	ClaimDailyQuestRewardEvent = Network.Event("ClaimDailyQuestReward", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 2 },
	}), -- client -> server (cardSlot)
	ClaimDailyQuestResultEvent = Network.Event("ClaimDailyQuestResult"), -- server -> client (success, cardSlot?)

	OnDailyQuestCompleted = Signal.new(), -- (player, quest)
	OnDailyQuestClaimed = Signal.new(), -- (player, quest)
	OnDailyQuestBoardCompleted = Signal.new(), -- (player, reward, settledAtReset)

	_claiming = {}, -- [player] = true, held across the read -> write yield window
	_resetThreads = {}, -- [player] = the delayed thread that rolls their next board
}

-- Adds progress to every unfinished quest on the player's board, `getAmount` saying how much each quest earns from what just happened. Toasts each one it finishes.
function DailyQuestManager:ProgressDailyQuests(player: Player, getAmount: (quest: DailyQuests.Quest) -> number)
	-- Not awaited: a signal fires before a join has loaded or after a leave, and either way there's no board to add to
	local data = PlayerDataManager:GetLoadedPlayerData(player)
	if not data then
		return
	end

	-- A lapsed board is settled as it stood when the roll comes, so nothing past its reset counts toward it
	local board = data.DailyQuests
	if workspace:GetServerTimeNow() >= board.StartedAt + DailyQuests.RESET_INTERVAL then
		return
	end

	for slot, boardQuest in board.Quests do
		if boardQuest.Progress >= boardQuest.Target then
			continue
		end

		-- Taken out of the pool after this board rolled; its tile still shows, it just can't move
		local quest = DailyQuests.GetQuestFromId(boardQuest.Id)
		if not quest then
			continue
		end

		local amount = getAmount(quest)
		if amount <= 0 then
			continue
		end

		local target = boardQuest.Target
		local progress = math.min(boardQuest.Progress + amount, target)
		PlayerDataManager:SetPlayerDataKey(player, { "DailyQuests", "Quests", slot, "Progress" }, progress)

		if progress < target then
			continue
		end

		NotificationManager:NotifyNormal(player, {
			Text = `Quest complete: {GuiUtil.Colorize(quest.Title, Keywords.EMPHASIS)}! Claim it from your Quests`,
			Duration = 5,
			Sound = "CollectedReward",
			Effect = "Success",
		})

		self.OnDailyQuestCompleted:Fire(player, quest)
	end
end

-- Adds `amount` to every unfinished quest of `questType`, for the Types that count one thing with no Arg.
function DailyQuestManager:ProgressDailyQuestType(player: Player, questType: string, amount: number)
	self:ProgressDailyQuests(player, function(quest)
		return if quest.Type == questType then amount else 0
	end)
end

-- Counts one sale toward the board: the customer, each skewer, and whatever each skewer carried.
function DailyQuestManager:ProgressDailyQuestsFromSale(player: Player, skewerRecords: { StickModel.StickRecord })
	self:ProgressDailyQuests(player, function(quest)
		if quest.Type == "ServeCustomers" then
			return 1
		elseif quest.Type == "SellSkewers" then
			return #skewerRecords
		end

		local count = 0
		for _, record in skewerRecords do
			local counts = false

			if quest.Type == "ServeIngredient" then
				counts = table.find(record.Ingredients, quest.Arg) ~= nil
			elseif quest.Type == "ServeIngredientTier" then
				local tierIndex = Ingredients.GetTierFromId(quest.Arg).Index
				for _, ingredientId in record.Ingredients do
					local ingredient = Ingredients.GetIngredientFromId(ingredientId)
					if ingredient and ingredient.Tier.Index >= tierIndex then
						counts = true
						break
					end
				end
			elseif quest.Type == "ServeFullSkewer" then
				local stick = Sticks.GetStickFromId(record.StickId)
				counts = stick ~= nil and #record.Ingredients >= stick.Capacity
			elseif quest.Type == "ServeStick" then
				counts = record.StickId == quest.Arg
			elseif quest.Type == "ServeMutation" then
				counts = record.Mutation == quest.Arg
			elseif quest.Type == "ServeCookState" then
				counts = StickModel.GetCookStateId(record) == quest.Arg
			end

			if counts then
				count += 1
			end
		end

		return count
	end)
end

-- Rolls the player's next board once their current one has run its RESET_INTERVAL, paying out anything finished and left unclaimed first. Otherwise just schedules the check for when it will have.
function DailyQuestManager:RollDailyQuestsIfDue(player: Player)
	local data = PlayerDataManager:GetLoadedPlayerData(player)
	if not data or not data.TutorialCompleted then
		return
	end

	local board = data.DailyQuests
	local now = workspace:GetServerTimeNow()
	local resetsAt = board.StartedAt + DailyQuests.RESET_INTERVAL

	if now + DailyQuests.CLAIM_GRACE < resetsAt then
		self:_scheduleDailyQuestReset(player, resetsAt - now)
		return
	end

	local owed = 0
	for _, boardQuest in board.Quests do
		if not boardQuest.Claimed and boardQuest.Progress >= boardQuest.Target then
			owed += DailyQuests.QUEST_REWARD
		end
	end

	local settledReward = if DailyQuests.IsBoardComplete(board) and not board.RewardClaimed
		then board.Reward
		else nil

	-- The new board before any grant, since a grant can yield and a second roll mustn't find the old board still owed
	local count = board.Count + 1
	local quests, reward = DailyQuests.RollBoard(player.UserId, count)
	PlayerDataManager:SetPlayerDataKey(player, "DailyQuests", {
		Count = count,
		StartedAt = now,
		Quests = quests,
		Reward = reward,
		RewardClaimed = false,
	})

	if owed > 0 then
		CurrencyManager:IncrementCurrency(player, owed, "DailyQuest", true)
	end

	if settledReward then
		-- No cards to pick from at a reset, so the worker is whichever of the three the old board's seed lands on
		local candidate
		if settledReward.Type == "Worker" then
			local seed = DailyQuests.GetSeed(player.UserId, board.Count)
			local candidates = FreeWorkers.RollCandidates(seed, settledReward.Stars)
			candidate = candidates[RandomUtil.GetRandomIntFromMinMax(1, #candidates, seed)]
		end

		DailyRewardManager:GrantReward(player, settledReward, "DailyQuest", candidate)
		self.OnDailyQuestBoardCompleted:Fire(player, settledReward, true)
	end

	if owed > 0 or settledReward then
		NotificationManager:NotifyNormal(player, {
			Text = "Your unclaimed quest rewards were paid out, new quests are up!",
			Duration = 5,
			Sound = "CollectedReward",
			Effect = "Success",
		})
	end

	-- The last board's faces belong to a different three
	local portraits = player.PlayerGui:FindFirstChild(DailyQuests.PORTRAIT_FOLDER)
	if portraits then
		portraits:Destroy()
	end

	task.spawn(function()
		self:ResumeDailyQuestPortraits(player)
	end)

	self:_scheduleDailyQuestReset(player, DailyQuests.RESET_INTERVAL)
end

-- Runs RollDailyQuestsIfDue once `delay` seconds are up, replacing any check already waiting.
function DailyQuestManager:_scheduleDailyQuestReset(player: Player, delay: number)
	local existing = self._resetThreads[player]
	if existing then
		task.cancel(existing)
	end

	self._resetThreads[player] = task.delay(delay, function()
		self._resetThreads[player] = nil
		self:RollDailyQuestsIfDue(player)
	end)
end

-- Pays out one finished quest off its tile. Claiming the last of the three also hands over the board reward, unless it's a worker, whose cards the client puts up next.
function DailyQuestManager:ClaimDailyQuest(player: Player, questSlot: number): boolean
	-- Reading their data yields, so without this guard two rapid presses could both pass before either writes
	if self._claiming[player] then
		return false
	end
	self._claiming[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._claiming[player] = nil
		return false
	end

	-- The tile only claims a finished, unclaimed quest, so anything else is a forged call, refused without a toast
	local board = data.DailyQuests
	local boardQuest = type(questSlot) == "number" and board.Quests[questSlot]
	if not boardQuest or boardQuest.Claimed or boardQuest.Progress < boardQuest.Target then
		self._claiming[player] = nil
		return false
	end

	-- Stamped before the grant, as a redeemed code is
	PlayerDataManager:SetPlayerDataKey(player, { "DailyQuests", "Quests", questSlot, "Claimed" }, true)
	CurrencyManager:IncrementCurrency(player, DailyQuests.QUEST_REWARD, "DailyQuest", true)

	local reward = board.Reward
	local grantsReward = DailyQuests.IsBoardClaimed(board) and reward.Type ~= "Worker"
	if grantsReward then
		PlayerDataManager:SetPlayerDataKey(player, { "DailyQuests", "RewardClaimed" }, true)
		DailyRewardManager:GrantReward(player, reward, "DailyQuest")
	end

	self._claiming[player] = nil

	local quest = DailyQuests.GetQuestFromId(boardQuest.Id)
	local buxText = GuiUtil.Colorize(`${GuiUtil.ConvertNumberWithSuffix(DailyQuests.QUEST_REWARD)}`, Keywords.NUMBER)

	NotificationManager:NotifyNormal(player, {
		Text = if grantsReward
			then `All quests complete! You got {buxText} and {DailyRewards.GetRewardDisplay(reward)}`
			else `Claimed {buxText} for {if quest then quest.Title else "your quest"}`,
		Duration = 5,
		Sound = "CollectedReward",
		Effect = "Success",
	})

	if quest then
		self.OnDailyQuestClaimed:Fire(player, quest)
	end

	if grantsReward then
		self.OnDailyQuestBoardCompleted:Fire(player, reward, false)
	end

	return true
end

-- Hires the worker a claimed board owes, picked off its three cards. The three are re-rolled here off the same seed the client drew them from, so only the pick's slot comes over.
function DailyQuestManager:ClaimDailyQuestReward(player: Player, cardSlot: number): boolean
	if self._claiming[player] then
		return false
	end
	self._claiming[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._claiming[player] = nil
		return false
	end

	local board = data.DailyQuests
	if
		not DailyQuests.IsWorkerPickOwed(board)
		or type(cardSlot) ~= "number"
		or not FreeWorkers.SLOT_ROLES[cardSlot]
	then
		self._claiming[player] = nil
		return false
	end

	local reward = board.Reward
	local candidate = FreeWorkers.RollCandidates(DailyQuests.GetSeed(player.UserId, board.Count), reward.Stars)[cardSlot]

	PlayerDataManager:SetPlayerDataKey(player, { "DailyQuests", "RewardClaimed" }, true)
	DailyRewardManager:GrantReward(player, reward, "DailyQuest", candidate)

	-- These three are spent, so their faces go rather than stand in for the next board's
	local portraits = player.PlayerGui:FindFirstChild(DailyQuests.PORTRAIT_FOLDER)
	if portraits then
		portraits:Destroy()
	end

	self._claiming[player] = nil

	-- A hire lands unequipped, so it names who they got and where they go to work, as a worker day does
	NotificationManager:NotifyNormal(player, {
		Text = `Hired {GuiUtil.Colorize(candidate.Name, Keywords.Colors.Workers)}! Equip them at your Worker Hut`,
		Duration = 5,
		Sound = "CollectedReward",
		Effect = "Success",
	})

	self.OnDailyQuestBoardCompleted:Fire(player, reward, false)

	return true
end

-- Dresses the three on offer when the player's board reward is a worker still to be picked, so its cards have faces waiting.
function DailyQuestManager:ResumeDailyQuestPortraits(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local board = data.DailyQuests
	local reward = board.Reward
	if not reward or reward.Type ~= "Worker" or board.RewardClaimed then
		return
	end

	local count = board.Count
	local candidates = FreeWorkers.RollCandidates(DailyQuests.GetSeed(player.UserId, count), reward.Stars)
	FreeWorkersManager:BakeCandidatePortraits(player, DailyQuests.PORTRAIT_FOLDER, candidates, function(latest)
		-- A reset or a pick in the meantime moved them on, so these three are no longer the ones on offer
		return latest.DailyQuests.Count == count and not latest.DailyQuests.RewardClaimed
	end)
end

-- Adds `amount` to one quest on the player's board, or finishes it when `amount` is nil, for the progressQuest and completeQuest commands. Through the normal progress path, so it toasts as a real finish would.
function DailyQuestManager:DebugProgressDailyQuest(player: Player, questSlot: number, amount: number?): boolean
	local data = PlayerDataManager:GetLoadedPlayerData(player)
	local boardQuest = data and data.DailyQuests.Quests[questSlot]
	if not boardQuest then
		return false
	end

	-- One quest per difficulty, so its Id names exactly this tile on the board
	local questId = boardQuest.Id
	local added = amount or boardQuest.Target - boardQuest.Progress

	self:ProgressDailyQuests(player, function(quest)
		return if quest.Id == questId then added else 0
	end)

	return true
end

-- Moves the player's board so it resets in `secondsLeft`, for the resetQuests command.
function DailyQuestManager:DebugSetDailyQuestReset(player: Player, secondsLeft: number): boolean
	local data = PlayerDataManager:GetLoadedPlayerData(player)
	if not data or #data.DailyQuests.Quests == 0 then
		return false
	end

	local startedAt = workspace:GetServerTimeNow() - DailyQuests.RESET_INTERVAL + secondsLeft
	PlayerDataManager:SetPlayerDataKey(player, { "DailyQuests", "StartedAt" }, startedAt)
	self:_scheduleDailyQuestReset(player, math.max(secondsLeft, 0))

	return true
end

function DailyQuestManager:OnStart()
	self.ClaimDailyQuestEvent:OnServerEvent(function(player: Player, questSlot: number)
		self.ClaimDailyQuestResultEvent:FireClient(player, self:ClaimDailyQuest(player, questSlot))
	end)

	self.ClaimDailyQuestRewardEvent:OnServerEvent(function(player: Player, cardSlot: number)
		local success = self:ClaimDailyQuestReward(player, cardSlot)
		self.ClaimDailyQuestResultEvent:FireClient(player, success, cardSlot)
	end)

	-- Off the handover rather than PlayerAdded, so the roll and the bake wait behind the load the base waits on
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:RollDailyQuestsIfDue(player)

		task.spawn(function()
			self:ResumeDailyQuestPortraits(player)
		end)
	end)

	-- This manager can load after a player is already on a base, so sweep whoever is here
	for _, player in Players:GetPlayers() do
		self:RollDailyQuestsIfDue(player)

		task.spawn(function()
			self:ResumeDailyQuestPortraits(player)
		end)
	end

	-- A new player's first board waits for the tutorial, which otherwise hands out quests nothing can progress yet
	PlayerDataManager.OnDataChanged:Connect(function(player: Player, key: string, value: any)
		if key == "TutorialCompleted" and value == true then
			self:RollDailyQuestsIfDue(player)
		end
	end)

	SellNpcManager.OnSaleCompleted:Connect(function(player, _, skewerRecords, customerType, _, counterRounds)
		self:ProgressDailyQuestsFromSale(player, skewerRecords)

		if customerType == "Rich" then
			self:ProgressDailyQuestType(player, "ServeRichCustomer", 1)
		end

		if counterRounds > 0 then
			self:ProgressDailyQuestType(player, "AcceptCounteroffer", 1)
		end
	end)

	-- A delivered order is a customer served too, so its skewer counts toward the sale quests as well
	CustomOrderNpcManager.OnCustomOrderResolved:Connect(function(player, entry, _, delivered, isRich)
		if entry.Outcome ~= "Delivered" then
			return
		end

		self:ProgressDailyQuestsFromSale(player, { delivered })
		self:ProgressDailyQuestType(player, "DeliverCustomOrders", 1)

		if isRich then
			self:ProgressDailyQuestType(player, "ServeRichCustomer", 1)
		end

		if entry.Matched == entry.Slots and entry.Extras == 0 and entry.CookState == "Perfect" then
			self:ProgressDailyQuestType(player, "PerfectCustomOrders", 1)
		end
	end)

	-- Hungry Joe is a customer served with a BBQ too, so his stick counts toward the sale quests
	HungryJoeNpcManager.OnHungryJoeFed:Connect(function(player, delivered)
		self:ProgressDailyQuestsFromSale(player, { delivered })
	end)

	GrillerManager.OnCookCompleted:Connect(function(player, cookStateId)
		self:ProgressDailyQuests(player, function(quest)
			if quest.Type == "CookBbqs" then
				return if cookStateId ~= "Raw" then 1 else 0
			end

			return if quest.Type == "CookState" and quest.Arg == cookStateId then 1 else 0
		end)
	end)

	IngredientRollingManager.OnIngredientPurchased:Connect(function(player)
		self:ProgressDailyQuestType(player, "RollIngredients", 1)
	end)

	StickShopManager.OnStickPurchased:Connect(function(player, _, _, _, amount)
		self:ProgressDailyQuestType(player, "BuySticks", amount)
	end)

	task.spawn(function()
		while true do
			task.wait(PLAY_TIME_INTERVAL)

			for _, player in Players:GetPlayers() do
				self:ProgressDailyQuestType(player, "PlayTime", 1)
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._claiming[player] = nil

		local resetThread = self._resetThreads[player]
		if resetThread then
			task.cancel(resetThread)
			self._resetThreads[player] = nil
		end
	end)
end

return DailyQuestManager
