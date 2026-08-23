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
	-- (player, ingredientId, price, discovered, method) when a pending roll is claimed and the ingredient
	-- granted. method is "Currency" or "Robux"; price is the Bux paid, 0 on a Robux buy.
	OnIngredientPurchased = Signal.new(),

	-- The rolls themselves live in player data (data.PendingRolls), so one landed on but not bought is
	-- still sitting on its stand after a rejoin rather than thrown away.
	_inCooldown = {}, -- [player] = true, held until the roll animation has had time to finish
	_purchasing = {}, -- [player] = true, held across the CanAfford -> DeductCurrency window
	_forcedIngredients = {}, -- [player] = ingredientId, consumed by the next roll's first stand
	_pendingRobuxStand = {}, -- [player] = { StandId, IngredientId } their open ingredient Robux prompt
	-- was raised for. The ingredient is stamped as well as the stand so a pull that lands while the
	-- dialog sits open can't be handed over at the price the old one was quoted at.
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Mirrors a player's pending rolls onto their base's stand models, which is what every client renders
-- the stands from. Player data only replicates to the player it belongs to, so a visitor's client has
-- no way to read the rolls themselves -- these attributes are the only thing it can see them through.
-- Written across the whole folder rather than one stand, so a stand the table no longer covers is
-- cleared by the same pass that stamps the ones it does.
function IngredientRollingManager:WritePendingRollsToBase(player: Player, pending: { [string]: any })
	-- A server with more players than bases leaves someone without one until a base frees up.
	local baseId = player:GetAttribute("BaseId")
	if not baseId then
		return
	end

	for _, standModel in workspace.Base[baseId].Rolling.Stands:GetChildren() do
		local roll = pending[standModel.Name]

		-- Set on the one instance so the pair replicates together: the client reads both to tell a roll
		-- it should animate from one it should just land, and a stand handed only half of them would
		-- pick the wrong one.
		standModel:SetAttribute("RolledIngredient", roll and roll.IngredientId)
		standModel:SetAttribute("RolledAt", roll and roll.RolledAt)
	end
end

