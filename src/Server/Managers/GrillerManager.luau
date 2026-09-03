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

-- The category, and the tag every placed griller wears. A category rather than one model's id, so a
-- second kind of griller is picked up here with nothing changed.
local GRILLER_CATEGORY = "Grillers"

-- Most of a player's ping we'll take off their take, in seconds: ping is dead time between the press and
-- us hearing it, so subtracting it is what makes the state they saw the state they get. Capped so a
-- dropped connection can't rewind the bar by seconds.
local MAX_STOP_COMPENSATION = 0.25

-- Perfect is what the bar is aimed at rather than a bonus over it -- ingredient prices are tuned against
-- it -- so the product sells away the timing risk, not a state the player couldn't have hit themselves.
local SKIP_COOK_STATE = "Perfect"
local SKIP_COOK_PRODUCT = "SkipCook"

--[[
    Placing a filled skewer onto a griller, which lights it, and taking it back off, which settles it. A
    cook is a timing minigame, not a countdown: only the player ever ends it, and where they stopped is
    what they get (see CookStates). Two beats rather than three -- the grate is the whole interface.

    Player data is the source of truth -- data.Grillers[structureUid] holds the skewer, plus Cooking /
    CookStartedAt / CookTime while it runs. Nothing is scheduled off those: the elapsed time at the take is
    what settles a cook. The stamp is the synced clock rather than os.time(), which only resolves to whole
    seconds -- most of this window.

    A cook is frozen for as long as its owner is away: the seconds it had run are banked at their last save
    and the clock is restamped off them when they come back, so a session gap neither burns a BBQ nor buys
    any progress, and a rejoin resumes the same bar the skewer went down on.

    Which grillers exist is discovered off the Griller tag and keyed by uid, so one placed mid-session
    needs nothing told about it.

    No animation is rendered here: the server mirrors the record onto replicated attributes and each
    client's GrillerController draws the spin, browning, bar and coals off them.
]]

