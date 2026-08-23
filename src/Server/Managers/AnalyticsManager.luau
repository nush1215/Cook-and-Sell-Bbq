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
local IndexManager
local BaseManager
local BadgeManager
local TutorialManager
local TutorialCrateManager

--[[
	The one place AnalyticsService is spoken to. Every gameplay manager owns a Signal for what happens in
	its domain and knows nothing about analytics; this subscribes to all of them in OnStart and turns
	each into a Roblox analytics event. Nothing here can block or error gameplay: every call is wrapped
	in task.spawn + pcall.

	Custom events carry a numeric value plus up to three custom fields, which are the only breakdown
	dimensions the dashboard offers -- so what goes in each field is chosen for what's worth slicing by.
]]
local AnalyticsManager = {}

local CustomFields = Enum.AnalyticsCustomFieldKeys

-- Maps a currency source/sink label to the analytics transaction type it represents. Anything not
-- listed falls back to Gameplay.
local SOURCE_TRANSACTION_TYPES = {
	BaseUnlock = Enum.AnalyticsEconomyTransactionType.Shop.Name,
	PlotUnlock = Enum.AnalyticsEconomyTransactionType.Shop.Name,
	IngredientPurchase = Enum.AnalyticsEconomyTransactionType.Shop.Name,
	StickPurchase = Enum.AnalyticsEconomyTransactionType.Shop.Name,
	SauceDispenserUpgrade = Enum.AnalyticsEconomyTransactionType.Shop.Name,
	BuxPack = Enum.AnalyticsEconomyTransactionType.Shop.Name,
}

-- Wraps a custom event behind task.spawn/pcall so analytics never blocks or errors gameplay. Absent
-- fields are simply omitted.
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

-- Returns the ingredient's tier id, or nil for an id the config no longer has.
local function getIngredientTier(ingredientId: string): string?
	local ingredient = Ingredients.GetIngredientFromId(ingredientId)
	return ingredient and ingredient.Tier.Id
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
	IndexManager = require(script.Parent.IndexManager)
	BaseManager = require(script.Parent.BaseManager)
	BadgeManager = require(script.Parent.BadgeManager)
	TutorialManager = require(script.Parent.TutorialManager)
	TutorialCrateManager = require(script.Parent.TutorialCrateManager)
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
	-- Only three custom fields exist, and how it was paid for is worth slicing by now that a broke player
	-- is offered the ingredient for Robux instead of a rejection -- so it shares the last field with
	-- discovery rather than either dimension being dropped: "Currency", "Currency New", "Robux", "Robux New".
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
	SellNpcManager.OnSaleCompleted:Connect(function(player, offer, skewerRecords, isRich)
		logCustom(
			player,
			"Sale Completed",
			offer,
			tostring(#skewerRecords),
			if isRich then "Rich" else "Normal",
			getDominantCookState(skewerRecords)
		)
	end)
	SellNpcManager.OnSaleDeclined:Connect(function(player, offer, skewerRecords, isRich, reason)
		logCustom(
			player,
			"Sale Declined",
			offer,
			reason,
			if isRich then "Rich" else "Normal",
			getDominantCookState(skewerRecords)
		)
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

	-- Onboarding funnel. Its own Roblox event rather than a custom one: the funnel report wants an
	-- ordered step number and name, which is what TutorialManager already resolves each key into.
	TutorialManager.OnFunnelStep:Connect(function(player, stepIndex, stepName)
		task.spawn(function()
			pcall(function()
				AnalyticsService:LogOnboardingFunnelStepEvent(player, stepIndex, stepName)
			end)
		end)
	end)

	-- The tutorial's reward crate sits behind a countdown that keeps running offline, so the split is
	-- between players the wait held onto and players who had to come back for it.
	TutorialCrateManager.OnClaimed:Connect(function(player, spawnedThisSession)
		logCustom(player, "Tutorial Crate Claimed", 1, if spawnedThisSession then "SameSession" else "Rejoined")
	end)
end

return AnalyticsManager
