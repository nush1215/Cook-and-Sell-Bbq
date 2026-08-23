-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Ingredients = require(Shared.Config.Ingredients)
local BaseUnlocks = require(Shared.Config.BaseUnlocks)
local CookSpeed = require(Shared.Config.CookSpeed)
local CookStates = require(Shared.Config.CookStates)

--
local PlayerDataManager
local NotificationManager
local CurrencyManager
local BaseManager
local StickManager
local StatsManager
local ShopManager

--
local STICK_TOOL_TAG = "StickTool"

-- The most of a player's ping we'll take off their stop, in seconds. Their ping is dead time between
-- pressing the prompt and us hearing it, so taking it off is what makes the state they saw the state
-- they get -- and the cap is what stops a dropped connection from rewinding the bar by seconds.
local MAX_STOP_COMPENSATION = 0.25

-- What a bought skip settles a cook as, and the product that buys one. Perfect is what the bar is aimed
-- at rather than a bonus over it -- every ingredient price is tuned against it -- so what the product
-- sells is the timing risk going away, not a state the player couldn't have hit themselves.
local SKIP_COOK_STATE = "Perfect"
local SKIP_COOK_PRODUCT = "SkipCook"

--[[
    Drives placing a filled skewer onto a griller, cooking it, and taking it back off.

    A cook is a timing minigame rather than a countdown: the player lights the stove and decides when
    to turn it back off, and nothing else ever ends it. Where they stopped is what they get (see the
    CookStates config). Stop early and the skewer comes off raw, still re-cookable; stop in the window
    and it's perfect; overshoot and it's still a fine skewer, just worth a little less. Only past the
    end of the bar does it start costing them -- from there it burns on a wall clock, which docks what
    it sells for and follows it around as a tint.

    Player data is the source of truth: data.Grillers[slotId] = { StickId, Ingredients, Cooked?,
    CookState? } holds the skewer on each griller. While it cooks the record also carries Cooking =
    true, CookStartedAt = workspace:GetServerTimeNow() and CookTime = the whole bar in seconds. Nothing
    is scheduled off those: a cook nobody stops just keeps running, across a rejoin included, and the
    elapsed time on the stop is what settles it -- a skewer left overnight comes off charred, once its
    owner walks up and turns the stove off. The stamp is the synced clock rather than os.time() because
    os.time() only resolves to whole seconds, which on a window this tight is most of it. Only a stick
    with ingredients (a FilledStickTool) can go on. The griller is a Ghost unlock -- a static model the
    server never moves -- so the static skewer model is cloned in server-side (seen by everyone), like
    SauceDispenserManager.

    Each grill also carries its own CookSpeed upgrade (data.GrillerCookSpeed[slotId] = level), bought
    off the sign on the grill and folded into the cook time stamped at the start of a cook.

    The cook animation and the stove visuals are NOT rendered here: the server just mirrors the record
    onto the slot's replicated attributes (PlacedStickId / Cooking / Cooked / CookStartedAt / CookTime /
    CookIngredients), and every client's GrillerController spins the skewer, browns its ingredients,
    draws the cooking bar and lights the stove off those, so the motion is smooth and local instead of
    replicated per frame. The bands the bar reads are fixed fractions in the config, so none of them
    have to be replicated.
]]