--
local GrillerManager = {
	ToggleGrillEvent = Network.Event("ToggleGrillStick"),
	RequestSkipCookEvent = Network.Event("RequestSkipCook"),

	-- (player, cookStateId, elapsed, method) when a cook settles. method is "Timed" (taken off by hand),
	-- "Skipped" or "PickedUp" (the whole griller taken down) -- the three can't be read as one population,
	-- since only "Timed" elapsed says anything about how the cook went.
	OnCookCompleted = Signal.new(),

	_grillers = {}, -- [player] = { [uid] = Model }, every placed griller they own
	_skewers = {}, -- [player] = { [uid] = Model }, the skewers we've cloned onto those grillers
	_listeners = {}, -- [player] = the Grillers data listener
	_toggling = {}, -- [player] = true across the read -> write window, so a spammed prompt can't double up
	-- [player] = true across a settle, so a hand take and a griller pickup can't settle the same cook twice
	_stopping = {},
	_skipping = {}, -- [player] = true across the skip's read -> prompt window, so a mashed button raises one
	_pendingSkipCookUid = {}, -- [player] = the griller their open skip-cook Robux prompt was raised from
	_cookWindowStretch = {}, -- [player] = how many times longer their perfect window runs, stamped per cook
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Every field BuildStickModel varies on, as one string, so a re-render can tell a record that would build
-- the same model from one that wouldn't. The cook stamps are deliberately excluded: they change on every
-- light and settle, and rebuilding for them swapped an identical model in under a mid-animation client.
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

-- Whether the player has a bare (ingredient-less) stick equipped. Only used to pick which advice the
-- rejection gives.
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

-- The config entry for the griller at `uid`. Everything a cook takes from the grill rather than the
-- skewer -- speed, steadiness, what it stamps -- reads through here, so a BBQ is only ever shaped by the
-- grill it was on. Nil when it's gone: a bought skip can land minutes after a pickup.
-- `data` is the caller's already-read player data, since every caller has read it to act anyway.
function GrillerManager:GetGrillerStructure(data, uid: string): Structures.Structure?
	local placed = data.Structures[uid]

	return placed and Structures.GetStructureFromId(placed.Type)
end

-- The mutation the griller stamps onto a settling cook, or nil. No MutationChance means it stamps every
-- time; a chance is rolled here, as the cook settles, so the roll is the server's and lands once.
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

-- Mirrors a griller's record onto its replicated attributes, which is everything the client needs to draw
-- the prompt and the cook. Every field that bends the bar (WindowStretch, Progress, the two instability
-- ones) has to ride along, or a client would draw a different cook to the one the take resolves against.
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

-- Brings the models on the player's grillers in line with their records, and mirrors each one's state
-- onto its attributes.
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

		-- Every record write lands here but most don't change the skewer, so an identical model is kept and
		-- re-stamped. That stops a write swapping a model in under a mid-animation client -- a re-render
		-- from another griller, which popped a browning skewer back to raw, and a rejoin's restamp, which
		-- would tear the spin off a resumed cook. The settle still rebuilds: it really does change the
		-- skewer. A place builds one either way, since the grate it lands on was empty.
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

			-- The griller's parts come off its place-file template, so a missing attachment is a real failure.
			if model and attachment then
				-- The client finds the skewer by name and browns it only while this cook is the running
				-- one. ModelKey is ours -- what the model was built from, read back by the reuse check above.
				model.Name = "Skewer"
				model:SetAttribute("CookStartedAt", if cooking then record.CookStartedAt else nil)
				model:SetAttribute("ModelKey", skewerModelKey(record))

				-- Whole or not at all, as with a placed structure (see Base:BuildStructure): the client hangs
				-- the take prompt on the skewer's first part, which the default mode can deliver a frame late.
				model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

				-- Seated off where the griller *belongs*, not where it is: the server leaves a freshly built
				-- one PLACE_DROP_HEIGHT above its cell (only the client springs it down), so a skewer
				-- pivoted onto the live attachment would hang in the air. Re-seating the attachment's model
				-- -space pose on the settled pivot carries it down with the griller.
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

-- Takes on a griller as it's placed, setting its owner up on their first. Re-renders all of them, not
-- just this one -- a re-render leaves a running cook exactly as it is, so it costs nothing.
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

-- Drops a griller as it's taken away, along with the skewer cloned onto it. The base destroys the griller
-- model itself; this is only the bookkeeping.
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

-- Puts the player's equipped filled skewer on an empty grill and lights it, or takes it back off and
-- settles it wherever the bar had got to. The whole cook is these two presses. The Grillers write
-- re-renders through the listener.
function GrillerManager:ToggleGrillStick(player: Player, uid: string)
	if not validatePlayer(player) then
		return
	end

	-- Before anything that can yield, since a take is the stop: this timestamp is the whole minigame, and
	-- subtracting ping is what makes the state they saw the state they get. Read even on a place, which is
	-- the branch that ignores it, because which branch this is isn't known until after the read below.
	local stoppedAt = workspace:GetServerTimeNow() - math.min(player:GetNetworkPing(), MAX_STOP_COMPENSATION)

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
		-- Occupied: settle whatever was cooking, hand the skewer back and clear the grill. The return only
		-- turns this down for a cook this player is already settling from the other entry point.
		if not self:ReturnContentsToPlayer(player, data, uid, record, nil, stoppedAt) then
			self._toggling[player] = nil
			return
		end

		PlayerDataManager:SetPlayerDataKey(player, { "Grillers", uid }, nil)
	else
		-- Only a filled skewer can go on -- a bare stick has nothing to cook.
		local filled = StickManager:GetEquippedFilledStick(player, data)
		if not filled then
			-- A bare stick has a clear next step, so say that rather than the generic advice.
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

		-- Setting a skewer down is what starts its cook -- there's nothing else to do with one on a grate.
		-- Cooked and CookState don't survive the trip on purpose: a cooked skewer was refused above, so what
		-- goes down is raw, and Mutation is stamped when the cook settles rather than carried onto the grate.
		PlayerDataManager:SetPlayerDataKey(
			player,
			{ "Grillers", uid },
			self:StartCookRecord(player, data, uid, filled)
		)
		-- The skewer moves from the inventory onto the grill.
		PlayerDataManager:SetPlayerDataKey(player, { "FilledSticks", filled.Uid }, nil)
	end

	self._toggling[player] = nil
end

-- Hands a griller's skewer back as a filled tool, settling however its cook went. Taking a skewer off is
-- the stop, so this is where every hand-ended cook lands; shared with BaseManager taking the whole griller
-- down, so a pickup gives back exactly what taking the skewer off by hand would. Clearing the record is
-- the caller's.
--
-- A lit grill settles where it had got to, so a pickup is never a way to dodge a burn nor to lose a cook.
--
-- @param fromPickup Taken down with the pickup tool rather than by hand. The skewer goes quietly to the
-- backpack so a base can be cleared in one go, and a toast says so since no tool appears in their hand.
-- @param stoppedAt The ping-compensated server time the player acted at, read by the caller before
-- anything yields. Only the hand take passes one -- a pickup isn't a timing call, so it settles at now.
-- @return Whether the hand-back may go ahead. False only when this player is already settling this cook
-- from the other entry point: that settle would write the record back under a uid this caller has taken
-- away, stranding it.
function GrillerManager:ReturnContentsToPlayer(
	player: Player,
	data,
	uid: string,
	record,
	fromPickup: boolean?,
	stoppedAt: number?
): boolean
	local settled = record
	local cookState

	if record.Cooking then
		-- A pickup reads its own, since nothing upstream of it was timing anything.
		local settledAt = stoppedAt
			or (workspace:GetServerTimeNow() - math.min(player:GetNetworkPing(), MAX_STOP_COMPENSATION))

		-- Held through the whole hand-back: AddFilledStick yields, and the caller only clears Grillers[uid]
		-- afterwards, so the other entry point slipping into that gap would settle the same cook twice and
		-- write it back.
		if self._stopping[player] then
			return false
		end
		self._stopping[player] = true

		settled, cookState = self:SettleCookRecord(data, uid, record, settledAt)

		-- Elapsed is real, unwarped seconds. A hand take is the player's timing call and reads as one; only
		-- a griller taken down out from under a cook is incidental.
		self:RecordCookResult(
			player,
			cookState,
			settledAt - record.CookStartedAt,
			if fromPickup then "PickedUp" else "Timed"
		)
	end

	StickManager:AddFilledStick(player, {
		StickId = settled.StickId,
		Ingredients = table.clone(settled.Ingredients),
		Cooked = settled.Cooked,
		CookState = settled.CookState,
		CookProgress = settled.CookProgress,
		Mutation = settled.Mutation,
	}, fromPickup)

	-- Only dropped on the branch that took it -- clearing flat would release a lock a concurrent settle holds.
	if cookState then
		self._stopping[player] = nil
	end

	-- Skipped after a settle: RecordCookResult has already toasted the verdict, which says more than this.
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

-- How many times longer this player's perfect window runs, from their next cook on. Nothing else about
-- the bar changes, so a stretch buys reaction room and nothing else. Nil or 1 restores the normal bar.
-- Set while a player is being taught the timing rather than tested on it.
function GrillerManager:SetCookWindowStretch(player: Player, stretch: number?)
	self._cookWindowStretch[player] = if stretch and stretch > 1 then stretch else nil
end

-- Raises the Robux prompt for skipping a cook. Which grill is remembered here rather than carried on the
-- product, since the receipt arrives with nothing on it but the buyer.
function GrillerManager:PromptSkipCookProduct(player: Player, uid: string)
	if not validatePlayer(player) then
		return
	end

	-- A button rather than a hold prompt, so nothing else slows a mashed one down. Held across the read
	-- below too, or two requests either side of the yield would both write _pendingSkipCookUid.
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

	-- The client only shows the button during a cook, so this holds the remote to that rather than
	-- covering a case a player can walk into.
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

-- Settles a bought-out cook as perfect, on the grill the prompt was raised from (fired by ShopManager).
--
-- A receipt Roblox never got an answer for is re-processed on a later join, with no pending griller to
-- read -- so that case falls back to whatever is on a grill rather than dropping a paid purchase.
function GrillerManager:GrantSkipCookFromProduct(player: Player)
	local uid = self._pendingSkipCookUid[player]
	self._pendingSkipCookUid[player] = nil

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- Read back rather than trusted: the prompt and its answer can be minutes apart, and the cook can be
	-- stopped by hand in between.
	local record = if uid then data.Grillers[uid] else nil
	if record and record.Cooked then
		record = nil
	end

	if not record then
		uid = nil

		-- Their own grillers only: a record can outlive its structure if a removal half lands, and spending
		-- a receipt on one of those would put a BBQ somewhere nothing can reach.
		for candidateUid, candidate in data.Grillers do
			if candidate.Cooked or not self:OwnsGrillerStructure(data, candidateUid) then
				continue
			end

			-- A running cook is what they were buying out of, so it wins outright over an unlit BBQ.
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
		-- Cleared, not carried: the skip takes the cook past the raw band, and that's what consumes a bank.
		CookProgress = nil,
		-- Stamped off the grill it settled on, as a hand-stopped cook is. Unconditional, unlike the stop's,
		-- since a skip always lands past the raw band.
		Mutation = self:GetGrillerMutation(data, uid),
	})

	-- Real seconds actually spent on the heat -- none at all on a BBQ that was never lit. Ends on the same
	-- toast a hand-timed window gets: what the player bought is that result.
	self:RecordCookResult(
		player,
		SKIP_COOK_STATE,
		if record.CookStartedAt then workspace:GetServerTimeNow() - record.CookStartedAt else 0,
		"Skipped"
	)
