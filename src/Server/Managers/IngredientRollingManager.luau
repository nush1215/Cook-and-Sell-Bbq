-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Server
local Server = script.Parent.Parent
local ServerRandom = require(Server.Modules.ServerRandom)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local RandomUtil = require(Shared.RandomUtil)
local Ingredients = require(Shared.Config.Ingredients)
local RollingConfig = require(Shared.Config.Rolling)
local BaseUnlocks = require(Shared.Config.BaseUnlocks)
local EarlyBoost = require(Shared.Config.EarlyBoost)

--
local PlayerDataManager
local CurrencyManager
local NotificationManager
local IngredientManager
local StatsManager
local BaseManager
local ShopManager

--
local IngredientRollingManager = {
	RequestRollFunction = Network.Function("RequestRoll"),
	PurchaseIngredientEvent = Network.Event("PurchaseIngredient"),
	OnPurchasedEvent = Network.Event("OnIngredientPurchased"),

	-- (player, standId, ingredientId) once per stand on every pull.
	OnIngredientRolled = Signal.new(),
	-- (player) once per accepted lever pull, where OnIngredientRolled fires once per stand
	OnRollPerformed = Signal.new(),
	-- (player, ingredientId, price, discovered, method) on a claim; method is "Currency" or "Robux"
	OnIngredientPurchased = Signal.new(),
	-- (player, standId, ingredientId) on a teaser. Fires alongside OnIngredientRolled, not instead of it
	OnIngredientTeased = Signal.new(),

	-- The rolls live in player data (data.PendingRolls), so one landed on but not bought survives a rejoin.
	_inCooldown = {}, -- [player] = true, held until the roll animation has had time to finish
	_purchasing = {}, -- [player] = true, held across the CanAfford -> DeductCurrency window
	_forcedIngredients = {}, -- [player] = ingredientId, consumed by the next roll's first stand
	_forcedTeasers = {}, -- [player] = true, makes the next pull tease past its chance roll
	-- [player] = { StandId, IngredientId } the open Robux prompt was raised for, so a new pull can't reprice it
	_pendingRobuxStand = {},
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Mirrors pending rolls onto the stand models, which is a visitor's only view of them. Written folder-wide.
function IngredientRollingManager:WritePendingRollsToBase(player: Player, pending: { [string]: any })
	-- A server with more players than bases leaves someone without one until a base frees up.
	local baseId = player:GetAttribute("BaseId")
	if not baseId then
		return
	end

	for _, standModel in workspace.Base[baseId].Rolling.Stands:GetChildren() do
		local roll = pending[standModel.Name]

		-- All on one instance so they replicate together -- a partial stand would pick the wrong animation
		standModel:SetAttribute("RolledIngredient", roll and roll.IngredientId)
		standModel:SetAttribute("RolledAt", roll and roll.RolledAt)
		standModel:SetAttribute("RollSpeedLevel", roll and roll.SpeedLevel)
	end
end

-- Stamps saved rolls back onto a freshly handed-over base, whose stands are built from scratch.
function IngredientRollingManager:RestorePendingRollsToBase(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	self:WritePendingRollsToBase(player, data.PendingRolls)
end

-- The ingredient a due pity counter forces, or nil. Rarest first; affordability doesn't come into it.
function IngredientRollingManager:DrawPityIngredient(pity: { [string]: number }, rng: Random): string?
	for _, tier in Ingredients.PITY_TIERS do
		if (pity[tier.Id] or 0) >= tier.PityThreshold then
			return RandomUtil.GetResultFromWeight(tier.PityWeights, rng)
		end
	end

	return nil
end

-- The teaser pool: cool ingredients priced clear of `balance`, so one stays out of reach after the next sale.
function IngredientRollingManager:GetTeaserCandidates(currency: number): { string }
	local outOfReach = currency * EarlyBoost.TEASE_AFFORD_MARGIN
	local candidates = {}

	for _, ingredient in Ingredients.Data do
		if ingredient.Tier.Index >= Ingredients.COOL_TIER_INDEX and ingredient.Price > outOfReach then
			table.insert(candidates, ingredient.Id)
		end
	end

	return candidates
end

-- A cool ingredient they can't afford, for a pull to show off instead of rolling. Drawn flat, not by weight -- see docs/balance.md.
function IngredientRollingManager:DrawTeaserIngredient(player: Player, currency: number, rng: Random): string?
	if self._forcedTeasers[player] then
		self._forcedTeasers[player] = nil
	elseif not RandomUtil.RollChance(EarlyBoost.GetTeaseChance(CurrencyManager:GetEarlyBoostEarnings(player)), rng) then
		return nil
	end

	-- Nil on an empty pool, which is the right answer for a player who can afford everything worth showing
	return RandomUtil.GetRandomFromArray(self:GetTeaserCandidates(currency), nil, rng)
end

-- Rolls one ingredient per active stand into data.PendingRolls. Returns the pull's time and duration, or nil.
function IngredientRollingManager:RollIngredientsForPlayer(player: Player): (number?, number?)
	if not validatePlayer(player) then
		return nil
	end

	-- Debounce so a client can't spam the lever
	if self._inCooldown[player] then
		return nil
	end

	-- Raised before the read, which yields; the failed path must drop it by hand or they can never roll
	self._inCooldown[player] = true

	-- Read before the timestamp below, so the wait can't eat into the window the claim is gated on.
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._inCooldown[player] = nil
		return nil
	end

	local speedLevel = data.Unlocks.RollSpeed
	local duration = RollingConfig.GetRollDuration(speedLevel)

	task.delay(duration, function()
		self._inCooldown[player] = nil
	end)

	-- Weight is the reciprocal of the authored odds, corrected at load, so these are the odds on the label
	local weighted = {}
	for _, ingredient in Ingredients.Data do
		table.insert(weighted, { ingredient.Id, ingredient.Weight })
	end

	-- Roll server-side with server-only entropy so the outcome can't be predicted client-side
	local rng = ServerRandom.MakeRNG(`IngredientRolling:{player.UserId}`)
	local rolledAt = workspace:GetServerTimeNow()
	local pending = {}

	-- Never more stands than the base shows, so a level nudged past the cap can't strand a roll
	local standCount = math.min(data.Unlocks.RollingStands, BaseUnlocks.GetUnlockFromId("RollingStands").Limit)

	-- Cloned and written once -- a pull moves every counter, and one write beats one per tier per stand
	local pity = table.clone(data.Pity)

	-- Held off through the tutorial, which pins the first stand to something always affordable
	local teaserIngredientId = if data.TutorialCompleted
		then self:DrawTeaserIngredient(player, data.Currency, rng)
		else nil

	-- Drawn once per pull, so a wide base can't lose several stands to one lucky chance
	local teaserStandIndex = if teaserIngredientId then rng:NextInteger(1, standCount) else nil
	local teasedStandId = nil

	for standIndex = 1, standCount do
		local standId = tostring(standIndex)
		local ingredientId = self:DrawPityIngredient(pity, rng)

		-- A guarantee they're owed outranks a window-shop, so the teaser takes no stand pity claimed
		local isTeaser = ingredientId == nil and standIndex == teaserStandIndex
		if isTeaser then
			ingredientId = teaserIngredientId
		end

		ingredientId = ingredientId or RandomUtil.GetResultFromWeight(weighted, rng)

		-- Consumed here, not up top, so an early return can't eat it on a pull that rolled nothing
		if standIndex == 1 and self._forcedIngredients[player] then
			ingredientId = self._forcedIngredients[player]
			self._forcedIngredients[player] = nil
			isTeaser = false
		end

		if isTeaser then
			teasedStandId = standId
		end

		-- Counted off what landed, so a pity payout resets its own counter. A teaser counts up but resets nothing
		local landedIndex = Ingredients.GetIngredientFromId(ingredientId).Tier.Index
		for _, tier in Ingredients.PITY_TIERS do
			pity[tier.Id] = if not isTeaser and landedIndex >= tier.Index then 0 else (pity[tier.Id] or 0) + 1
		end

		pending[standId] = {
			IngredientId = ingredientId,
			RolledAt = rolledAt,
			SpeedLevel = speedLevel,
		}
	end

	PlayerDataManager:SetPlayerDataKey(player, "Pity", pity)

	-- Written whole, so a stand the new roll doesn't cover can't keep its old claim
	PlayerDataManager:SetPlayerDataKey(player, "PendingRolls", pending)
	self:WritePendingRollsToBase(player, pending)

	self.OnRollPerformed:Fire(player)

	for standId, roll in pending do
		self.OnIngredientRolled:Fire(player, standId, roll.IngredientId)
	end

	if teasedStandId then
		self.OnIngredientTeased:Fire(player, teasedStandId, pending[teasedStandId].IngredientId)
	end

	return rolledAt, duration
end

-- Pins the next pull's first stand, off the command bar. Cleared by the pull that uses it.
function IngredientRollingManager:ForceNextIngredient(player: Player, ingredientId: string)
	self._forcedIngredients[player] = ingredientId
end

-- Arms a teaser on the next pull, off the command bar. Can't conjure a pool, and is spent either way.
function IngredientRollingManager:ForceNextTeaser(player: Player)
	self._forcedTeasers[player] = true
end

-- Sets one of a player's pity counters, off the command bar -- the rarest rung is thousands of rolls out.
function IngredientRollingManager:SetPlayerPityCount(player: Player, tierId: string, count: number)
	PlayerDataManager:SetPlayerDataKey(player, { "Pity", tierId }, count)
end

-- Claims one stand's pending roll: gates on timing, charges, grants. True only on an actual grant.
function IngredientRollingManager:PurchaseIngredientFromStand(
	player: Player,
	standId: string,
	skipCurrencyCost: boolean?
): (boolean, boolean?)
	if not validatePlayer(player) then
		return false
	end

	-- The reads yield, so two purchases could both pass the affordability check before either deducts
	if self._purchasing[player] then
		if not skipCurrencyCost then
			return false
		end

		-- Leaving is checked too, so a guard stranded by an error can't spin this thread past its session.
		repeat
			task.wait()
		until not self._purchasing[player] or not player:IsDescendantOf(Players)

		if not player:IsDescendantOf(Players) then
			return false
		end
	end
	self._purchasing[player] = true

	-- Read once the guard is held: the claim, the affordability check and the grant all work off it.
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._purchasing[player] = nil
		return false
	end

	local roll = data.PendingRolls[standId]
	if not roll then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = "Roll for an ingredient first!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	-- Gated at the speed the pull was made at, not the player's now, so it matches what clients animate
	if (workspace:GetServerTimeNow() - roll.RolledAt) < RollingConfig.GetRollDuration(roll.SpeedLevel) then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = "Wait for the roll to finish!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	-- A roll outlives its session, so it can name a dropped ingredient. Cleared rather than left unbuyable
	local ingredient = Ingredients.GetIngredientFromId(roll.IngredientId)
	if not ingredient then
		PlayerDataManager:SetPlayerDataKey(player, { "PendingRolls", standId }, nil)
		self:WritePendingRollsToBase(player, data.PendingRolls)
		self._purchasing[player] = nil
		return false
	end

	if not skipCurrencyCost then
		local canAfford = CurrencyManager:CanAfford(player, ingredient.Price)
		if not canAfford then
			self._purchasing[player] = nil

			-- Said before the dialog, since the prompt names the band's product rather than what it was raised over
			NotificationManager:NotifyNormal(player, {
				Text = `You can't afford {ingredient.Name}`,
				Duration = 3,
				Sound = "Reject",
				Effect = "Error",
			})

			-- Which stand is remembered here, since a band is shared and its receipt names only the buyer
			self._pendingRobuxStand[player] = { StandId = standId, IngredientId = roll.IngredientId }
			ShopManager:AttemptProductPurchase(player, Ingredients.GetProductStringIdForPrice(ingredient.Price))
			return false
		end

		CurrencyManager:DeductCurrency(player, ingredient.Price, "IngredientPurchase")
	end

	local discovered = IngredientManager:GrantIngredient(player, roll.IngredientId)
	StatsManager:RecordIngredientsBought(player)
	self.OnIngredientPurchased:Fire(
		player,
		roll.IngredientId,
		if skipCurrencyCost then 0 else ingredient.Price,
		discovered,
		if skipCurrencyCost then "Robux" else "Currency"
	)

	-- Clearing the attribute is what empties the stand on every client, the buyer's included
	PlayerDataManager:SetPlayerDataKey(player, { "PendingRolls", standId }, nil)
	self:WritePendingRollsToBase(player, data.PendingRolls)
	self._purchasing[player] = nil
	return true, discovered
end

-- Grants an ingredient once its band product clears, only while the stand still holds what it held then.
function IngredientRollingManager:GrantIngredientFromProduct(player: Player, tier: number)
	local pending = self._pendingRobuxStand[player]
	self._pendingRobuxStand[player] = nil

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local standId
	if pending then
		local roll = data.PendingRolls[pending.StandId]
		if roll and roll.IngredientId == pending.IngredientId then
			standId = pending.StandId
		end
	end

	if not standId then
		local dearest
		for id, roll in data.PendingRolls do
			local ingredient = Ingredients.GetIngredientFromId(roll.IngredientId)
			if not ingredient or Ingredients.GetProductTier(ingredient.Price) > tier then
				continue
			end

			if not dearest or ingredient.Price > dearest then
				standId, dearest = id, ingredient.Price
			end
		end
	end

	if standId then
		self:PurchaseIngredientFromStand(player, standId, true)
		return
	end

	-- Pay out the band's dearest ingredient -- exactly what the product says it buys, and they've been charged
	local ingredient = Ingredients.GetDearestIngredientInProductTier(tier)
	if ingredient then
		local discovered = IngredientManager:GrantIngredient(player, ingredient.Id)
		StatsManager:RecordIngredientsBought(player)
		self.OnIngredientPurchased:Fire(player, ingredient.Id, 0, discovered, "Robux")
	end
end

function IngredientRollingManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	NotificationManager = require(script.Parent.NotificationManager)
	IngredientManager = require(script.Parent.IngredientManager)
	StatsManager = require(script.Parent.StatsManager)
	BaseManager = require(script.Parent.BaseManager)
	ShopManager = require(script.Parent.ShopManager)
end

function IngredientRollingManager:OnStart()
	-- The client waits this out before re-arming its lever; what each stand landed on rides the attributes
	self.RequestRollFunction:OnInvoke(function(player: Player)
		return self:RollIngredientsForPlayer(player)
	end)

	-- This reply only tells the buyer whether it was new, so their sound doesn't land on a discovery toast
	self.PurchaseIngredientEvent:OnServerEvent(function(player: Player, standId: string)
		local success, discovered = self:PurchaseIngredientFromStand(player, standId)
		self.OnPurchasedEvent:FireClient(player, success, standId, discovered)
	end)

	-- The base rebuilds its stands on assignment, so last session's rolls have to be stamped back on.
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:RestorePendingRollsToBase(player)
	end)

	-- Covers a base handed over before the connect above existed. Spawned, since the read yields
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:RestorePendingRollsToBase(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		self._inCooldown[player] = nil
		self._purchasing[player] = nil
		self._forcedIngredients[player] = nil
		self._forcedTeasers[player] = nil
		self._pendingRobuxStand[player] = nil
	end)
end

return IngredientRollingManager
