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
	-- (player) once per lever pull the server accepted. OnIngredientRolled above is per stand, so a
	-- player with several of them fires it many times for the one pull and can't be counted for this.
	OnRollPerformed = Signal.new(),
	-- (player, ingredientId, price, discovered, method) when a pending roll is claimed and the ingredient
	-- granted. method is "Currency" or "Robux"; price is the Bux paid, 0 on a Robux buy.
	OnIngredientPurchased = Signal.new(),
	-- (player, standId, ingredientId) when a pull hands a stand over to an early-game window-shop rather
	-- than a roll. Fires alongside OnIngredientRolled rather than instead of it -- the stand really does
	-- hold the thing -- so anything counting rolls can tell the shown ones from the won ones.
	OnIngredientTeased = Signal.new(),

	-- The rolls live in player data (data.PendingRolls), so one landed on but not bought survives a rejoin.
	_inCooldown = {}, -- [player] = true, held until the roll animation has had time to finish
	_purchasing = {}, -- [player] = true, held across the CanAfford -> DeductCurrency window
	_forcedIngredients = {}, -- [player] = ingredientId, consumed by the next roll's first stand
	_forcedTeasers = {}, -- [player] = true, makes the next pull tease past its chance roll
	-- [player] = { StandId, IngredientId } their open Robux prompt was raised for. The ingredient is
	-- stamped too, so a pull landing while the dialog sits open can't be handed over at the old price.
	_pendingRobuxStand = {},
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Mirrors a player's pending rolls onto their stand models, which is what every client renders from --
-- data reaches only its owner, so these attributes are a visitor's only view of them. Written across the
-- whole folder, so a stand the table no longer covers is cleared by the same pass.
function IngredientRollingManager:WritePendingRollsToBase(player: Player, pending: { [string]: any })
	-- A server with more players than bases leaves someone without one until a base frees up.
	local baseId = player:GetAttribute("BaseId")
	if not baseId then
		return
	end

	for _, standModel in workspace.Base[baseId].Rolling.Stands:GetChildren() do
		local roll = pending[standModel.Name]

		-- All three on one instance so they replicate together -- a stand handed only some of them would
		-- pick the wrong animation. SpeedLevel rides along for the same reason as the rest: a visitor
		-- cycling at their own speed would land the roll outside the window the server allows.
		standModel:SetAttribute("RolledIngredient", roll and roll.IngredientId)
		standModel:SetAttribute("RolledAt", roll and roll.RolledAt)
		standModel:SetAttribute("RollSpeedLevel", roll and roll.SpeedLevel)
	end
end