end

-- Returns the griller record that puts `record`'s skewer on the heat: its whole cook worked out from the
-- ingredients and the grill under them, stamped so nothing has to be recomputed while it runs. Takes any
-- record carrying StickId / Ingredients / CookProgress, so a filled stick going down and a stale one being
-- picked back up both light the same way. Paired with SettleCookRecord, which ends what this starts.
--
-- The whole bar, not the wait until done: dividing by RAW_END puts the raw -> cooked boundary exactly on
-- the ingredient's CookTime. CookSpeed divides the whole bar rather than one band, which is what makes
-- speed a trade -- a fast grill's perfect window is that many times shorter in real seconds. The burn past
-- the end is wall-clock seconds in the config, so every grill gives the same time to notice.
function GrillerManager:StartCookRecord(player: Player, data, uid: string, record)
	local structure = self:GetGrillerStructure(data, uid)

	local cookTime = Ingredients.GetTotalCookTime(record.Ingredients)
		/ CookStates.RAW_END
		/ (structure and structure.CookSpeed or 1)

	-- A skewer whose ingredients add up to no cook still goes down, just unlit; the take hands it back.
	local cooking = cookTime > 0

	return {
		StickId = record.StickId,
		Ingredients = table.clone(record.Ingredients),
		-- Stamped onto the cook rather than read at the take, like CookTime: the run must bend the same way
		-- from first frame to last, so a stretch lifted mid-cook (finishing the tutorial) keeps the bar it
		-- started on, and CookStartedAt stays honest so the spin still ramps from standstill.
		Cooking = if cooking then true else nil,
		CookStartedAt = if cooking then workspace:GetServerTimeNow() else nil,
		CookTime = if cooking then cookTime else nil,
		CookWindowStretch = if cooking then self._cookWindowStretch[player] else nil,
		-- Carried in, so a skewer pulled off raw picks its banked progress back up on the next grill.
		CookProgress = record.CookProgress,
		-- Stamped off the grill it was set down on, like CookTime, so a rejoin picks up the bar that was left
		-- and a retuned config doesn't move a running cook. The phase is rolled per cook so the surges don't
		-- land on the same places every time; rolled here and replicated rather than derived from
		-- CookStartedAt, which would tie a gameplay curve to a timestamp's low bits.
		CookInstability = if cooking then structure and structure.CookInstability else nil,
		CookInstabilityPhase = if cooking and structure and structure.CookInstability
			then RandomUtil.GetRandomFromMinMax(0, 2 * math.pi)
			else nil,
	}
