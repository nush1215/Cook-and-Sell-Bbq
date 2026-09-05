-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AnalyticsService = game:GetService("AnalyticsService")

-- Shared
local Shared = ReplicatedStorage.Shared
local StickModel = require(Shared.StickModel)
local Ingredients = require(Shared.Config.Ingredients)

-- Managers (resolved in OnInit, connected to in OnStart)
local PlayerDataManager
local CurrencyManager
local ShopManager
local IngredientRollingManager
local StickShopManager
local GrillerManager
local SkewerStandManager
local SellNpcManager
local CustomOrderNpcManager
local IndexManager
local BaseManager
local BadgeManager
local TutorialManager
local TutorialCrateManager
local PlaytimeManager

-- The one place AnalyticsService is spoken to: subscribes to every manager's signals and turns each into an event. Every call is spawned and pcall'd, so it can't block or error gameplay.
local AnalyticsManager = {
	-- [player] = lever pulls this session. Not dropped on PlayerRemoving, which fires before the summary
	_sessionRolls = {},
}

local CustomFields = Enum.AnalyticsCustomFieldKeys

-- Maps a currency source or sink label to its analytics transaction type; anything unlisted is Gameplay.
local SOURCE_TRANSACTION_TYPES = {
	BaseUnlock = Enum.AnalyticsEconomyTransactionType.Shop.Name,
	PlotUnlock = Enum.AnalyticsEconomyTransactionType.Shop.Name,
	IngredientPurchase = Enum.AnalyticsEconomyTransactionType.Shop.Name,
	StickPurchase = Enum.AnalyticsEconomyTransactionType.Shop.Name,
	SauceDispenserUpgrade = Enum.AnalyticsEconomyTransactionType.Shop.Name,
	BuxPack = Enum.AnalyticsEconomyTransactionType.Shop.Name,
}

-- Fires a custom event behind spawn and pcall, so analytics never blocks or errors gameplay.
local function logCustom(
	player: Player,
	eventName: string,
	value: number,
	field1: string?,
	field2: string?,
	field3: string?
)
	task.spawn(function()
		pcall(function()
			AnalyticsService:LogCustomEvent(player, eventName, value, {
				[CustomFields.CustomField01.Name] = field1,
				[CustomFields.CustomField02.Name] = field2,
				[CustomFields.CustomField03.Name] = field3,
			})
		end)
	end)
end

-- Logs one step of an order's funnel. The id is per-order, so a repeat order is its own run rather than a second step 1.
local function logOrderFunnelStep(player: Player, funnelId: string, stepIndex: number, stepName: string)
	task.spawn(function()
		pcall(function()
			AnalyticsService:LogFunnelStepEvent(player, "Custom Order 1", funnelId, stepIndex, stepName)
		end)
	end)
end

-- Returns the tier an order reads as, its slots averaged and rounded to the nearest band.
local function getOrderTier(order): string
	return Ingredients.Tiers[math.round(order.TierIndex)].Id
end

-- Returns the ingredient's tier id, or nil for an id the config no longer has.
local function getIngredientTier(ingredientId: string): string?
	local ingredient = Ingredients.GetIngredientFromId(ingredientId)
	return ingredient and ingredient.Tier.Id
end

-- Buckets a session length, raw seconds being too granular to break a chart down by.
local function getSessionLengthBucket(sessionLength: number): string
	local minutes = sessionLength / 60

	if minutes < 1 then
		return "0-1m"
	elseif minutes < 5 then
		return "1-5m"
	elseif minutes < 15 then
		return "5-15m"
	elseif minutes < 30 then
		return "15-30m"
	elseif minutes < 60 then
		return "30-60m"
	end

	return "60m+"
end

-- Returns the cook state most of a haul's skewers share, so a bulk sale still reads as one quality.
local function getDominantCookState(skewerRecords: { StickModel.StickRecord }): string?
	local counts = {}
	local dominant, dominantCount = nil, 0
	for _, skewerRecord in skewerRecords do
		local cookState = StickModel.GetCookStateId(skewerRecord)
		counts[cookState] = (counts[cookState] or 0) + 1
		if counts[cookState] > dominantCount then
			dominant, dominantCount = cookState, counts[cookState]
		end
	end

	return dominant
end

-- Logs a soft-currency (Bux) flow, reading the ending balance after the change.
function AnalyticsManager:_onCurrencyChanged(player: Player, amount: number, source: string?, isGain: boolean)
	if not source then
		return
	end

	local flowType = if isGain then Enum.AnalyticsEconomyFlowType.Source else Enum.AnalyticsEconomyFlowType.Sink
	local transactionType = SOURCE_TRANSACTION_TYPES[source] or Enum.AnalyticsEconomyTransactionType.Gameplay.Name
	task.spawn(function()
		pcall(function()
			PlayerDataManager:GetPlayerDataKey(player, "Currency"):andThen(function(currency)
				AnalyticsService:LogEconomyEvent(player, flowType, "Bux", amount, currency, transactionType, source)
			end)
		end)
	end)
