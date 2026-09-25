-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Server
local Server = script.Parent.Parent
local ServerRandom = require(Server.Modules.ServerRandom)

-- Shared
local Shared = ReplicatedStorage.Shared
local Colors = require(Shared.Colors)
local StickModel = require(Shared.StickModel)
local RandomUtil = require(Shared.RandomUtil)
local Sticks = require(Shared.Config.Sticks)
local Ingredients = require(Shared.Config.Ingredients)
local CustomerTips = require(Shared.Config.CustomerTips)
local Rating = require(Shared.Config.Rating)
local RatingPerks = require(Shared.Config.RatingPerks)

-- Managers
local PlayerDataManager = require(script.Parent.PlayerDataManager)
local CurrencyManager = require(script.Parent.CurrencyManager)
local NotificationManager = require(script.Parent.NotificationManager)
local EffectManager = require(script.Parent.EffectManager)

-- Rolls whether a customer leaves Gems on top of what it paid, and plays the tip out while it eats. The sell stand and the custom orders share it, so they share one gap.
local CustomerTipManager = {
	_rng = ServerRandom.MakeRNG("CustomerTip"),

	_lastTipAt = {}, -- [player] = os.clock() their last tip was rolled at, which MIN_GAP counts from
	_forcedTips = {}, -- [player] = true while their next paying customer is armed to tip, past the gap and the roll
	-- [player] = customers still to pass over after finishing the tutorial this session, before any can tip
	_quietCustomers = {},
}

-- What a skewer's quality multiplies a tip chance by: its cook state, any mutation and how rare its ingredients run.
local function getSkewerTipBoost(skewer: StickModel.StickRecord): number
	local cookMultiplier = CustomerTips.COOK_STATE_MULTIPLIERS[StickModel.GetCookStateId(skewer)] or 0
	local mutationMultiplier = if skewer.Mutation then CustomerTips.MUTATION_MULTIPLIER else 1

	local tierTotal, tierCount = 0, 0
	for _, ingredientId in skewer.Ingredients do
		-- An ingredient the config has since dropped has no tier left to read, so it sits out of the mean
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)
		if ingredient then
			tierTotal += ingredient.Tier.Index
			tierCount += 1
		end
	end

	-- Measured up from the commonest tier, as the Menu rating is, so an all-Common stick adds nothing
	local meanTier = if tierCount > 0 then tierTotal / tierCount else 1

	return cookMultiplier * mutationMultiplier * (1 + CustomerTips.TIER_STEP * (meanTier - 1))
end

-- The chance out of 100 that a stand customer tips for one skewer: its quality, and whether its stick was filled. Shared with the offline pass, so away sales tip on the same formula.
function CustomerTipManager:GetStandTipChance(skewer: StickModel.StickRecord): number
	-- A stick the config has since dropped has no capacity left to fill, so it reads as not full
	local stick = Sticks.GetStickFromId(skewer.StickId)
	local isFull = stick ~= nil and #skewer.Ingredients >= stick.Capacity

	return CustomerTips.STAND_CHANCE
		* getSkewerTipBoost(skewer)
		* (if isFull then CustomerTips.FULL_STICK_MULTIPLIER else 1)
end

-- Rolls a stand customer's tip on what it bought, playing it out on a hit. A haul rolls once, on its skewers' mean chance.
function CustomerTipManager:RollSaleTip(
	player: Player,
	npc: Model,
	soldRecords: { StickModel.StickRecord },
	sayTipping: () -> ()
)
	local chanceTotal = 0

	for _, skewer in soldRecords do
		chanceTotal += self:GetStandTipChance(skewer)
	end

	self:_tryCustomerTip(
		player,
		npc,
		chanceTotal / #soldRecords,
		CustomerTips.STAND_GEMS_MIN,
		CustomerTips.STAND_GEMS_MAX,
		"CustomerTip",
		sayTipping
	)
end

-- Rolls a custom order customer's tip on what was handed over, scaled by how much of the order it got right. Seated and rich customers tip more.
function CustomerTipManager:RollCustomOrderTip(
	player: Player,
	npc: Model,
	delivered: StickModel.StickRecord,
	accuracy: number,
	seated: boolean,
	rich: boolean,
	sayTipping: () -> ()
)
	-- Over Perfect's multiplier, so a good order -- exact and Perfect -- lands on CUSTOM_ORDER_CHANCE itself
	local chance = CustomerTips.CUSTOM_ORDER_CHANCE
		* accuracy
		* getSkewerTipBoost(delivered)
		/ CustomerTips.COOK_STATE_MULTIPLIERS.Perfect
		* (if seated then CustomerTips.SEATED_CHANCE_MULTIPLIER else 1)

	local gemsMin, gemsMax = CustomerTips.CUSTOM_ORDER_GEMS_MIN, CustomerTips.CUSTOM_ORDER_GEMS_MAX
	if rich then
		gemsMin, gemsMax = CustomerTips.RICH_GEMS_MIN, CustomerTips.RICH_GEMS_MAX
	elseif seated then
		gemsMin, gemsMax = CustomerTips.SEATED_GEMS_MIN, CustomerTips.SEATED_GEMS_MAX
	end

	self:_tryCustomerTip(player, npc, chance, gemsMin, gemsMax, "CustomOrderTip", sayTipping)