-- Puts a player's saved rolls back onto the base they've just been handed. A base builds its stands
-- from scratch on assignment, so a roll their last session landed but never bought has nothing to sit
-- on until it's stamped back -- and it's the stamp, not their data, that every client draws from.
function IngredientRollingManager:RestorePendingRollsToBase(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	self:WritePendingRollsToBase(player, data.PendingRolls)
end

-- Rolls one weighted-random ingredient per active stand and stores them as pending claims in player
-- data, so a pull nobody bought from is still on the stands when they come back.
-- Returns the server time the pull landed on, which the caller waits out before re-arming its lever,
-- or nil if the player is invalid or still in the roll debounce. What each stand rolled goes out on
-- the stand attributes instead, so every client gets it rather than only the puller.
function IngredientRollingManager:RollIngredientsForPlayer(player: Player): number?
	if not validatePlayer(player) then
		return nil
	end

	-- Debounce so a client can't spam the lever
	if self._inCooldown[player] then
		return nil
	end

	self._inCooldown[player] = true
	task.delay(RollingConfig.GetRollDuration(), function()
		self._inCooldown[player] = nil
	end)

	-- How many stands they've unlocked is how many ingredients one pull rolls. Read after the
	-- debounce so a failed read can't be spammed, and before the timestamp below so the wait can't
	-- eat into the window PurchaseIngredientFromStand gates the claim on.
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return nil
	end

	-- Build the weighted pool from the shared ingredient config. Weight is the reciprocal of each
	-- ingredient's authored "1 in X", and the config corrects the label to what that weight really rolls
	-- at once normalised here -- so these are the odds on the label, not something kept in step with it.
	local weighted = {}
	for _, ingredient in Ingredients.Data do
		table.insert(weighted, { ingredient.Id, ingredient.Weight })
	end

	-- Roll server-side with server-only entropy so the outcome can't be predicted client-side
	local rng = ServerRandom.MakeRNG(`IngredientRolling:{player.UserId}`)
	local rolledAt = workspace:GetServerTimeNow()
	local pending = {}

	-- Never roll more stands than the base actually shows: the render caps at this same limit, so a
	-- level nudged past it (e.g. from the command bar) can't leave rolls with no stand to land on.
	local standCount = math.min(data.Unlocks.RollingStands, BaseUnlocks.GetUnlockFromId("RollingStands").Limit)

	for standIndex = 1, standCount do
		local standId = tostring(standIndex)
		local ingredientId = RandomUtil.GetResultFromWeight(weighted, rng)

		-- An ingredient forced from the command bar lands on the first stand and leaves the rest to roll
		-- normally. Consumed here rather than up top so the early returns above -- the debounce and a failed
		-- data read -- can't eat it on a pull that never rolled anything.
		if standIndex == 1 and self._forcedIngredients[player] then
			ingredientId = self._forcedIngredients[player]
			self._forcedIngredients[player] = nil
		end

		pending[standId] = {
			IngredientId = ingredientId,
			RolledAt = rolledAt,
		}
	end

	-- Written whole rather than per stand: a pull replaces everything the last one left, so a stand the
	-- new roll doesn't cover (the player having lost a level) shouldn't keep its old claim.
	PlayerDataManager:SetPlayerDataKey(player, "PendingRolls", pending)
	self:WritePendingRollsToBase(player, pending)

	for standId, roll in pending do
		self.OnIngredientRolled:Fire(player, standId, roll.IngredientId)
	end

	return rolledAt
end

-- Pins what the player's next pull lands on their first stand, replacing that one weighted draw. Fired off
-- the command bar. Held until a pull actually rolls, then cleared, so it's worth exactly one ingredient.
function IngredientRollingManager:ForceNextIngredient(player: Player, ingredientId: string)
	self._forcedIngredients[player] = ingredientId
end

-- Claims the pending roll sitting on one stand: gates on the roll timing, charges the player, and
-- grants the ingredient into their data. Returns true only when the ingredient was actually
-- granted, so the client can gate clearing the stand on a real, server-verified purchase.
-- @param skipCurrencyCost Grant the roll without charging for it, for one already paid for in Robux
-- (see the ingredient products in Config/Products). Everything else -- the roll check, the time gate,
-- the grant, the stat and the emptying of the stand -- is wanted on both paths, so only the charge differs.
function IngredientRollingManager:PurchaseIngredientFromStand(
	player: Player,
	standId: string,
	skipCurrencyCost: boolean?
): (boolean, boolean?)
	if not validatePlayer(player) then
		return false
	end

	-- The reads below yield, so without this guard two purchases landing together could both pass the
	-- affordability check before either of them deducts. A currency buy that loses the race is simply not
	-- made; a Robux one has already been charged, so it waits its turn rather than being dropped.
	if self._purchasing[player] then
		if not skipCurrencyCost then
			return false
		end

		-- Leaving is checked as well as the guard clearing, so a guard stranded by an error can't hold
		-- this thread spinning past the session it belongs to.
		repeat
			task.wait()
		until not self._purchasing[player] or not player:IsDescendantOf(Players)

		if not player:IsDescendantOf(Players) then
			return false
		end
	end
	self._purchasing[player] = true

	-- Read once the guard is held: the claim, the affordability check and the grant all work off this one
	-- read, and the roll it holds is what says there's anything on the stand to buy.
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

	-- Time gate: a rolled ingredient can only be claimed once the animation window has passed
	if (workspace:GetServerTimeNow() - roll.RolledAt) < RollingConfig.GetRollDuration() then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = "Wait for the roll to finish!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	-- A roll now outlives the session that made it, so data can hold an ingredient the config no longer
	-- has. Clear it rather than leaving a stand that can never be bought from.
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

			-- The roll stays on the stand, and now there's somewhere for a broke player to go with it:
			-- the price band this ingredient is sold in, prompted for Robux while they're stood in front
			-- of it. Which stand the prompt went up on is remembered here rather than carried on the
			-- product -- a band is shared by every ingredient costing about the same, and its receipt
			-- arrives with nothing but the buyer on it.
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

	-- The claim is spent, so the stand goes empty until the next pull -- and stays empty across a rejoin.
	-- Clearing the attribute is what empties it on every client, the buyer's included.
	PlayerDataManager:SetPlayerDataKey(player, { "PendingRolls", standId }, nil)
	self:WritePendingRollsToBase(player, data.PendingRolls)
	self._purchasing[player] = nil
	return true, discovered
end

-- Grants an ingredient once one of the band products clears (fired by ShopManager from the product's
-- callback). It goes to the stand the prompt was raised from, which is why every band can share one
-- handler -- but only while that stand still holds what it held when the prompt went up, so a pull that
-- landed during the open dialog can't sell a Salmon at a Corn's price.
--
-- A receipt Roblox never got an answer for is re-processed on a later join, where nothing raised a prompt
-- and there's no pending stand to read. That falls back to the dearest roll still on their stands the band
-- covers -- rolls outlive the session, so there almost always is one -- and past that to the dearest
-- ingredient the band sells outright, rather than dropping a purchase the player has already paid for.
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

	-- Nothing on the stands the band reaches, so pay it out as the dearest ingredient the band is sold
	-- for. They've been charged either way, and that is exactly what the product says it buys.
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
	-- Request/response: the client invokes this and waits out the roll it stamps before re-arming its
	-- lever. What each stand landed on rides the stand attributes, so it reaches visitors too.
	self.RequestRollFunction:OnInvoke(function(player: Player)
		return self:RollIngredientsForPlayer(player)
	end)

	-- One-way claim of a pending roll. Emptying the stand is the attribute's job, since that reaches
	-- every client at once -- this reply just tells the buyer whether the ingredient was new to them,
	-- which decides whether their purchase sound would land on top of a discovery notification.
	self.PurchaseIngredientEvent:OnServerEvent(function(player: Player, standId: string)
		local success, discovered = self:PurchaseIngredientFromStand(player, standId)
		self.OnPurchasedEvent:FireClient(player, success, standId, discovered)
	end)

	-- The base rebuilds its stands as it's assigned, so anything the player's last session left on them
	-- has to be stamped back on once they're there.
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:RestorePendingRollsToBase(player)
	end)

	-- BaseManager sweeps the players already in the server as it loads, which can hand someone a base
	-- before the connect above exists -- so sweep them here as well. Spawned because the data read
	-- yields, and harmless to double up on: a player still waiting on a base has no BaseId yet, so the
	-- write bails and the signal covers them instead.
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:RestorePendingRollsToBase(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		self._inCooldown[player] = nil
		self._purchasing[player] = nil
		self._forcedIngredients[player] = nil
		self._pendingRobuxStand[player] = nil
	end)
end

return IngredientRollingManager