end

-- Logs a Robux purchase as an IAP sink.
function AnalyticsManager:_onRobuxPurchase(player: Player, sku: string, robuxAmount: number)
	task.spawn(function()
		pcall(function()
			AnalyticsService:LogEconomyEvent(
				player,
				Enum.AnalyticsEconomyFlowType.Sink,
				"Robux",
				robuxAmount,
				0,
				Enum.AnalyticsEconomyTransactionType.IAP.Name,
				sku
			)
		end)
	end)
end

function AnalyticsManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	ShopManager = require(script.Parent.ShopManager)
	IngredientRollingManager = require(script.Parent.IngredientRollingManager)
	StickShopManager = require(script.Parent.StickShopManager)
	GrillerManager = require(script.Parent.GrillerManager)
	SkewerStandManager = require(script.Parent.SkewerStandManager)
	SellNpcManager = require(script.Parent.SellNpcManager)
	CustomOrderNpcManager = require(script.Parent.CustomOrderNpcManager)
	IndexManager = require(script.Parent.IndexManager)
	BaseManager = require(script.Parent.BaseManager)
	BadgeManager = require(script.Parent.BadgeManager)
	TutorialManager = require(script.Parent.TutorialManager)
	TutorialCrateManager = require(script.Parent.TutorialCrateManager)
	PlaytimeManager = require(script.Parent.PlaytimeManager)
end

