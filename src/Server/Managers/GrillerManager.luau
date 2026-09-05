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

-- The category, not one model's id, so a second kind of griller is picked up here unchanged
local GRILLER_CATEGORY = "Grillers"

-- Ping taken off a take, so the state they saw is the state they get. Capped against a dropped link
local MAX_STOP_COMPENSATION = 0.25

-- Perfect is the target, not a bonus, so the product sells away timing risk rather than an unreachable state
local SKIP_COOK_STATE = "Perfect"
local SKIP_COOK_PRODUCT = "SkipCook"

-- Placing a filled skewer onto a griller and taking it back off: a timing minigame settled by the player, with data.Grillers as the source of truth.

--
local GrillerManager = {
	ToggleGrillEvent = Network.Event("ToggleGrillStick"),
	RequestSkipCookEvent = Network.Event("RequestSkipCook"),

	-- (player, cookStateId, elapsed, method) on settle; only "Timed" elapsed says how the cook went
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

-- Every field BuildStickModel varies on, as one string. Cook stamps excluded -- they change every light
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

-- Whether a bare stick is equipped, only to pick which advice the rejection gives.
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

-- Whether `uid` names one of the player's own grillers -- a uid is player input, so every entry point goes through here.
function GrillerManager:OwnsGrillerStructure(data, uid: string): boolean
	local structure = data.Structures[uid]
	return structure ~= nil and Structures.IsCategory(structure.Type, GRILLER_CATEGORY)
end

-- The config for the griller at `uid`, so a BBQ is only ever shaped by the grill it was on. Nil when it's gone.
function GrillerManager:GetGrillerStructure(data, uid: string): Structures.Structure?
	local placed = data.Structures[uid]

	return placed and Structures.GetStructureFromId(placed.Type)
end

-- The mutation the griller stamps, rolled here as the cook settles so the roll is the server's and lands once.
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

-- Mirrors a record onto the griller's attributes -- everything the client needs to draw the cook. Nil clears it.
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

-- Brings the models on the player's grillers in line with their records and mirrors each one's state.
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

		-- Identical models are kept and re-stamped, or a write would swap one in under a mid-animation client
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
				-- Name is what the client finds it by; ModelKey is what the reuse check above reads back
				model.Name = "Skewer"
				model:SetAttribute("CookStartedAt", if cooking then record.CookStartedAt else nil)
				model:SetAttribute("ModelKey", skewerModelKey(record))

				-- Whole or not at all -- the take prompt hangs on the skewer's first part, which default mode delivers late
				model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

				-- Seated off where the griller belongs, not where it is -- a fresh one hangs above its cell until the client springs it
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

-- Takes on a griller as it's placed. Re-renders all of them, which costs nothing -- a running cook is left as is.
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

-- Drops a griller as it's taken away. The base destroys the model; this is only the bookkeeping.
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

-- Places and lights the equipped skewer, or takes it back off and settles it. The whole cook is these two presses.
function GrillerManager:ToggleGrillStick(player: Player, uid: string)
	if not validatePlayer(player) then
		return
	end

	-- Read before anything yields, since a take is the stop and subtracting ping is the whole minigame
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
		-- Occupied: settle, hand back and clear. The return only refuses a cook already settling elsewhere
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

		-- Cooked and CookState don't survive on purpose -- what goes down is raw, and Mutation lands on settle
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

-- Hands a griller's skewer back as a tool, settling its cook. Returns false if the other entry point is already settling it.
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

		-- Held through the hand-back, since AddFilledStick yields and the caller clears Grillers[uid] after
		if self._stopping[player] then
			return false
		end
		self._stopping[player] = true

		settled, cookState = self:SettleCookRecord(data, uid, record, settledAt)

		-- Real, unwarped seconds. A hand take is a timing call; a griller taken down out from under a cook isn't
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

-- How many times longer this player's perfect window runs, from their next cook. Nil or 1 is the normal bar.
function GrillerManager:SetCookWindowStretch(player: Player, stretch: number?)
	self._cookWindowStretch[player] = if stretch and stretch > 1 then stretch else nil
end

-- Raises the skip prompt, remembering the grill here since the receipt arrives with only the buyer on it.
function GrillerManager:PromptSkipCookProduct(player: Player, uid: string)
	if not validatePlayer(player) then
		return
	end

	-- A button, not a hold prompt; held across the read below, or two requests would both write the uid
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

	-- Holds the remote to what the client actually offers, rather than covering a case nobody can reach
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

-- Settles a bought-out cook as perfect. An unanswered receipt re-processed later falls back to whatever is on a grill.
function GrillerManager:GrantSkipCookFromProduct(player: Player)
	local uid = self._pendingSkipCookUid[player]
	self._pendingSkipCookUid[player] = nil

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- Read back, not trusted -- the prompt and its answer can be minutes apart, and the cook stoppable between
	local record = if uid then data.Grillers[uid] else nil
	if record and record.Cooked then
		record = nil
	end

	if not record then
		uid = nil

		-- Their own grillers only -- a record can outlive its structure if a removal half lands
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
		-- Stamped off the grill it settled on. Unconditional, unlike the stop's, since a skip always clears raw
		Mutation = self:GetGrillerMutation(data, uid),
	})

	-- Real seconds on the heat, none on a BBQ never lit. Same toast a hand-timed window gets
	self:RecordCookResult(
		player,
		SKIP_COOK_STATE,
		if record.CookStartedAt then workspace:GetServerTimeNow() - record.CookStartedAt else 0,
		"Skipped"
	)
