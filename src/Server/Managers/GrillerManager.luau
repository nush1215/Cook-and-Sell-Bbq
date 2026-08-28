-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local RandomUtil = require(Shared.RandomUtil)
local Ingredients = require(Shared.Config.Ingredients)
local CookStates = require(Shared.Config.CookStates)
local Structures = require(Shared.Config.Structures)

--
local PlayerDataManager
local NotificationManager
local StickManager
local StatsManager
local ShopManager

--
local STICK_TOOL_TAG = "StickTool"

-- The structure category grillers are, which is also the tag every placed one wears. The category and
-- not one model's id, so a second kind of griller added to Config.Structures is picked up here with
-- nothing changed: this manager owns grillers, not one particular griller.
local GRILLER_CATEGORY = "Grillers"

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

    Player data is the source of truth: data.Grillers[structureUid] = { StickId, Ingredients, Cooked?,
    CookState? } holds the skewer on each griller. While it cooks the record also carries Cooking =
    true, CookStartedAt = workspace:GetServerTimeNow() and CookTime = the whole bar in seconds. Nothing
    is scheduled off those: a cook nobody stops just keeps running, across a rejoin included, and the
    elapsed time on the stop is what settles it -- a skewer left overnight comes off charred, once its
    owner walks up and turns the stove off. The stamp is the synced clock rather than os.time() because
    os.time() only resolves to whole seconds, which on a window this tight is most of it. Only a stick
    with ingredients (a FilledStickTool) can go on.

    Grillers are structures the player builds rather than slots authored into their base (see
    Config.Structures), so which ones exist is discovered off the Griller tag: every placed one is
    bound as it appears and dropped as it goes, and it's keyed by the uid on it -- which is also the
    key its record sits under. Placing one mid-session therefore needs nothing told about it. The
    static skewer model is still cloned in server-side (so everyone sees it), like SauceDispenserManager.

    The cook animation and the stove visuals are NOT rendered here: the server just mirrors the record
    onto the griller's replicated attributes (PlacedStickId / Cooking / Cooked / CookStartedAt /
    CookTime / CookIngredients), and every client's GrillerController spins the skewer, browns its
    ingredients, draws the cooking bar and lights the stove off those, so the motion is smooth and
    local instead of replicated per frame. The bands the bar reads are fixed fractions in the config,
    so none of them have to be replicated.
]]