-- Puts saved rolls back onto a freshly handed-over base. Its stands are built from scratch on assignment,
-- so an unbought roll has nothing to sit on until it's stamped back -- and the stamp is what clients draw.
function IngredientRollingManager:RestorePendingRollsToBase(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	self:WritePendingRollsToBase(player, data.PendingRolls)
end

-- The ingredient a due pity counter forces onto one roll, or nil if none is due and it should roll normally.
-- Scanned rarest first, so two counters coming due on the same roll pay out the better one. A counter
-- watches its tier *or better* but pays out the tier itself (Config.Ingredients holds the weights), so the
-- guarantee is a floor and anything above it still has to be won.
--
-- What the player can afford doesn't come into it: a pity Lamb lands on the stand whether or not they have
-- the $60,000 for it, the same as a lucky one would. An unbought roll keeps its stand with no expiry, so
-- earning the money and coming back for it is the intended path.
function IngredientRollingManager:DrawPityIngredient(pity: { [string]: number }, rng: Random): string?
	for _, tier in Ingredients.PITY_TIERS do
		if (pity[tier.Id] or 0) >= tier.PityThreshold then
			return RandomUtil.GetResultFromWeight(tier.PityWeights, rng)
		end
	end

	return nil
end

-- Every cool ingredient priced clear of this much Bux: the pool a teaser draws from. Priced clear rather
-- than merely above, so a teaser is still out of reach after the sale the player was about to make.
--
-- Comes back empty for someone rich enough that nothing worth showing off is out of reach, which is the
-- teaser retiring itself on their balance before the early-game fade gets to it on their earnings.
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

-- A cool ingredient this player can't afford, for a pull to show off instead of rolling, or nil if they
-- rolled no teaser this pull -- past the early game, or rich enough that nothing is out of reach.
--
-- The point is the want, not the ingredient. An early base rolls almost nothing but Commons and the good
-- stuff is thousands of rolls out, so nothing tells a new player what they're playing towards. This puts
-- it on their own stand where they can walk up to it and read the price off the billboard, and the price
-- is the real one -- an unaffordable roll is already a thing this game does (see DrawPityIngredient), so
-- there's nothing here to mark up or lock. What they can't do is buy it, which is the whole idea.
--
-- Drawn flat rather than by weight, and that's deliberate: on the roll odds seven teasers in eight would
-- be Rares and Lamb would show about one in fifty, which is no showcase at all. Flat puts it at five in
-- eight and one in eight, and the pool climbs the ladder on its own as the player's balance does. The
-- label still reads its authored odds, the same call PITY_TIERS documents -- what pity and this add is
-- meant to be felt rather than read.
function IngredientRollingManager:DrawTeaserIngredient(player: Player, currency: number, rng: Random): string?
	if self._forcedTeasers[player] then
		self._forcedTeasers[player] = nil
	elseif not RandomUtil.RollChance(EarlyBoost.GetTeaseChance(CurrencyManager:GetEarlyBoostEarnings(player)), rng) then
		return nil
	end

	-- Nil on an empty pool, which is the right answer for a player who can afford everything worth showing
	return RandomUtil.GetRandomFromArray(self:GetTeaserCandidates(currency), nil, rng)
end

-- Rolls one weighted-random ingredient per active stand and stores them as pending claims in player data.
-- Returns the pull's server time and duration for the caller to wait out before re-arming its lever, or
-- nil if invalid or debounced. What each stand rolled goes out on the stand attributes, not here.
function IngredientRollingManager:RollIngredientsForPlayer(player: Player): (number?, number?)
	if not validatePlayer(player) then
		return nil
	end

	-- Debounce so a client can't spam the lever
	if self._inCooldown[player] then
		return nil
	end

	-- Raised before the read, which yields -- a lever spammed across it would get several pulls through.
	-- The hold length depends on their roll speed, so the release is scheduled after the read lands, and
	-- the failed-read path must drop it by hand or the player can never roll again.
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

	-- Weight is the reciprocal of each ingredient's authored "1 in X". The config corrects each label to
	-- what that weight really rolls at once normalised here, so these *are* the odds on the label.
	local weighted = {}
	for _, ingredient in Ingredients.Data do
		table.insert(weighted, { ingredient.Id, ingredient.Weight })
	end

	-- Roll server-side with server-only entropy so the outcome can't be predicted client-side
	local rng = ServerRandom.MakeRNG(`IngredientRolling:{player.UserId}`)
	local rolledAt = workspace:GetServerTimeNow()
	local pending = {}

	-- Never more stands than the base shows: the render caps at the same limit, so a level nudged past it
	-- from the command bar can't leave rolls with no stand to land on.
	local standCount = math.min(data.Unlocks.RollingStands, BaseUnlocks.GetUnlockFromId("RollingStands").Limit)

	-- Cloned and written back once below: a pull moves every counter, and one write beats a nested one per
	-- tier per stand.
	local pity = table.clone(data.Pity)

	-- Held off until the tutorial is done: it pins the first stand to an ingredient the player can always
	-- afford for exactly this reason, and a teaser is the opposite of that.
	local teaserIngredientId = if data.TutorialCompleted
		then self:DrawTeaserIngredient(player, data.Currency, rng)
		else nil

	-- Drawn once for the pull rather than per stand, so a wide base can't lose several of them to one
	-- lucky chance -- a teaser costs the stand it takes.
	local teaserStandIndex = if teaserIngredientId then rng:NextInteger(1, standCount) else nil
	local teasedStandId = nil

	for standIndex = 1, standCount do
		local standId = tostring(standIndex)
		local ingredientId = self:DrawPityIngredient(pity, rng)

		-- A guarantee the player is owed outranks a window-shop they can't buy, so the teaser only takes a
		-- stand no pity payout claimed.
		local isTeaser = ingredientId == nil and standIndex == teaserStandIndex
		if isTeaser then
			ingredientId = teaserIngredientId
		end

		ingredientId = ingredientId or RandomUtil.GetResultFromWeight(weighted, rng)

		-- A forced ingredient lands on the first stand, the rest roll normally. Consumed here rather than
		-- up top, so the early returns above can't eat it on a pull that never rolled anything.
		if standIndex == 1 and self._forcedIngredients[player] then
			ingredientId = self._forcedIngredients[player]
			self._forcedIngredients[player] = nil
			isTeaser = false
		end

		if isTeaser then
			teasedStandId = standId
		end

		-- Counted off what landed rather than how it was chosen, so a pity payout resets its own counter
		-- the same way a natural roll does -- which is what re-arms it -- and a forced Lamb off the command
		-- bar doesn't leave a Legendary pity still owed.
		--
		-- A teaser is the one thing that lands without resetting anything: it's shown, not won, so clearing
		-- a guarantee on it would take away something the player never got to own. It still counts up, the
		-- same as the ordinary roll it replaced almost certainly would have.
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

	-- Written whole: a pull replaces everything the last left, so a stand the new roll doesn't cover
	-- (having lost a level) shouldn't keep its old claim.
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

-- Pins what the next pull lands on the first stand, replacing that one weighted draw. Fired off the
-- command bar, and cleared by the pull that uses it, so it's worth exactly one ingredient.
function IngredientRollingManager:ForceNextIngredient(player: Player, ingredientId: string)
	self._forcedIngredients[player] = ingredientId
end

-- Makes the next pull tease without waiting on its chance, and is worth exactly one pull. Fired off the
-- command bar: the chance tops out at a few percent and fades as the player earns, so there's no reaching
-- one on demand by pulling the lever. What it can't do is conjure a pool -- a player past the early game
-- or rich enough to afford everything cool still teases nothing, and the arming is spent either way.
function IngredientRollingManager:ForceNextTeaser(player: Player)
	self._forcedTeasers[player] = true
end

-- Sets one of a player's pity counters. Fired off the command bar: the rarest rung is thousands of rolls
-- out, so there's no reaching it by pulling the lever.
function IngredientRollingManager:SetPlayerPityCount(player: Player, tierId: string, count: number)
	PlayerDataManager:SetPlayerDataKey(player, { "Pity", tierId }, count)
end

-- Claims one stand's pending roll: gates on the roll timing, charges, grants. Returns true only on an
-- actual grant, so the client can gate clearing the stand on a server-verified purchase.
-- @param skipCurrencyCost Grant without charging, for one already paid for in Robux. Everything else --
-- the roll check, the time gate, the grant, the stat, the emptying -- is wanted on both paths.
function IngredientRollingManager:PurchaseIngredientFromStand(
	player: Player,
	standId: string,
	skipCurrencyCost: boolean?
): (boolean, boolean?)
	if not validatePlayer(player) then
		return false
	end

	-- The reads below yield, so without this two purchases landing together could both pass the
	-- affordability check before either deducts. A currency buy that loses the race is dropped; a Robux
	-- one has already been charged, so it waits its turn.
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

	-- Claimable only once the animation window has passed, measured at the speed the pull was *made* at
	-- rather than the player's speed now, so it matches what every client is animating. A roll saved
	-- before RollSpeed existed carries no level, which reads as the slowest rung.
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

	-- A roll outlives its session, so data can name an ingredient the config no longer has. Cleared rather
	-- than left as a stand that can never be bought from.
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

			-- Said before the dialog goes up: the prompt names the band's product rather than what it was
			-- raised over, so without this the player gets a Robux price with nothing telling them why.
			NotificationManager:NotifyNormal(player, {
				Text = `You can't afford {ingredient.Name}`,
				Duration = 3,
				Sound = "Reject",
				Effect = "Error",
			})

			-- The roll stays on the stand and the player is offered its price band for Robux. Which stand
			-- is remembered here rather than carried on the product: a band is shared by every ingredient
			-- costing about the same, and its receipt names only the buyer.
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

	-- The claim is spent, so the stand empties until the next pull and stays empty across a rejoin.
	-- Clearing the attribute is what empties it on every client, the buyer's included.
	PlayerDataManager:SetPlayerDataKey(player, { "PendingRolls", standId }, nil)
	self:WritePendingRollsToBase(player, data.PendingRolls)
	self._purchasing[player] = nil
	return true, discovered
end

-- Grants an ingredient once a band product clears (fired by ShopManager). Goes to the stand the prompt was
-- raised from, but only while it still holds what it held then -- so a pull landing during the open dialog
-- can't sell a Salmon at a Corn's price.
--
-- An unanswered receipt is re-processed on a later join with no pending stand to read. That falls back to
-- the dearest roll the band covers, and past that to the dearest ingredient the band sells outright,
-- rather than dropping a purchase already paid for.
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

	-- Nothing on the stands the band reaches, so pay out its dearest ingredient -- which is exactly what
	-- the product says it buys, and they've been charged either way.
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
	-- The client waits out the roll this stamps before re-arming its lever. What each stand landed on
	-- rides the stand attributes instead, so it reaches visitors too.
	self.RequestRollFunction:OnInvoke(function(player: Player)
		return self:RollIngredientsForPlayer(player)
	end)

	-- Emptying the stand is the attribute's job, since that reaches every client. This reply only tells
	-- the buyer whether the ingredient was new, so their purchase sound doesn't land on a discovery toast.
	self.PurchaseIngredientEvent:OnServerEvent(function(player: Player, standId: string)
		local success, discovered = self:PurchaseIngredientFromStand(player, standId)
		self.OnPurchasedEvent:FireClient(player, success, standId, discovered)
	end)

	-- The base rebuilds its stands on assignment, so last session's rolls have to be stamped back on.
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:RestorePendingRollsToBase(player)
	end)

	-- BaseManager's own load sweep can hand someone a base before the connect above exists. Spawned
	-- because the read yields, and harmless to double up on -- a player with no BaseId yet just bails.
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