--
local GrillerManager = {
	ToggleGrillEvent = Network.Event("ToggleGrillStick"),
	StartCookEvent = Network.Event("StartCooking"),
	StopCookEvent = Network.Event("StopCooking"),
	PurchaseCookSpeedUpgradeEvent = Network.Event("PurchaseCookSpeedUpgrade"),
	RequestCookSpeedProductEvent = Network.Event("RequestCookSpeedProduct"),
	RequestSkipCookEvent = Network.Event("RequestSkipCook"),

	-- (player, cookStateId, elapsed, cookSpeedLevel, method) when a cook is stopped and settled. elapsed is
	-- how long it sat on the heat in seconds. method is "Timed" or "Skipped" -- a skipped cook's elapsed is
	-- however long it happened to be on when it was bought out, which says nothing about the cook, so the
	-- two can't be read as one population.
	OnCookCompleted = Signal.new(),
	-- (player, slotId, newLevel, cost, method) when a grill's cook speed is bought up a level. method is
	-- "Currency" or "Robux"; cost is the Bux paid, 0 on a Robux buy.
	OnCookSpeedUpgraded = Signal.new(),

	_grills = {}, -- [player] = { [slotId] = Model }, the skewers we've cloned onto the grills
	_listeners = {}, -- [player] = { the Grillers and GrillerCookSpeed data listeners }
	_toggling = {}, -- [player] = true across the read -> write window, so a spammed prompt can't double up
	_starting = {}, -- [player] = true across StartCooking's read -> write window
	_stopping = {}, -- [player] = true across StopCooking's read -> write window
	_upgrading = {}, -- [player] = true across PurchaseGrillCookSpeedUpgrade's CanAfford -> deduct window
	_pendingCookSpeedSlot = {}, -- [player] = the slot their open cook-speed Robux prompt was raised from
	_pendingSkipCookSlot = {}, -- [player] = the slot their open skip-cook Robux prompt was raised from
	_cookWindowStretch = {}, -- [player] = how many times longer their perfect window runs, stamped per cook
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Whether the player currently has a bare (ingredient-less) stick equipped. A bare stick can't be
-- grilled, so this only tells the rejection which advice to give -- point them at adding ingredients.
local function isHoldingBareStick(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end

	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:HasTag(STICK_TOOL_TAG) then
			return true
		end
	end

	return false
end

-- Whether the player may act on this griller slot at all. Ordinary slots are the ones they've levelled
-- the Griller unlock up to; the Golden Grill is a gamepass slot, which sits past the group's Limit so
-- the level can never reach it and its pass's tag is what owns it instead. `level` is the caller's
-- already-read data.Unlocks.Griller, since every caller has read their data to act on the slot anyway.
-- @param slotNumber The slot, straight off a remote, so it can be anything
function GrillerManager:IsGrillSlotUnlocked(player: Player, slotNumber: number?, level: number): boolean
	if not slotNumber or slotNumber < 1 then
		return false
	end

	local gamepassSlot = BaseUnlocks.GetGamepassSlot("Griller", slotNumber)
	if gamepassSlot then
		return player:HasTag(gamepassSlot.Gamepass)
	end

	return slotNumber <= level
end

-- Mirrors a griller's record onto the slot's replicated attributes. The client reads these to drive
-- both its owner prompt/knob and the cook animation it renders (spin, raw -> cooked colour, stove), so
-- CookStartedAt / CookTime let it play out deterministically and CookIngredients tells it what each
-- part cooks toward. CookWindowStretch goes with them for the same reason: it bends the bar, so a client
-- that didn't have it would draw a different cook to the one the stop resolves against. CookSpeedLevel is
-- what the slot's upgrade sign shows. CookProgress rides along for the same reason CookWindowStretch does
-- -- a resumed cook starts part-way up the bar, and a client without it would draw one starting at zero.
-- A nil record clears the slot.
function GrillerManager:_writeSlotAttributes(slot: Instance, record, cookSpeedLevel: number)
	slot:SetAttribute("CookSpeedLevel", cookSpeedLevel)
	slot:SetAttribute("PlacedStickId", if record then record.StickId else nil)
	slot:SetAttribute("Cooking", if record and record.Cooking then true else nil)
	slot:SetAttribute("Cooked", if record then record.Cooked or nil else nil)
	slot:SetAttribute("CookStartedAt", if record then record.CookStartedAt else nil)
	slot:SetAttribute("CookTime", if record then record.CookTime else nil)
	slot:SetAttribute("CookWindowStretch", if record then record.CookWindowStretch else nil)
	slot:SetAttribute("CookProgress", if record then record.CookProgress else nil)
	slot:SetAttribute("CookIngredients", if record then table.concat(record.Ingredients, ",") else nil)
end

-- Brings the models on the player's grillers in line with their records: the right skewer sits on each
-- occupied slot's StickAttachment, and the slot's attributes mirror the state for the client's prompt
-- and its cook animation.
function GrillerManager:_renderGrills(player: Player)
	local baseId = player:GetAttribute("BaseId")
	if not baseId then
		return
	end

	local baseModel = workspace.Base:FindFirstChild(baseId)
	if not baseModel then
		return
	end

	local interactables = baseModel:FindFirstChild("Interactables")
	local grillFolder = interactables and interactables:FindFirstChild("Grillers")
	if not grillFolder then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local grills = self._grills[player]
	if not grills then
		grills = {}
		self._grills[player] = grills
	end

	for _, slot in grillFolder:GetChildren() do
		-- Anything in the folder that isn't a numbered griller isn't ours to drive.
		if not tonumber(slot.Name) then
			continue
		end

		local slotId = slot.Name
		local record = data.Grillers[slotId]
		local cooking = record ~= nil and record.Cooking == true
		local cookSpeedLevel = data.GrillerCookSpeed[slotId] or 0

		local existing = grills[slotId]

		-- A cook in progress writes to Grillers only at its start and finish, but interacting with another
		-- slot re-renders this one too. Leave a still-cooking skewer's (raw) model in place -- the client
		-- spins and browns it off the attributes, so a needless rebuild would pop its colours back to raw.
		-- The model carries the cook it belongs to, so a genuinely new cook still rebuilds.
		if existing and cooking and existing:GetAttribute("CookStartedAt") == record.CookStartedAt then
			self:_writeSlotAttributes(slot, record, cookSpeedLevel)
			continue
		end

		-- Grillers change rarely (outside cooking), so just rebuild rather than diff.
		if existing then
			existing:Destroy()
			grills[slotId] = nil
		end

		if record then
			local model = StickManager:BuildPlacedStickModel(record)
			local attachment = slot:FindFirstChild("StickAttachment")

			-- The slot's parts live in the place file, so a missing attachment is a real failure case.
			if model and attachment then
				-- A fixed name and the cook stamp are the client's handle on the skewer: it finds it by
				-- name and only animates it while this cook is the one running.
				model.Name = "Skewer"
				model:SetAttribute("CookStartedAt", if cooking then record.CookStartedAt else nil)
				model:PivotTo(attachment.WorldCFrame)
				model.Parent = slot
				grills[slotId] = model
			elseif model then
				warn(`[Griller] {baseId} slot {slotId} has no StickAttachment, its skewer won't render`)
				model:Destroy()
			end
		end

		self:_writeSlotAttributes(slot, record, cookSpeedLevel)
	end
end

-- Puts the player's equipped filled skewer on an empty grill, or takes the finished one back off. A
-- skewer that's mid-cook is locked on. The Grillers write re-renders through the listener.
function GrillerManager:ToggleGrillStick(player: Player, slotId: string)
	if not validatePlayer(player) then
		return
	end

	if self._toggling[player] then
		return
	end
	self._toggling[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._toggling[player] = nil
		return
	end

	-- The id comes off a remote, so only act on a real, unlocked griller.
	local slotNumber = tonumber(slotId)
	if not self:IsGrillSlotUnlocked(player, slotNumber, data.Unlocks.Griller or 0) then
		self._toggling[player] = nil
		return
	end

	local record = data.Grillers[slotId]

	if record then
		-- Mid-cook skewers are committed until the timer's done.
		if record.Cooking then
			self._toggling[player] = nil
			return
		end

		-- Occupied: hand the skewer back as a distinct filled tool (carrying however its cook went, and
		-- whatever a pull off the raw band banked on it) and clear the grill.
		StickManager:AddFilledStick(player, {
			StickId = record.StickId,
			Ingredients = table.clone(record.Ingredients),
			Cooked = record.Cooked,
			CookState = record.CookState,
			CookProgress = record.CookProgress,
			Mutation = record.Mutation,
		})
		PlayerDataManager:SetPlayerDataKey(player, { "Grillers", slotId }, nil)
	else
		-- Empty: only a skewer can go on -- a bare stick has nothing to cook.
		local filled = StickManager:GetEquippedFilledStick(player, data)
		if not filled then
			-- A bare stick has a clear next step -- get ingredients on it -- so say that instead of the
			-- generic advice an empty-handed player gets.
			NotificationManager:NotifyNormal(player, {
				Text = if isHoldingBareStick(player)
					then "Add ingredients to your stick first!"
					else "You need a BBQ to grill!",
				Duration = 3,
				Sound = "Reject",
				Effect = "Error",
			})
			self._toggling[player] = nil
			return
		end

		-- A cooked skewer is done -- it can't go back on to cook again.
		if filled.Cooked then
			NotificationManager:NotifyNormal(player, {
				Text = "This BBQ's already cooked!",
				Duration = 3,
				Sound = "Reject",
				Effect = "Error",
			})
			self._toggling[player] = nil
			return
		end

		PlayerDataManager:SetPlayerDataKey(player, { "Grillers", slotId }, {
			StickId = filled.StickId,
			Ingredients = table.clone(filled.Ingredients),
			Cooked = filled.Cooked,
			CookState = filled.CookState,
			CookProgress = filled.CookProgress,
			Mutation = filled.Mutation,
		})
		-- The skewer moves from the inventory onto the grill.
		PlayerDataManager:SetPlayerDataKey(player, { "FilledSticks", filled.Uid }, nil)
	end

	self._toggling[player] = nil
end

-- Lights the stove under an eligible skewer: works out how long the whole bar takes from its
-- ingredients and stamps the record, so the cook survives a rejoin. Nothing is scheduled off the stamp
-- -- only the player's own stop ever ends a cook.
function GrillerManager:StartCooking(player: Player, slotId: string)
	if not validatePlayer(player) then
		return
	end

	if self._starting[player] then
		return
	end
	self._starting[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._starting[player] = nil
		return
	end

	local slotNumber = tonumber(slotId)
	if not self:IsGrillSlotUnlocked(player, slotNumber, data.Unlocks.Griller or 0) then
		self._starting[player] = nil
		return
	end

	-- Only a raw skewer that's sitting there and not already cooking can be lit.
	local record = data.Grillers[slotId]
	if not record or record.Cooking or record.Cooked then
		self._starting[player] = nil
		return
	end

	-- What's stamped is the whole bar, not the wait until the skewer is done: dividing by RAW_END is what
	-- puts the raw -> cooked boundary on exactly the second an ingredient's CookTime says it should, with
	-- the rest of the bar being the window and the run past it. This grill's CookSpeed upgrade is the only
	-- thing that shortens it, and it's baked in here, so the client's bar and browning follow it for free.
	-- The burn past the end of the bar isn't scaled by any of this -- it's wall-clock seconds in the config,
	-- so every skewer gives the same window to notice.
	local cookSpeedLevel = data.GrillerCookSpeed[slotId] or 0
	local cookTime = Ingredients.GetTotalCookTime(record.Ingredients)
		/ CookStates.RAW_END
		/ CookSpeed.GetMultiplier(cookSpeedLevel)
	if cookTime <= 0 then
		self._starting[player] = nil
		return
	end

	-- Stamped onto the cook rather than read at the stop, the same as CookTime: the run has to bend the
	-- same way from the first frame to the last, so a player whose stretch is lifted mid-cook (finishing
	-- their tutorial) keeps the bar they lit, and a rejoin picks up the one they left.
	--
	-- CookProgress carries straight over: it's a fraction of the bar rather than seconds off it, so a
	-- skewer banked on a slow grill resumes at the same point on a fast one and just takes less real time
	-- to finish from there. CookStartedAt stays honest about when the stove was lit -- the offset is added
	-- in when the bar is read, not hidden in the stamp, so the stove and spin still ramp from a standstill.
	PlayerDataManager:SetPlayerDataKey(player, { "Grillers", slotId }, {
		StickId = record.StickId,
		Ingredients = table.clone(record.Ingredients),
		Cooking = true,
		CookStartedAt = workspace:GetServerTimeNow(),
		CookTime = cookTime,
		CookWindowStretch = self._cookWindowStretch[player],
		CookProgress = record.CookProgress,
		-- Mutation is deliberately absent: StopCooking stamps it off the *slot*, so what comes off a
		-- grill is always what that grill hands out. A record reaching here can't be carrying one
		-- anyway -- a mutated skewer is cooked, and a cooked one was refused above.
	})

	self._starting[player] = nil
end

-- Sets how many times longer this player's perfect window runs, from their next cook on. The bar is
-- otherwise unchanged -- the run up to the window and the burn past it keep their timings, so what a
-- stretch buys is reaction room and nothing else. Nil or 1 puts them back on the normal bar.
--
-- Set for a player being taught the timing rather than tested on it: the window is a quarter of the bar,
-- which on the cheapest ingredient is around two seconds.
function GrillerManager:SetCookWindowStretch(player: Player, stretch: number?)
	self._cookWindowStretch[player] = if stretch and stretch > 1 then stretch else nil
end

-- Buys the next CookSpeed level on one of the player's grills, which cooks everything placed on it
-- that much faster from the next cook on. Each grill carries its own level and its own prices, so a
-- later grill costs more to speed up than the first.
-- @param skipCurrencyCost Grant the level without charging for it, for one already paid for in Robux
-- (see the cook-speed products in Config/Products). Everything else -- the unlocked and max checks, the
-- data write, the signal and the notification -- is wanted on both paths, so only the charge differs.
function GrillerManager:PurchaseGrillCookSpeedUpgrade(player: Player, slotId: string, skipCurrencyCost: boolean?)
	if not validatePlayer(player) then
		return
	end

	-- The reads below yield, so without this guard two purchases landing together could both read the
	-- same level and write the same next one. A currency buy that loses the race is simply not made; a
	-- Robux one has already been charged, so it waits its turn rather than being dropped on the floor.
	if self._upgrading[player] then
		if not skipCurrencyCost then
			return
		end

		-- Leaving is checked as well as the guard clearing, so a guard stranded by an error can't hold
		-- this thread spinning past the session it belongs to.
		repeat
			task.wait()
		until not self._upgrading[player] or not player:IsDescendantOf(Players)

		if not player:IsDescendantOf(Players) then
			return
		end
	end
	self._upgrading[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._upgrading[player] = nil
		return
	end

	-- The id comes off a remote, so only act on a real, unlocked griller.
	local slotNumber = tonumber(slotId)
	if not self:IsGrillSlotUnlocked(player, slotNumber, data.Unlocks.Griller or 0) then
		self._upgrading[player] = nil
		return
	end

	local currentLevel = data.GrillerCookSpeed[slotId] or 0
	local cost = CookSpeed.GetCost(slotNumber, currentLevel + 1)
	if currentLevel >= CookSpeed.MAX_LEVEL or not cost then
		self._upgrading[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = "That grill's already at max cook speed!",
			Duration = 3,
			Sound = "Reject",
		})
		return
	end

	if not skipCurrencyCost then
		local canAfford = CurrencyManager:CanAfford(player, cost)
		if not canAfford then
			self._upgrading[player] = nil
			NotificationManager:NotifyNormal(player, {
				Text = "You can't afford this upgrade!",
				Effect = "Error",
				Duration = 3,
				Sound = "Reject",
			})
			return
		end

		CurrencyManager:DeductCurrency(player, cost, "CookSpeedUpgrade")
	end

	PlayerDataManager:SetPlayerDataKey(player, { "GrillerCookSpeed", slotId }, currentLevel + 1)
	self.OnCookSpeedUpgraded:Fire(
		player,
		slotId,
		currentLevel + 1,
		if skipCurrencyCost then 0 else cost,
		if skipCurrencyCost then "Robux" else "Currency"
	)

	self._upgrading[player] = nil

	-- A grill already cooks at 1.0x before its first level, so every purchase here is an upgrade.
	NotificationManager:NotifyNormal(player, {
		Text = `Griller {slotNumber} Cook Speed Upgraded!`,
		Duration = 3,
		Sound = "Upgrade",
		Effect = "Success",
	})
end

-- Raises the Robux prompt for the next cook-speed level on one of the player's grills. Which grill it
-- was is remembered here rather than carried on the product, since a product is a price band shared by
-- several levels across every grill and its receipt arrives with nothing but the buyer on it.
function GrillerManager:PromptCookSpeedUpgradeProduct(player: Player, slotId: string)
	if not validatePlayer(player) then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- The id comes off a remote, so only act on a real, unlocked griller.
	local slotNumber = tonumber(slotId)
	if not self:IsGrillSlotUnlocked(player, slotNumber, data.Unlocks.Griller or 0) then
		return
	end

	local currentLevel = data.GrillerCookSpeed[slotId] or 0
	local productStringId = CookSpeed.GetProductStringIdForLevel(slotNumber, currentLevel + 1)
	if currentLevel >= CookSpeed.MAX_LEVEL or not productStringId then
		NotificationManager:NotifyNormal(player, {
			Text = "That grill's already at max cook speed!",
			Duration = 3,
			Sound = "Reject",
		})
		return
	end

	self._pendingCookSpeedSlot[player] = slotId
	ShopManager:AttemptProductPurchase(player, productStringId)
end

-- Grants a cook-speed level once one of the band products clears (fired by ShopManager from the
-- product's callback). It goes to the grill the prompt was raised from, which is why every band can
-- share one handler.
--
-- A receipt Roblox never got an answer for is re-processed on a later join, where nothing raised a
-- prompt and there's no pending slot to read -- so that case falls back to whichever grill is furthest
-- behind rather than dropping a purchase the player has already been charged for.
function GrillerManager:GrantCookSpeedUpgradeFromProduct(player: Player)
	local slotId = self._pendingCookSpeedSlot[player]
	self._pendingCookSpeedSlot[player] = nil

	if not slotId then
		local hasData, data = PlayerDataManager:GetPlayerData(player):await()
		if not hasData then
			return
		end

		-- Slots are walked through IsGrillSlotUnlocked rather than off the Griller level alone, so a maxed
		-- out ladder can't hide a Golden Grill that still has levels left in it -- that slot is authored
		-- past the ladder and is owned by holding the pass instead.
		local griller = BaseUnlocks.GetUnlockFromId("Griller")
		local highestSlot = griller.Limit
		for slotNumber in griller.GamepassSlots or {} do
			highestSlot = math.max(highestSlot, slotNumber)
		end

		local lowestLevel = nil
		for slotNumber = 1, highestSlot do
			local level = data.GrillerCookSpeed[tostring(slotNumber)] or 0
			local eligible = level < CookSpeed.MAX_LEVEL
				and (not lowestLevel or level < lowestLevel)
				and self:IsGrillSlotUnlocked(player, slotNumber, data.Unlocks.Griller or 0)

			if eligible then
				slotId, lowestLevel = tostring(slotNumber), level
			end
		end

		if not slotId then
			return
		end
	end

	self:PurchaseGrillCookSpeedUpgrade(player, slotId, true)
end

-- Raises the Robux prompt for skipping the cook running on one of the player's grills. Which grill it
-- was is remembered here rather than carried on the product, for the same reason a cook-speed band is:
-- the receipt arrives with nothing on it but the buyer.
function GrillerManager:PromptSkipCookProduct(player: Player, slotId: string)
	if not validatePlayer(player) then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- The id comes off a remote, so only act on a real, unlocked griller.
	local slotNumber = tonumber(slotId)
	if not self:IsGrillSlotUnlocked(player, slotNumber, data.Unlocks.Griller or 0) then
		return
	end

	-- There's nothing to buy your way out of on a grill that isn't cooking. The client only puts the
	-- prompt up through a cook, so this is the remote being held to that rather than a case a player can
	-- walk into.
	local record = data.Grillers[slotId]
	if not record or not record.Cooking then
		NotificationManager:NotifyNormal(player, {
			Text = "Nothing's cooking on that grill",
			Duration = 3,
			Sound = "Reject",
		})
		return
	end

	self._pendingSkipCookSlot[player] = slotId
	ShopManager:AttemptProductPurchase(player, SKIP_COOK_PRODUCT)
end

-- Finishes a cook the player bought their way out of, settling it perfect wherever the bar had actually
-- got to (fired by ShopManager from the product's callback). It goes to the grill the prompt was raised
-- from, the same as a cook-speed band.
--
-- A receipt Roblox never got an answer for is re-processed on a later join, where nothing raised a prompt
-- and there's no pending slot to read -- so that case falls back to whatever the player has on a grill
-- rather than dropping a purchase they've already been charged for. A cook nobody stops keeps running
-- across a rejoin, so the one they bought this for is usually still sitting there on the heat waiting.
function GrillerManager:GrantSkipCookFromProduct(player: Player)
	local slotId = self._pendingSkipCookSlot[player]
	self._pendingSkipCookSlot[player] = nil

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- The pending slot is read back rather than trusted: raising the prompt and answering it are minutes
	-- apart at worst, and the cook it was raised from can be stopped by hand in between.
	local record = if slotId then data.Grillers[slotId] else nil
	if record and record.Cooked then
		record = nil
	end

	if not record then
		-- Slots are walked through IsGrillSlotUnlocked rather than off the Griller level alone, so a maxed
		-- out ladder can't hide a Golden Grill -- that slot is authored past the ladder and is owned by
		-- holding the pass instead.
		local griller = BaseUnlocks.GetUnlockFromId("Griller")
		local highestSlot = griller.Limit
		for slotNumber in griller.GamepassSlots or {} do
			highestSlot = math.max(highestSlot, slotNumber)
		end

		slotId = nil

		for slotNumber = 1, highestSlot do
			local candidateId = tostring(slotNumber)
			local candidate = data.Grillers[candidateId]
			if
				not candidate
				or candidate.Cooked
				or not self:IsGrillSlotUnlocked(player, slotNumber, data.Unlocks.Griller or 0)
			then
				continue
			end

			-- A running cook is what they were buying out of, so it takes it outright. A BBQ sitting there
			-- unlit is only worth falling back to if nothing at all is on the heat.
			if candidate.Cooking then
				slotId, record = candidateId, candidate
				break
			end

			if not record then
				slotId, record = candidateId, candidate
			end
		end

		if not record then
			warn(`[Griller] {player.Name} bought a cook skip with nothing on a grill to spend it on`)
			return
		end
	end

	-- What this grill stamps on whatever comes off it -- the Golden Grill's mutation, and nothing at all on
	-- an ordinary slot. Read off the slot rather than the record for the same reason StopCooking reads it
	-- there: what comes off a grill is always what that grill hands out.
	local gamepassSlot = BaseUnlocks.GetGamepassSlot("Griller", tonumber(slotId))

	PlayerDataManager:SetPlayerDataKey(player, { "Grillers", slotId }, {
		StickId = record.StickId,
		Ingredients = table.clone(record.Ingredients),
		Cooked = true,
		CookState = SKIP_COOK_STATE,
		-- Cleared rather than carried across: the skip takes the cook past the raw band, and clearing that
		-- band is what consumes a bank, exactly as a stop past it does.
		CookProgress = nil,
		Mutation = gamepassSlot and gamepassSlot.Mutation,
	})

	-- Counted like any other cook, so SkewersCooked still comes to the sum of CookStateCounts. The elapsed
	-- reported is the real seconds it did spend on the heat before being bought out -- none at all on a BBQ
	-- that was never lit -- and the method is what says not to read it as a cook that was timed.
	StatsManager:RecordCookCompleted(player, SKIP_COOK_STATE)
	self.OnCookCompleted:Fire(
		player,
		SKIP_COOK_STATE,
		if record.CookStartedAt then workspace:GetServerTimeNow() - record.CookStartedAt else 0,
		data.GrillerCookSpeed[slotId] or 0,
		"Skipped"
	)

	-- The same toast a cook that landed in the window by hand gets, off the same state: what the player
	-- bought is that result, so it should read as that result.
	local notification = CookStates.GetStateFromId(SKIP_COOK_STATE).Notification
	if notification then
		NotificationManager:NotifyNormal(player, {
			Text = notification.Text,
			Duration = 3,
			Sound = notification.Sound,
			Effect = notification.Effect,
		})
	end
end

-- Pulls a griller's skewer off the heat and settles it at wherever the cook had got to: raw below the
-- window (so it stays re-cookable), perfect inside it, merely cooked through the rest of the bar, and
-- overcooked then charred for however long past the end of it nobody came back.
function GrillerManager:StopCooking(player: Player, slotId: string)
	if not validatePlayer(player) then
		return
	end

	-- Read before anything that can yield: this timestamp is the whole minigame. Their ping is dead time
	-- between pressing the prompt and us hearing it, so taking it off is what makes the state they saw
	-- the state they get.
	local stoppedAt = workspace:GetServerTimeNow() - math.min(player:GetNetworkPing(), MAX_STOP_COMPENSATION)

	if self._stopping[player] then
		return
	end
	self._stopping[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._stopping[player] = nil
		return
	end

	-- Nothing else needs checking -- a locked or made-up slot has no record, let alone one that's cooking.
	local record = data.Grillers[slotId]
	if not record or not record.Cooking then
		self._stopping[player] = nil
		return
	end

	-- Warped after the ping compensation above, not before: that correction is in real seconds off a real
	-- clock, and it's the corrected moment that has to be read against the bar the player was watching.
	-- CookProgress goes in with it, so a resumed cook is read against the whole bar it's been through
	-- rather than only this leg of it.
	local elapsed = CookStates.GetBarElapsed(
		stoppedAt - record.CookStartedAt,
		record.CookTime,
		record.CookWindowStretch,
		record.CookProgress
	)

	local state = CookStates.GetStateFromCook(elapsed, record.CookTime)
	local raw = state == "Raw"

	-- What this grill stamps on whatever comes off it -- the Golden Grill's mutation, and nothing at all
	-- on an ordinary slot. Read off the slot rather than carried on the record, so a skewer is only ever
	-- mutated by the grill it was actually cooked on. Nothing verifies the pass again here: placing and
	-- lighting both gated on it, so a record can't be cooking on this slot without it.
	local gamepassSlot = BaseUnlocks.GetGamepassSlot("Griller", tonumber(slotId))

	PlayerDataManager:SetPlayerDataKey(player, { "Grillers", slotId }, {
		StickId = record.StickId,
		Ingredients = table.clone(record.Ingredients),
		-- Cooked stays the plain "has been through a grill" flag the sauce dispenser gates on, and
		-- CookState says how that went. A skewer pulled off raw carries neither, so it's
		-- indistinguishable from one that was never lit -- still takeable, still re-cookable, and
		-- still sellable, just for almost nothing (StickModel.GetCookStateId reads the pair back).
		Cooked = if raw then nil else true,
		CookState = if raw then nil else state,
		-- Except for how far it got. Nothing about a raw pull is ever worth doing on purpose -- a raw
		-- skewer barely clears what its ingredients cost -- so throwing the cook away only ever punishes
		-- a mistake or an interruption. Banked as a fraction of the bar rather than seconds off it, so it
		-- means the same thing on a grill with a different CookSpeed. Being raw is what bounds it under
		-- RAW_END, and any cook that got past that band consumes the bank by clearing it.
		CookProgress = if raw then elapsed / record.CookTime else nil,
		-- On the same rule as CookState: a pull off the raw band isn't a cook, so it banks its progress
		-- and nothing else. Finish it on this grill and it comes off mutated; finish it on an ordinary
		-- one and it doesn't, which is the honest reading of where it was actually cooked.
		Mutation = if raw then nil else gamepassSlot and gamepassSlot.Mutation,
	})

	self._stopping[player] = nil

	-- Every stop counts, a raw pull included -- the raw ones are the interesting half of a cook-quality
	-- tally rather than a non-event, so SkewersCooked always comes to the sum of CookStateCounts.
	--
	-- The elapsed reported is this stint on the heat and not the bar it landed on: real, unwarped seconds
	-- off a real clock, so a cook resumed from an earlier pull reports the leg that was actually run rather
	-- than counting the banked part twice across two stops.
	StatsManager:RecordCookCompleted(player, state)
	self.OnCookCompleted:Fire(
		player,
		state,
		stoppedAt - record.CookStartedAt,
		data.GrillerCookSpeed[slotId] or 0,
		"Timed"
	)

	-- The verdict on the cook, written next to the state it belongs to rather than spelled out here. Every
	-- state carries one now, a raw pull included: what it's there to say is that the cook was banked and
	-- not lost, which is the one thing about a stop the bar can't show on its way down. Slots landing
	-- together share their text, so they collapse into one toast with a counter rather than stacking.
	local notification = CookStates.GetStateFromId(state).Notification
	if notification then
		NotificationManager:NotifyNormal(player, {
			Text = notification.Text,
			Duration = 3,
			Sound = notification.Sound,
			Effect = notification.Effect,
		})
	end
end

-- Registers the player's data listeners and does the first render. Guarded so the base-assigned signal
-- and the OnStart sweep can't set the same player up twice.
function GrillerManager:_setupPlayer(player: Player)
	if self._listeners[player] then
		return
	end

	-- A CookSpeed purchase changes nothing about the models, but the level is mirrored onto the slot
	-- for its upgrade sign, so it re-renders on the same path.
	self._listeners[player] = {
		PlayerDataManager:ListenForChanges(player, "Grillers", function()
			self:_renderGrills(player)
		end),
		PlayerDataManager:ListenForChanges(player, "GrillerCookSpeed", function()
			self:_renderGrills(player)
		end),
	}

	-- A cook the player left running is picked straight back up: the record still carries its stamps, so
	-- it renders mid-cook and keeps burning until they turn the stove off themselves.
	self:_renderGrills(player)
end

-- Drops the player's listeners and the models we cloned onto their grills.
function GrillerManager:_cleanupPlayer(player: Player)
	local listeners = self._listeners[player]
	if listeners then
		for _, listener in listeners do
			listener:Disconnect()
		end
		self._listeners[player] = nil
	end

	local grills = self._grills[player]
	if grills then
		for _, model in grills do
			model:Destroy()
		end
		self._grills[player] = nil
	end

	self._toggling[player] = nil
	self._starting[player] = nil
	self._stopping[player] = nil
	self._upgrading[player] = nil
	self._pendingCookSpeedSlot[player] = nil
	self._pendingSkipCookSlot[player] = nil
	self._cookWindowStretch[player] = nil
end

function GrillerManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	NotificationManager = require(script.Parent.NotificationManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	BaseManager = require(script.Parent.BaseManager)
	StickManager = require(script.Parent.StickManager)
	StatsManager = require(script.Parent.StatsManager)
	ShopManager = require(script.Parent.ShopManager)
end

function GrillerManager:OnStart()
	-- The base is what says which grillers exist and where their attachments are, so set a player up
	-- only once it's been assigned one.
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:_setupPlayer(player)
	end)

	-- A player assigned a base before this manager started won't fire the signal above, so sweep them.
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("BaseId") then
			task.spawn(function()
				self:_setupPlayer(player)
			end)
		end
	end

	self.ToggleGrillEvent:OnServerEvent(function(player: Player, slotId: string)
		self:ToggleGrillStick(player, slotId)
	end)

	self.StartCookEvent:OnServerEvent(function(player: Player, slotId: string)
		self:StartCooking(player, slotId)
	end)

	self.StopCookEvent:OnServerEvent(function(player: Player, slotId: string)
		self:StopCooking(player, slotId)
	end)

	self.PurchaseCookSpeedUpgradeEvent:OnServerEvent(function(player: Player, slotId: string)
		self:PurchaseGrillCookSpeedUpgrade(player, slotId)
	end)

	self.RequestCookSpeedProductEvent:OnServerEvent(function(player: Player, slotId: string)
		self:PromptCookSpeedUpgradeProduct(player, slotId)
	end)

	self.RequestSkipCookEvent:OnServerEvent(function(player: Player, slotId: string)
		self:PromptSkipCookProduct(player, slotId)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)
end

return GrillerManager