end

-- Builds the record that lights `record`'s skewer, its whole cook stamped up front. Paired with SettleCookRecord.
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
		-- Stamped onto the cook, so a stretch lifted mid-cook keeps the bar the run started on
		Cooking = if cooking then true else nil,
		CookStartedAt = if cooking then workspace:GetServerTimeNow() else nil,
		CookTime = if cooking then cookTime else nil,
		CookWindowStretch = if cooking then self._cookWindowStretch[player] else nil,
		-- Carried in, so a skewer pulled off raw picks its banked progress back up on the next grill.
		CookProgress = record.CookProgress,
		-- Stamped per cook so surges don't repeat, and replicated rather than derived from a timestamp's low bits
		CookInstability = if cooking then structure and structure.CookInstability else nil,
		CookInstabilityPhase = if cooking and structure and structure.CookInstability
			then RandomUtil.GetRandomFromMinMax(0, 2 * math.pi)
			else nil,
	}
end

-- Works out where a cook got to and returns the settled record plus its CookStates id, without writing it.
function GrillerManager:SettleCookRecord(data, uid: string, record, stoppedAt: number)
	-- Warped after the ping correction, so the corrected moment is read against the bar the player watched
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
		-- Cooked says it went through a grill, CookState how it went; a raw pull carries neither
		Cooked = if raw then nil else true,
		CookState = if raw then nil else state,
		-- Banked as a fraction of the bar, so it means the same on whatever grill picks it back up
		CookProgress = if raw then elapsed / record.CookTime else nil,
		-- Nil on a raw pull, or a Golden Grill could be lit for a second and the cook finished on a plain one
		Mutation = if raw then nil else self:GetGrillerMutation(data, uid),
	}, state
end

-- Counts a finished cook and toasts the verdict. Shared by all three endings, so the totals stay in step.
function GrillerManager:RecordCookResult(player: Player, stateId: string, elapsed: number, method: string)
	StatsManager:RecordCookCompleted(player, stateId)
	self.OnCookCompleted:Fire(player, stateId, elapsed, method)

	-- Every state carries one, a raw pull included -- what it says is that the cook was banked
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

-- Banks each running cook's elapsed on the last save, so time away doesn't advance it. Must not yield.
function GrillerManager:PauseCooksOnLastSave(data)
	for _, record in data.Grillers do
		-- Already banked means it was paused and never resumed, so recomputing would bank the gap again
		if not record.Cooking or record.CookPausedElapsed then
			continue
		end

		record.CookPausedElapsed = math.max(0, workspace:GetServerTimeNow() - record.CookStartedAt)
	end
end

-- Restamps every paused cook and lights anything found sitting unlit, which old data is full of.
function GrillerManager:ResumePausedCooks(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	for uid, record in data.Grillers do
		if not record.Cooking then
			-- Carries CookProgress, and stamps from now -- the player wasn't watching the time they were away
			if not record.Cooked then
				PlayerDataManager:SetPlayerDataKey(
					player,
					{ "Grillers", uid },
					self:StartCookRecord(player, data, uid, record)
				)
			end

			continue
		end

		-- No bank means the session ended without its save, so restart the leg rather than settle on a stale stamp
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

-- Registers the player's data listener and resumes their paused cooks, guarded against a double bind.
function GrillerManager:_setupPlayer(player: Player)
	if self._listeners[player] then
		return
	end

	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "Grillers", function()
		self:_renderGrills(player)
	end)

	-- After the listener, so the restamped records render themselves; the guard is set before this yields
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