--
local GrillerManager = {
	ToggleGrillEvent = Network.Event("ToggleGrillStick"),
	StartCookEvent = Network.Event("StartCooking"),
	StopCookEvent = Network.Event("StopCooking"),
	RequestSkipCookEvent = Network.Event("RequestSkipCook"),

	-- (player, cookStateId, elapsed, method) when a cook is stopped and settled. elapsed is how long it
	-- sat on the heat in seconds. method is "Timed", "Skipped" or "PickedUp" -- a skipped cook's elapsed is
	-- however long it happened to be on when it was bought out, which says nothing about the cook, and a
	-- picked-up one ended because the griller under it came down rather than because anyone was watching
	-- the bar, so none of the three can be read as one population.
	OnCookCompleted = Signal.new(),

	_grillers = {}, -- [player] = { [uid] = Model }, every placed griller they own
	_skewers = {}, -- [player] = { [uid] = Model }, the skewers we've cloned onto those grillers
	_listeners = {}, -- [player] = the Grillers data listener
	_toggling = {}, -- [player] = true across the read -> write window, so a spammed prompt can't double up
	_starting = {}, -- [player] = true across StartCooking's read -> write window
	_stopping = {}, -- [player] = true across StopCooking's read -> write window
	_skipping = {}, -- [player] = true across the skip's read -> prompt window, so a mashed button raises one
	_pendingSkipCookUid = {}, -- [player] = the griller their open skip-cook Robux prompt was raised from
	_cookWindowStretch = {}, -- [player] = how many times longer their perfect window runs, stamped per cook
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- What a skewer model is built from, as one string, so a re-render can tell a record that would build
-- the same model again from one that genuinely wouldn't. Every field StickModel.BuildStickModel varies
-- on is in here and nothing else is -- the cook stamps deliberately aren't, which is the whole point:
-- they change on every light and every settle, and rebuilding for them is what used to swap an
-- identical model in under a client that was mid-animation on the old one.
local function skewerModelKey(record): string
	return table.concat({
		record.StickId,
		table.concat(record.Ingredients, ","),
		if record.Cooked then "1" else "",
		record.CookState or "",
		record.Sauce or "",
		record.Mutation or "",
	}, "|")
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

-- Whether the uid off a remote names one of the player's own grillers. Every entry point that acts on
-- a griller goes through here, since a uid is player input and can be anything -- and reading it off
-- their build rather than the world proves the structure exists, is a griller, and is theirs, in one.
-- `data` is the caller's already-read player data, since every caller has read it to act anyway.
function GrillerManager:OwnsGrillerStructure(data, uid: string): boolean
	local structure = data.Structures[uid]
	return structure ~= nil and Structures.IsCategory(structure.Type, GRILLER_CATEGORY)
end

-- The config entry for the griller at `uid`, or nil if it's gone. Everything a cook takes from the
-- grill rather than from the skewer -- how fast it cooks, how steadily it holds that rate, what it
-- stamps on the result -- is read through here, off the grill the cook actually happened on rather
-- than off the skewer's record. That's what keeps a BBQ only ever shaped by the grill it was on.
--
-- The structure may be gone: a bought cook skip can land minutes after its prompt went up, and the
-- grill can have been picked up in between.
-- `data` is the caller's already-read player data, since every caller has read it to act anyway.
function GrillerManager:GetGrillerStructure(data, uid: string): Structures.Structure?
	local placed = data.Structures[uid]

	return placed and Structures.GetStructureFromId(placed.Type)
end

-- The mutation the griller at `uid` stamps onto a cook that settles on it, or nil for a plain grill --
-- and nil for a chance grill whose roll missed. A grill with no MutationChance stamps every time (the
-- Golden Grill, which is bought for exactly that); one with a chance rolls here, as the cook settles,
-- so the roll is the server's and lands once rather than being something a client can see coming.
function GrillerManager:GetGrillerMutation(data, uid: string): string?
	local structure = self:GetGrillerStructure(data, uid)
	if not structure or not structure.Mutation then
		return nil
	end

	if structure.MutationChance and not RandomUtil.RollChance(structure.MutationChance) then
		return nil
	end

	return structure.Mutation
end

-- Mirrors a griller's record onto its replicated attributes. The client reads these to drive both its
-- owner prompt/knob and the cook animation it renders (spin, raw -> cooked colour, stove), so
-- CookStartedAt / CookTime let it play out deterministically and CookIngredients tells it what each
-- part cooks toward. CookWindowStretch goes with them for the same reason: it bends the bar, so a client
-- that didn't have it would draw a different cook to the one the stop resolves against. CookProgress
-- rides along for the same reason -- a resumed cook starts part-way up the bar, and a client without it
-- would draw one starting at zero -- and so do the two instability fields, which bend it a second way.
-- A nil record clears the griller.
function GrillerManager:_writeSlotAttributes(slot: Instance, record)
	slot:SetAttribute("PlacedStickId", if record then record.StickId else nil)
	slot:SetAttribute("Cooking", if record and record.Cooking then true else nil)
	slot:SetAttribute("Cooked", if record then record.Cooked or nil else nil)
	slot:SetAttribute("CookStartedAt", if record then record.CookStartedAt else nil)
	slot:SetAttribute("CookTime", if record then record.CookTime else nil)
	slot:SetAttribute("CookWindowStretch", if record then record.CookWindowStretch else nil)
	slot:SetAttribute("CookProgress", if record then record.CookProgress else nil)
	slot:SetAttribute("CookInstability", if record then record.CookInstability else nil)
	slot:SetAttribute("CookInstabilityPhase", if record then record.CookInstabilityPhase else nil)
	slot:SetAttribute("CookIngredients", if record then table.concat(record.Ingredients, ",") else nil)
end

-- Brings the models on the player's grillers in line with their records: the right skewer sits on each
-- occupied griller's StickAttachment, and its attributes mirror the state for the client's prompt and
-- its cook animation.
function GrillerManager:_renderGrills(player: Player)
	local grillers = self._grillers[player]
	if not grillers then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local skewers = self._skewers[player]
	if not skewers then
		skewers = {}
		self._skewers[player] = skewers
	end

	for uid, slot in grillers do
		local record = data.Grillers[uid]
		local cooking = record ~= nil and record.Cooking == true

		local existing = skewers[uid]

		-- Every record write lands here, but most of them don't change what's on the skewer -- so a model
		-- that would only be built again exactly as it stands is kept and re-stamped instead. That covers
		-- the two writes that would otherwise swap an identical model in under a client that's mid-
		-- animation on the old one: a re-render triggered by interacting with another griller, which
		-- would pop a browning skewer back to raw, and the light itself -- StartCooking carries the record
		-- over untouched but for the stamps, and the rebuild it used to force tore the client's spin off
		-- its model on exactly the frame the spin starts. The settle still rebuilds, since that one really
		-- does change what's on the skewer (Cooked, its state, and any mutation stamped with it).
		if existing and record and existing:GetAttribute("ModelKey") == skewerModelKey(record) then
			existing:SetAttribute("CookStartedAt", if cooking then record.CookStartedAt else nil)
			self:_writeSlotAttributes(slot, record)
			continue
		end

		-- Grillers change rarely (outside cooking), so just rebuild rather than diff.
		if existing then
			existing:Destroy()
			skewers[uid] = nil
		end

		if record then
			local model = StickManager:BuildPlacedStickModel(record)
			local attachment = slot:FindFirstChild("StickAttachment", true)

			-- The griller's parts come off its template in the place file, so a missing attachment is a
			-- real failure case.
			if model and attachment then
				-- A fixed name and the cook stamp are the client's handle on the skewer: it finds it by
				-- name and only browns it while this cook is the one running. ModelKey is this end's own:
				-- what the model was built from, which is what the reuse check above reads back off it.
				model.Name = "Skewer"
				model:SetAttribute("CookStartedAt", if cooking then record.CookStartedAt else nil)
				model:SetAttribute("ModelKey", skewerModelKey(record))

				-- Seated off where the griller belongs rather than where it currently is. A structure
				-- built this session is left PLACE_DROP_HEIGHT above its cell here on the server -- only
				-- the client springs it down onto it (LayoutStand, off the same SlotCFrame) -- so the
				-- attachment's world pose is that far out, and a skewer pivoted straight onto it hangs in
				-- the air over the grill on every client. Taking the attachment's pose in model space and
				-- re-seating it on the settled pivot carries it down with the griller.
				local pivot = slot:GetPivot()
				local settled = slot:GetAttribute("SlotCFrame") or pivot
				model:PivotTo(settled * pivot:Inverse() * attachment.WorldCFrame)

				model.Parent = slot
				skewers[uid] = model
			elseif model then
				warn(`[Griller] {player.Name}'s griller {uid} has no StickAttachment, its skewer won't render`)
				model:Destroy()
			end
		end

		self:_writeSlotAttributes(slot, record)
	end
end

-- Takes on a griller as it's placed, and sets its owner up if this is their first. The whole render
-- runs off the back of it rather than just this one: a re-render leaves a cook that's already going
-- exactly as it is, so it costs nothing.
function GrillerManager:_bindGriller(model: Model)
	local player = Players:GetPlayerByUserId(model:GetAttribute(Structures.OWNER_ATTRIBUTE))

	-- The owner can leave between their base being torn down and this signal being handled.
	if not player then
		return
	end

	local grillers = self._grillers[player]
	if not grillers then
		grillers = {}
		self._grillers[player] = grillers
	end

	grillers[model:GetAttribute(Structures.UID_ATTRIBUTE)] = model

	self:_setupPlayer(player)
	self:_renderGrills(player)
end

-- Drops a griller as it's taken away, along with the skewer we cloned onto it. The griller model is
-- destroyed by the base itself; this is only the bookkeeping either side of it.
function GrillerManager:_unbindGriller(model: Model)
	local player = Players:GetPlayerByUserId(model:GetAttribute(Structures.OWNER_ATTRIBUTE))
	if not player then
		return
	end

	local uid = model:GetAttribute(Structures.UID_ATTRIBUTE)

	local skewer = self._skewers[player] and self._skewers[player][uid]
	if skewer then
		skewer:Destroy()
		self._skewers[player][uid] = nil
	end

	if self._grillers[player] then
		self._grillers[player][uid] = nil
	end
end

-- Puts the player's equipped filled skewer on an empty grill, or takes the finished one back off. A
-- skewer that's mid-cook is locked on. The Grillers write re-renders through the listener.
function GrillerManager:ToggleGrillStick(player: Player, uid: string)
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

	if not self:OwnsGrillerStructure(data, uid) then
		self._toggling[player] = nil
		return
	end

	local record = data.Grillers[uid]

	if record then
		-- Occupied: hand the skewer back and clear the grill. The return only turns this down for a cook
		-- already being stopped by hand, which the prompt can't offer a toggle on anyway.
		if not self:ReturnContentsToPlayer(player, data, uid, record) then
			self._toggling[player] = nil
			return
		end

		PlayerDataManager:SetPlayerDataKey(player, { "Grillers", uid }, nil)
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

		PlayerDataManager:SetPlayerDataKey(player, { "Grillers", uid }, {
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

-- Hands a griller's skewer back to the player as a distinct filled tool, carrying however its cook
-- went and whatever a pull off the raw band banked on it.
--
-- Shared by the prompt above and by BaseManager taking the whole griller down, so a griller picked up
-- with a skewer on it gives back exactly what taking that skewer off by hand would have. Clearing the
-- record is the caller's, since only they know what else is being written alongside it.
--
-- A lit grill isn't turned away: the cook is settled where it had actually got to, exactly as the stop
-- prompt would have settled it at that moment. So picking a griller up is never a way to dodge a burn,
-- and never a way to lose a cook either.
--
-- @param fromPickup The griller was taken down with the pickup tool rather than the skewer taken off
-- it. The skewer goes quietly to the backpack instead of into their hands -- the hammer stays equipped,
-- so a base can be cleared in one go -- and a toast says what happened, since without the tool
-- appearing in their hand nothing on screen otherwise would.
-- @return Whether the pickup may go ahead. False only for a cook this player is already stopping by
-- hand: letting both run would have that stop write the record back under a uid the pickup has just
-- taken away, stranding it where nothing can reach it.
function GrillerManager:ReturnContentsToPlayer(player: Player, data, uid: string, record, fromPickup: boolean?): boolean
	local settled = record
	local cookState

	if record.Cooking then
		-- Read first, like the stop prompt does, so the seconds spent settling below aren't charged to the
		-- cook. Unlike the stop this isn't the timing call the minigame turns on -- the player is taking the
		-- grill down, not calling the moment -- so the read BaseManager already yielded on before getting
		-- here costs nothing worth correcting for.
		local stoppedAt = workspace:GetServerTimeNow() - math.min(player:GetNetworkPing(), MAX_STOP_COMPENSATION)

		-- The same lock the stop prompt takes, and held right through the hand-back rather than just the
		-- settle: AddFilledStick yields inside the reconcile it kicks off, and the caller only clears
		-- Grillers[uid] once this returns. A stop slipping into that gap would read the record still sitting
		-- there mid-cook, settle it a second time and write it back -- counting one cook twice.
		if self._stopping[player] then
			return false
		end
		self._stopping[player] = true

		settled, cookState = self:SettleCookRecord(data, uid, record, stoppedAt)

		-- Counted like any cook ended by hand: the skewer carries a state now, so leaving it out would put
		-- SkewersCooked and the sum of CookStateCounts out of step. The elapsed reported is this stint on
		-- the heat in real, unwarped seconds, and the method is what says it ended with the grill rather
		-- than with the knob.
		self:RecordCookResult(player, cookState, stoppedAt - record.CookStartedAt, "PickedUp")
	end

	StickManager:AddFilledStick(player, {
		StickId = settled.StickId,
		Ingredients = table.clone(settled.Ingredients),
		Cooked = settled.Cooked,
		CookState = settled.CookState,
		CookProgress = settled.CookProgress,
		Mutation = settled.Mutation,
	}, fromPickup)

	-- Only ever taken on the branch above, so only dropped for the same one -- clearing it flat would
	-- release a lock a stop running alongside an idle take is holding.
	if cookState then
		self._stopping[player] = nil
	end

	-- Skipped when a cook was settled: RecordCookResult has already toasted the verdict on it, which says
	-- everything this one would and more, and two landing together would just talk over each other.
	if fromPickup and not cookState then
		NotificationManager:NotifyNormal(player, {
			Text = "BBQ returned to your inventory",
			Duration = 3,
			Sound = "Notify",
			Effect = "Success",
		})
	end

	return true
end

-- Lights the stove under an eligible skewer: works out how long the whole bar takes from its
-- ingredients and stamps the record, so the cook survives a rejoin. Nothing is scheduled off the stamp
-- -- only the player's own stop ever ends a cook.
function GrillerManager:StartCooking(player: Player, uid: string)
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

	if not self:OwnsGrillerStructure(data, uid) then
		self._starting[player] = nil
		return
	end

	-- Only a raw skewer that's sitting there and not already cooking can be lit.
	local record = data.Grillers[uid]
	if not record or record.Cooking or record.Cooked then
		self._starting[player] = nil
		return
	end

	-- What's stamped is the whole bar, not the wait until the skewer is done: dividing by RAW_END is what
	-- puts the raw -> cooked boundary on exactly the second an ingredient's CookTime says it should, with
	-- the rest of the bar being the window and the run past it. The burn past the end of the bar isn't
	-- scaled by any of this -- it's wall-clock seconds in the config, so every skewer gives the same
	-- window to notice.
	--
	-- A fast grill divides that whole bar rather than any one band of it, which is what makes speed a
	-- trade instead of a free upgrade: the skewer is done sooner, but the perfect window is that many
	-- times shorter in real seconds too. The burn stays where it is for the reason just given, so the
	-- time to notice a filled bar is the same on every grill however fast it got there.
	local structure = self:GetGrillerStructure(data, uid)

	local cookTime = Ingredients.GetTotalCookTime(record.Ingredients)
		/ CookStates.RAW_END
		/ (structure and structure.CookSpeed or 1)
	if cookTime <= 0 then
		self._starting[player] = nil
		return
	end

	-- Stamped onto the cook rather than read at the stop, the same as CookTime: the run has to bend the
	-- same way from the first frame to the last, so a player whose stretch is lifted mid-cook (finishing
	-- their tutorial) keeps the bar they lit, and a rejoin picks up the one they left.
	--
	-- CookProgress carries straight over: it's a fraction of the bar rather than seconds off it, so it
	-- means the same thing on whatever grill the skewer is finished on. CookStartedAt stays honest about
	-- when the stove was lit -- the offset is added in when the bar is read, not hidden in the stamp, so
	-- the stove and spin still ramp from a standstill.
	PlayerDataManager:SetPlayerDataKey(player, { "Grillers", uid }, {
		StickId = record.StickId,
		Ingredients = table.clone(record.Ingredients),
		Cooking = true,
		CookStartedAt = workspace:GetServerTimeNow(),
		CookTime = cookTime,
		CookWindowStretch = self._cookWindowStretch[player],
		CookProgress = record.CookProgress,
		-- Stamped off the grill the stove was lit on, alongside CookTime and the stretch and for the same
		-- reason: the run has to bend the same way from its first frame to its last, so a rejoin picks up
		-- the bar that was left and a config retuned under a running cook doesn't move it.
		--
		-- The phase is rolled per cook rather than fixed, which is what stops the surges from landing on
		-- the same places on the bar every time and turning the grill into one lottery per recipe. Rolled
		-- here and replicated rather than derived from CookStartedAt on each client: it's a gameplay curve,
		-- and hanging it off the low bits of a timestamp would quietly reshape it the day anything about
		-- how that stamp is taken ever changes.
		CookInstability = structure and structure.CookInstability,
		CookInstabilityPhase = if structure and structure.CookInstability
			then RandomUtil.GetRandomFromMinMax(0, 2 * math.pi)
			else nil,
		-- Mutation is deliberately absent: nothing stamps one at the light, and a record reaching here
		-- couldn't be carrying one anyway -- a mutated skewer is cooked, and a cooked one was refused
		-- above. It's stamped when the cook settles, off the grill it settled on.
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

-- Raises the Robux prompt for skipping the cook running on one of the player's grills. Which grill it
-- was is remembered here rather than carried on the product, since the receipt arrives with nothing on
-- it but the buyer.
function GrillerManager:PromptSkipCookProduct(player: Player, uid: string)
	if not validatePlayer(player) then
		return
	end

	-- The offer is a button on the cooking bar rather than a prompt with a hold on it, so nothing on the
	-- way in slows a mashed one down but this. Held across the read below as well as the prompt: the two
	-- requests either side of the yield would otherwise both write _pendingSkipCookUid.
	if self._skipping[player] then
		return
	end
	self._skipping[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._skipping[player] = nil
		return
	end

	if not self:OwnsGrillerStructure(data, uid) then
		self._skipping[player] = nil
		return
	end

	-- There's nothing to buy your way out of on a grill that isn't cooking. The client only puts the
	-- button up through a cook, so this is the remote being held to that rather than a case a player can
	-- walk into.
	local record = data.Grillers[uid]
	if not record or not record.Cooking then
		NotificationManager:NotifyNormal(player, {
			Text = "Nothing's cooking on that grill",
			Duration = 3,
			Sound = "Reject",
		})
		self._skipping[player] = nil
		return
	end

	self._pendingSkipCookUid[player] = uid
	ShopManager:AttemptProductPurchase(player, SKIP_COOK_PRODUCT)

	self._skipping[player] = nil
end

-- Finishes a cook the player bought their way out of, settling it perfect wherever the bar had actually
-- got to (fired by ShopManager from the product's callback). It goes to the grill the prompt was raised
-- from.
--
-- A receipt Roblox never got an answer for is re-processed on a later join, where nothing raised a prompt
-- and there's no pending griller to read -- so that case falls back to whatever the player has on a grill
-- rather than dropping a purchase they've already been charged for. A cook nobody stops keeps running
-- across a rejoin, so the one they bought this for is usually still sitting there on the heat waiting.
function GrillerManager:GrantSkipCookFromProduct(player: Player)
	local uid = self._pendingSkipCookUid[player]
	self._pendingSkipCookUid[player] = nil

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- The pending griller is read back rather than trusted: raising the prompt and answering it are minutes
	-- apart at worst, and the cook it was raised from can be stopped by hand in between.
	local record = if uid then data.Grillers[uid] else nil
	if record and record.Cooked then
		record = nil
	end

	if not record then
		uid = nil

		-- Their own grillers only: a record can outlive the structure it sat on if a removal ever half
		-- lands, and spending a receipt on one of those would put a BBQ somewhere nothing can reach.
		for candidateUid, candidate in data.Grillers do
			if candidate.Cooked or not self:OwnsGrillerStructure(data, candidateUid) then
				continue
			end

			-- A running cook is what they were buying out of, so it takes it outright. A BBQ sitting there
			-- unlit is only worth falling back to if nothing at all is on the heat.
			if candidate.Cooking then
				uid, record = candidateUid, candidate
				break
			end

			if not record then
				uid, record = candidateUid, candidate
			end
		end

		if not record then
			warn(`[Griller] {player.Name} bought a cook skip with nothing on a grill to spend it on`)
			return
		end
	end

	PlayerDataManager:SetPlayerDataKey(player, { "Grillers", uid }, {
		StickId = record.StickId,
		Ingredients = table.clone(record.Ingredients),
		Cooked = true,
		CookState = SKIP_COOK_STATE,
		-- Cleared rather than carried across: the skip takes the cook past the raw band, and clearing that
		-- band is what consumes a bank, exactly as a stop past it does.
		CookProgress = nil,
		-- Stamped the same way a cook stopped by hand is, off the grill it settled on. Unconditional
		-- where the stop has a raw case to rule out, since a skip always lands past the raw band.
		Mutation = self:GetGrillerMutation(data, uid),
	})

	-- The elapsed reported is the real seconds it did spend on the heat before being bought out -- none at
	-- all on a BBQ that was never lit. The toast this ends on is the same one a cook that landed in the
	-- window by hand gets, off the same state: what the player bought is that result, so it should read as
	-- that result.
	self:RecordCookResult(
		player,
		SKIP_COOK_STATE,
		if record.CookStartedAt then workspace:GetServerTimeNow() - record.CookStartedAt else 0,
		"Skipped"
	)
end

-- Pulls a griller's skewer off the heat, settling it where the cook had got to and leaving it on the
-- grill to be taken off. The timing is the whole minigame, so what this owns over SettleCookRecord is
-- reading the moment the player acted before anything yields.
function GrillerManager:StopCooking(player: Player, uid: string)
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

	-- Nothing else needs checking -- a made-up uid has no record, let alone one that's cooking.
	local record = data.Grillers[uid]
	if not record or not record.Cooking then
		self._stopping[player] = nil
		return
	end

	local settled, state = self:SettleCookRecord(data, uid, record, stoppedAt)
	PlayerDataManager:SetPlayerDataKey(player, { "Grillers", uid }, settled)

	self._stopping[player] = nil

	-- The elapsed reported is this stint on the heat and not the bar it landed on: real, unwarped seconds
	-- off a real clock, so a cook resumed from an earlier pull reports the leg that was actually run rather
	-- than counting the banked part twice across two stops.
	self:RecordCookResult(player, state, stoppedAt - record.CookStartedAt, "Timed")
end

-- Works out where a cook had got to and returns the record it settles into, without writing it: raw below
-- the window (so it stays re-cookable), perfect inside it, merely cooked through the rest of the bar, and
-- overcooked then charred for however long past the end of it nobody came back.
--
-- Shared by the stop prompt and by a griller picked up mid-cook, so both land on the same state for the
-- same moment on the bar. Returned rather than written because the two want it in different places -- one
-- back onto the grill, the other onto a skewer going into the backpack.
--
-- @param stoppedAt The ping-compensated server time the cook ended at, which the caller reads before
-- anything that yields -- the correction is only worth anything against the moment the player acted.
-- @return the settled record, and the CookStates id it settled on
function GrillerManager:SettleCookRecord(data, uid: string, record, stoppedAt: number)
	-- Warped after the ping compensation, not before: that correction is in real seconds off a real clock,
	-- and it's the corrected moment that has to be read against the bar the player was watching.
	-- CookProgress goes in with it, so a resumed cook is read against the whole bar it's been through
	-- rather than only this leg of it, and the instability pair so an unstable grill settles on the bar
	-- that was actually drawn rather than the steady one underneath it.
	local elapsed = CookStates.GetBarElapsed(
		stoppedAt - record.CookStartedAt,
		record.CookTime,
		record.CookWindowStretch,
		record.CookProgress,
		record.CookInstability,
		record.CookInstabilityPhase
	)

	local state = CookStates.GetStateFromCook(elapsed, record.CookTime)
	local raw = state == "Raw"

	return {
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
		-- means the same thing on whatever grill the cook is picked back up on. Being raw is what bounds it
		-- under RAW_END, and any cook that got past that band consumes the bank by clearing it.
		CookProgress = if raw then elapsed / record.CookTime else nil,
		-- Off the grill it cooked on rather than anything on the record, so a BBQ is only ever mutated by
		-- the grill it was actually cooked on. Nil on a raw pull alongside the two above, and for the same
		-- reason plus one: a raw skewer is meant to be indistinguishable from one that was never lit, and
		-- stamping one would let a player light a Golden Grill for a second, pull it raw, and then finish
		-- the cook on a plain grill still carrying the multiplier.
		Mutation = if raw then nil else self:GetGrillerMutation(data, uid),
	}, state
end

-- Counts a finished cook and gives the player the verdict on it.
--
-- Every cook that ends counts, a raw pull included -- the raw ones are the interesting half of a
-- cook-quality tally rather than a non-event, so SkewersCooked always comes to the sum of
-- CookStateCounts. Shared by all three ways a cook can end, which is what keeps that true.
--
-- @param elapsed Real, unwarped seconds this skewer spent on the heat -- not where it landed on the bar.
-- @param method How the cook ended: "Timed" off the knob, "Skipped" bought out with Robux, or "PickedUp"
-- with the whole griller. Analytics reads them apart because they can't be one population -- see the
-- comment on OnCookCompleted.
function GrillerManager:RecordCookResult(player: Player, stateId: string, elapsed: number, method: string)
	StatsManager:RecordCookCompleted(player, stateId)
	self.OnCookCompleted:Fire(player, stateId, elapsed, method)

	-- The verdict on the cook, written next to the state it belongs to rather than spelled out here. Every
	-- state carries one now, a raw pull included: what it's there to say is that the cook was banked and
	-- not lost, which is the one thing about a stop the bar can't show on its way down. Slots landing
	-- together share their text, so they collapse into one toast with a counter rather than stacking.
	local notification = CookStates.GetStateFromId(stateId).Notification
	if notification then
		NotificationManager:NotifyNormal(player, {
			Text = notification.Text,
			Duration = 3,
			Sound = notification.Sound,
			Effect = notification.Effect,
		})
	end
end

-- Registers the player's data listener. Guarded so two grillers being bound in the same frame can't
-- set the same player up twice.
function GrillerManager:_setupPlayer(player: Player)
	if self._listeners[player] then
		return
	end

	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "Grillers", function()
		self:_renderGrills(player)
	end)
end

-- Drops the player's listener and the models we cloned onto their grills.
function GrillerManager:_cleanupPlayer(player: Player)
	local listener = self._listeners[player]
	if listener then
		listener:Disconnect()
		self._listeners[player] = nil
	end

	local skewers = self._skewers[player]
	if skewers then
		for _, model in skewers do
			model:Destroy()
		end
		self._skewers[player] = nil
	end

	self._grillers[player] = nil
	self._toggling[player] = nil
	self._starting[player] = nil
	self._stopping[player] = nil
	self._skipping[player] = nil
	self._pendingSkipCookUid[player] = nil
	self._cookWindowStretch[player] = nil
end

function GrillerManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	NotificationManager = require(script.Parent.NotificationManager)
	StickManager = require(script.Parent.StickManager)
	StatsManager = require(script.Parent.StatsManager)
	ShopManager = require(script.Parent.ShopManager)
end

function GrillerManager:OnStart()
	-- A griller placed on any base wires itself up here, so nothing has to be told about it -- not the
	-- base going up on join, and not a player building one mid-session.
	CollectionService:GetInstanceAddedSignal(GRILLER_CATEGORY):Connect(function(model: Model)
		self:_bindGriller(model)
	end)

	CollectionService:GetInstanceRemovedSignal(GRILLER_CATEGORY):Connect(function(model: Model)
		self:_unbindGriller(model)
	end)

	-- Bases assigned before this manager started won't have fired the signal above, so sweep them.
	for _, model in CollectionService:GetTagged(GRILLER_CATEGORY) do
		task.spawn(function()
			self:_bindGriller(model)
		end)
	end

	self.ToggleGrillEvent:OnServerEvent(function(player: Player, uid: string)
		self:ToggleGrillStick(player, uid)
	end)

	self.StartCookEvent:OnServerEvent(function(player: Player, uid: string)
		self:StartCooking(player, uid)
	end)

	self.StopCookEvent:OnServerEvent(function(player: Player, uid: string)
		self:StopCooking(player, uid)
	end)

	self.RequestSkipCookEvent:OnServerEvent(function(player: Player, uid: string)
		self:PromptSkipCookProduct(player, uid)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)
end

return GrillerManager