end

-- Works out where a cook had got to and returns the record it settles into, without writing it. Shared by
-- the take and by a griller picked up mid-cook, so both land on the same state for the same moment;
-- returned rather than written because one goes into the backpack and the other stays on the grill.
--
-- @param stoppedAt The ping-compensated server time the cook ended at, read by the caller before anything
-- yields -- the correction is only worth anything against the moment the player acted.
-- @return the settled record, and the CookStates id it settled on
function GrillerManager:SettleCookRecord(data, uid: string, record, stoppedAt: number)
	-- Warped *after* the ping compensation, which is in real seconds -- it's the corrected moment that has
	-- to be read against the bar the player was watching. CookProgress and the instability pair go in too,
	-- so a resumed cook reads against its whole bar and an unstable grill settles on the one actually drawn.
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
		-- Cooked is the plain "has been through a grill" flag the sauce dispenser gates on; CookState says
		-- how it went. A raw pull carries neither, so it's indistinguishable from one never lit -- still
		-- re-cookable, still sellable for almost nothing (StickModel.GetCookStateId reads the pair back).
		Cooked = if raw then nil else true,
		CookState = if raw then nil else state,
		-- Except for how far it got, banked as a fraction of the bar so it means the same on whatever grill
		-- it's picked back up on. Being raw bounds it under RAW_END; getting past that band consumes it.
		CookProgress = if raw then elapsed / record.CookTime else nil,
		-- Off the grill it cooked on, so a BBQ is only mutated by the grill it was actually cooked on. Nil
		-- on a raw pull, or a player could light a Golden Grill for a second, pull raw, and finish on a
		-- plain grill still carrying the multiplier.
		Mutation = if raw then nil else self:GetGrillerMutation(data, uid),
	}, state