end

-- Rolls a tip at `chance` out of 100 once the gap allows, playing it out on its own thread on a hit. Must not yield, or two customers rolling at once could both slip through the gap.
function CustomerTipManager:_tryCustomerTip(
	player: Player,
	npc: Model,
	chance: number,
	gemsMin: number,
	gemsMax: number,
	source: string,
	sayTipping: () -> ()
)
	-- Here rather than in GetStandTipChance, which the offline pass shares, so the rating only pays out on live play
	chance *= RatingPerks.GetTipChanceScale(player:GetAttribute(Rating.OVERALL_ATTRIBUTE))

	-- Their first tip is a given, so Gems are shown to them rather than left to luck. Never on food that couldn't earn one
	local data = PlayerDataManager:GetLoadedPlayerData(player)
	local isFirstTip = data ~= nil and not data.SeenCustomerTip and chance > 0

	if self._forcedTips[player] then
		self._forcedTips[player] = nil
	else
		local quietCustomers = self._quietCustomers[player]
		if quietCustomers then
			self._quietCustomers[player] = if quietCustomers > 1 then quietCustomers - 1 else nil
			return
		end

		local lastTipAt = self._lastTipAt[player]
		if lastTipAt and os.clock() - lastTipAt < CustomerTips.MIN_GAP then
			return
		end

		if not isFirstTip and not RandomUtil.RollChance(chance, self._rng) then
			return
		end
	end

	self._lastTipAt[player] = os.clock()

	local gems = self._rng:NextInteger(gemsMin, gemsMax)

	task.spawn(self._playCustomerTip, self, player, npc, gems, source, isFirstTip, sayTipping)
end

-- Plays a rolled tip out mid-eat: the customer's line, a beat, then the Gems. A customer gone before either beat takes its tip with it.
function CustomerTipManager:_playCustomerTip(
	player: Player,
	npc: Model,
	gems: number,
	source: string,
	isFirstTip: boolean,
	sayTipping: () -> ()
)
	task.wait(CustomerTips.SAY_DELAY)
	if npc.Parent == nil then
		return
	end

	sayTipping()

	task.wait(CustomerTips.PAY_DELAY)
	if npc.Parent == nil then
		return
	end

	CurrencyManager:IncrementGems(player, gems, source)

	-- Marked once it lands rather than at the roll, so a customer lost mid-eat leaves the first still owed
	if isFirstTip then
		PlayerDataManager:SetPlayerDataKey(player, "SeenCustomerTip", true)
	end

	-- The tip lets each gem pop a "+X" that adds up to the counter's jump
	EffectManager:RunEffect("All", "CollectGems", { npc, gems, player })

	-- {value} is NotificationManager's placeholder for Count, so it must survive uninterpolated
	NotificationManager:NotifyNormal(player, {
		Text = "A customer tipped you {value} Gems!",
		Duration = 3,
		Effect = "Success",
		Count = {
			Value = gems,
			Format = "Comma",
			Color = Colors.Gems,
		},
	})

	-- The introduction Gems shipped without, so the first one says what they're for
	if isFirstTip then
		NotificationManager:NotifyNormal(player, {
			Text = "Customers tip Gems for good BBQ! Spend them at the Cosmetic Shop",
			Duration = 5,
			-- Not a second Success, or the explainer reads as another tip
			Sound = "Notify",
		})
	end
end

-- Arms the player's next paying customer to tip, past the gap and the roll. For testing.
function CustomerTipManager:ForceNextCustomerTip(player: Player)
	self._forcedTips[player] = true
end

function CustomerTipManager:OnStart()
	-- Only the flip TutorialManager makes on finishing, so a player who finished before this session isn't held off
	PlayerDataManager.OnDataChanged:Connect(function(player: Player, key: string, value: any)
		if key == "TutorialCompleted" and value == true then
			self._quietCustomers[player] = CustomerTips.POST_TUTORIAL_QUIET_CUSTOMERS
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._lastTipAt[player] = nil
		self._forcedTips[player] = nil
		self._quietCustomers[player] = nil
	end)
end

return CustomerTipManager