function AnalyticsManager:OnStart()
	-- Economy
	CurrencyManager.OnCurrencyChanged:Connect(function(player, amount, source, isGain)
		self:_onCurrencyChanged(player, amount, source, isGain)
	end)

	-- Monetization
	ShopManager.OnRobuxPurchase:Connect(function(player, sku, robuxAmount)
		self:_onRobuxPurchase(player, sku, robuxAmount)
	end)
	ShopManager.OnPurchasePromptShown:Connect(function(player, itemId, itemType, isGift)
		logCustom(player, "Purchase Prompt Shown", 1, itemId, itemType, if isGift then "Gift" else "Self")
	end)
	ShopManager.OnPurchaseCancelled:Connect(function(player, itemId)
		logCustom(player, "Purchase Cancelled", 1, itemId)
	end)
	ShopManager.OnCurrencyUpsellShown:Connect(function(player, shortfall)
		logCustom(player, "Currency Upsell Shown", shortfall)
	end)
	ShopManager.OnGiftDelivered:Connect(function(buyer, itemId, itemType)
		logCustom(buyer, if itemType == "Gamepass" then "Gifted Gamepass" else "Gifted Product", 1, itemId)
	end)

	-- Core loop: roll -> buy -> cook -> display -> sell
	IngredientRollingManager.OnIngredientRolled:Connect(function(player, standId, ingredientId)
		logCustom(player, "Ingredient Rolled", 1, ingredientId, getIngredientTier(ingredientId), standId)
	end)
	-- A teaser fires the roll event too, so this is what tells the two apart -- otherwise the top of the roll distribution reads far too generous
	IngredientRollingManager.OnIngredientTeased:Connect(function(player, standId, ingredientId)
		logCustom(player, "Ingredient Teased", 1, ingredientId, getIngredientTier(ingredientId), standId)
	end)
	-- Off the per-pull signal, or a pull would count once per unlocked stand. One event per session
	IngredientRollingManager.OnRollPerformed:Connect(function(player)
		self._sessionRolls[player] = (self._sessionRolls[player] or 0) + 1
	end)
	-- Only three fields exist, so payment shares the last with discovery: "Currency", "Currency New", "Robux", "Robux New"
	IngredientRollingManager.OnIngredientPurchased:Connect(function(player, ingredientId, price, discovered, method)
		logCustom(
			player,
			"Ingredient Bought",
			price,
			ingredientId,
			getIngredientTier(ingredientId),
			`{method}{if discovered then " New" else ""}`
		)
	end)
	StickShopManager.OnStickPurchased:Connect(function(player, stickId, price, method)
		logCustom(player, "Stick Bought", price, stickId, method)
	end)
	GrillerManager.OnCookCompleted:Connect(function(player, cookStateId, elapsed, method)
		logCustom(player, "Cook Completed", elapsed, cookStateId, method)
	end)
	SkewerStandManager.OnSkewerPlaced:Connect(function(player, record, placedCount)
		logCustom(player, "Skewer Placed", 1, StickModel.GetCookStateId(record), tostring(placedCount))
	end)
	SellNpcManager.OnSaleCompleted:Connect(function(player, offer, skewerRecords, customerType)
		logCustom(
			player,
			"Sale Completed",
			offer,
			tostring(#skewerRecords),
			customerType,
			getDominantCookState(skewerRecords)
		)
	end)
	SellNpcManager.OnSaleDeclined:Connect(function(player, offer, skewerRecords, customerType, reason)
		logCustom(player, "Sale Declined", offer, reason, customerType, getDominantCookState(skewerRecords))
	end)
	-- The value is how long they took to stock the stand, so an ignored one reads as the full wait
	SellNpcManager.OnCheckingVisitEnded:Connect(function(player, converted, waited)
		logCustom(player, "Checking Visit Ended", math.round(waited), if converted then "Converted" else "Ignored")
	end)
	-- The guaranteed first order is given rather than rolled for, so it has to be separable or it flatters the take-up
	CustomOrderNpcManager.OnCustomOrderOffered:Connect(function(player, order, payout, variation, firstVisit, funnelId)
		logCustom(
			player,
			"Custom Order Offered",
			payout,
			variation,
			`{#order.Ingredients}x{getOrderTier(order)}`,
			if firstVisit then "First" else "Repeat"
		)
		logOrderFunnelStep(player, funnelId, 1, "Offered")
	end)
	-- No event of its own: the funnel is what the acceptance is for, and the order's shape is on the offer
	CustomOrderNpcManager.OnCustomOrderAccepted:Connect(function(player, _, funnelId)
		logOrderFunnelStep(player, funnelId, 2, "Accepted")
	end)
	-- Three fields, so the order is logged by how it ended, how well it matched and how it cooked; the rest is in CustomOrderHistory
	CustomOrderNpcManager.OnCustomOrderResolved:Connect(function(player, entry, funnelId)
		local match = if entry.Matched == entry.Slots and entry.Extras == 0
			then "Exact"
			elseif entry.Matched > 0 then "Partial"
			else "Wrong"

		logCustom(player, "Custom Order Resolved", entry.Paid, entry.Outcome, match, entry.CookState)

		-- Only the one ending is a completion; the funnel reads the other three as the drop-off they are
		if entry.Outcome == "Delivered" then
			logOrderFunnelStep(player, funnelId, 3, "Delivered")
		end
	end)
	IndexManager.OnIngredientDiscovered:Connect(function(player, ingredientId)
		logCustom(player, "Ingredient Discovered", 1, ingredientId, getIngredientTier(ingredientId))
	end)

	-- Progression
	BaseManager.OnUnlockPurchased:Connect(function(player, unlockId, newLevel, cost, method)
		if newLevel == 1 then
			logCustom(player, "Base Unlocked", cost, unlockId, method)
		else
			logCustom(player, "Base Upgraded", cost, unlockId, tostring(newLevel), method)
		end
	end)
	BaseManager.OnPlotPurchased:Connect(function(player, plotId, newCount, cost, method)
		logCustom(player, "Plot Unlocked", cost, plotId, tostring(newCount), method)
	end)
	BadgeManager.OnBadgeAwarded:Connect(function(player, badgeKey)
		logCustom(player, "Badge Awarded", 1, badgeKey)
	end)

	-- One funnel per variant, so a rework reports separately. The 2 is versioning -- the cooking beats merged when the knob went
	TutorialManager.OnFunnelStep:Connect(function(player, variant, stepIndex, stepName)
		task.spawn(function()
			pcall(function()
				AnalyticsService:LogFunnelStepEvent(player, `Tutorial {variant} 2`, nil, stepIndex, stepName)
			end)
		end)
	end)

	-- The crate's countdown runs offline, so this splits players the wait held from those who came back
	TutorialCrateManager.OnClaimed:Connect(function(player, spawnedThisSession)
		logCustom(player, "Tutorial Crate Claimed", 1, if spawnedThisSession then "SameSession" else "Rejoined")
	end)

	-- OnSessionEnded rides the pre-cleanup hook, so it covers every ending and still holds a valid player
	PlaytimeManager.OnSessionEnded:Connect(function(player, sessionLength)
		-- Sessions that never rolled are logged too, or the average biases up and hides who never reached the lever
		local rolls = self._sessionRolls[player] or 0
		self._sessionRolls[player] = nil

		logCustom(player, "Session Rolls", rolls, getSessionLengthBucket(sessionLength))
	end)
end

return AnalyticsManager