end

-- Counts a finished cook and gives the player the verdict. Every cook counts, raw pulls included, so
-- SkewersCooked always comes to the sum of CookStateCounts -- shared by all three ways a cook can end,
-- which is what keeps that true.
--
-- @param elapsed Real, unwarped seconds this skewer spent on the heat -- not where it landed on the bar.
-- @param method "Timed", "Skipped" or "PickedUp" -- see the comment on OnCookCompleted.
function GrillerManager:RecordCookResult(player: Player, stateId: string, elapsed: number, method: string)
	StatsManager:RecordCookCompleted(player, stateId)
	self.OnCookCompleted:Fire(player, stateId, elapsed, method)

	-- Written next to the state it belongs to rather than spelled out here. Every state carries one,
	-- including a raw pull -- what it says is that the cook was banked, which the bar can't show.
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

-- Banks how long every running cook had been on the heat, so the time the player is away doesn't advance it.
-- Only the elapsed is kept -- the clock itself is restamped off it by ResumePausedCooks when they come back.
--
-- A pre-cleanup callback because that's the one hook covering every way a session ends (leaving, shutdown,
-- session handover), where _cleanupPlayer covers only the first.
--
-- Mutates `data` directly and never yields, as the hook requires: the player may already be gone from
-- Players, which SetPlayerDataKey needs.
function GrillerManager:PauseCooksOnLastSave(data)
	for _, record in data.Grillers do
		-- Already carrying one means the cook was paused and never resumed -- they left again before their
		-- grillers bound -- so CookStartedAt is stale and recomputing would bank the gap they were away for.
		if not record.Cooking or record.CookPausedElapsed then
			continue
		end

		record.CookPausedElapsed = math.max(0, workspace:GetServerTimeNow() - record.CookStartedAt)
	end
end

-- Restarts the clock on every cook that was frozen when the player last left, putting the bar back exactly
-- where they stopped watching it. Rewinding the stamp is the whole resume: CookStartedAt is the only input
-- the settle, the bar, the browning and the spin all derive from.
--
-- Also starts anything found sitting on a grate unlit. Lighting used to be its own press, so data from
-- before that merged is full of skewers that were put down and never lit -- and nothing would ever cook
-- them now. Started here rather than migrated once, because this is the hook that already sees every
-- griller a returning player owns. A settled skewer waiting to be collected is left alone.
function GrillerManager:ResumePausedCooks(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	for uid, record in data.Grillers do
		if not record.Cooking then
			-- Carries CookProgress, so one that was pulled off raw resumes the bar it banked rather than
			-- starting over. Stamped from now: the player wasn't watching the time they were away.
			if not record.Cooked then
				PlayerDataManager:SetPlayerDataKey(
					player,
					{ "Grillers", uid },
					self:StartCookRecord(player, data, uid, record)
				)
			end

			continue
		end

		-- No bank on a running cook means the session ended without its last save (a crash), so the leg it
		-- was on is unknowable -- restart that leg rather than settle against a stamp from another session.
		PlayerDataManager:SetPlayerDataKey(player, { "Grillers", uid }, {
			StickId = record.StickId,
			Ingredients = table.clone(record.Ingredients),
			Cooking = true,
			CookStartedAt = workspace:GetServerTimeNow() - (record.CookPausedElapsed or 0),
			CookTime = record.CookTime,
			CookWindowStretch = record.CookWindowStretch,
			CookProgress = record.CookProgress,
			CookInstability = record.CookInstability,
			CookInstabilityPhase = record.CookInstabilityPhase,
		})
	end
end

-- Registers the player's data listener and picks their paused cooks back up. Guarded so two grillers bound
-- in one frame can't set them up twice.
function GrillerManager:_setupPlayer(player: Player)
	if self._listeners[player] then
		return
	end

	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "Grillers", function()
		self:_renderGrills(player)
	end)

	-- After the listener, so the restamped records render themselves. The guard above is set before this
	-- yields, so a second griller binding meanwhile still can't run it twice.
	self:ResumePausedCooks(player)
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
	-- Any placed griller wires itself up here, so nothing has to be told about one built mid-session.
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

	self.RequestSkipCookEvent:OnServerEvent(function(player: Player, uid: string)
		self:PromptSkipCookProduct(player, uid)
	end)

	PlayerDataManager:RegisterPreCleanupCallback(function(_, data)
		self:PauseCooksOnLastSave(data)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)
end

return GrillerManager
