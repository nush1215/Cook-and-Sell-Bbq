-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Managers
local CollisionManager = require(script.Parent.CollisionManager)
local EffectManager = require(script.Parent.EffectManager)

-- Modules
local NpcRig = require(script.Parent.Parent.Modules.NpcRig)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Animations = require(Shared.Animations)
local GuiUtil = require(Shared.GuiUtil)
local EmployeeHut = require(Shared.Config.EmployeeHut)
local Structures = require(Shared.Config.Structures)
local Ingredients = require(Shared.Config.Ingredients)
local Sticks = require(Shared.Config.Sticks)
local Plots = require(Shared.Config.Plots)

-- Assets
local BuilderTemplate = ServerStorage.Assets:FindFirstChild(EmployeeHut.BUILDER_MODEL)

if not BuilderTemplate then
	warn(`ServerStorage.Assets.{EmployeeHut.BUILDER_MODEL} is missing, no hut will show a builder`)
end

--
local PlayerDataManager
local CurrencyManager
local NotificationManager
local BuildManager
local BaseManager
local IngredientManager
local StickManager

--
local STICK_TOOL_TAG = "StickTool"

-- How close a player has to be to see an item fly into someone's hut (studs)
local STORE_EFFECT_MAX_DISTANCE = 200

-- Its own, so two builders picking up their laps in the same frame don't share a sequence
local rng = Random.new()

-- The employee hut's purchases: repairing it, and the slots its workers are equipped into. The repair hands over the hut as a structure, so from then on the build system owns where it sits.
local EmployeeHutManager = {
	RepairHutEvent = Network.Event("RepairHut"),
	PurchaseHutSlotEvent = Network.Event("PurchaseHutSlot"), -- client -> server (slot)
	StoreItemEvent = Network.Event("StoreHutItem"),
	WithdrawItemEvent = Network.Event("WithdrawHutItem"), -- client -> server (hutUid, kind, id)

	-- Carries nothing: opening the repair panel is the whole of what it reports, for the worker funnel
	RepairPanelOpenedEvent = Network.Event("RepairPanelOpened", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 2 },
	}),

	OnRepairPanelOpened = Signal.new(), -- (player)
	OnHutRepairPurchased = Signal.new(), -- (player, cost)
	OnHutSlotPurchased = Signal.new(), -- (player, slot, cost, method); a Robux receipt's cost is 0
	OnHutItemStored = Signal.new(), -- (player, kind, itemId, amount, storeAll?)
	OnHutItemWithdrawn = Signal.new(), -- (player, kind, itemId); an employee taking from the store isn't one

	_purchasing = {}, -- [player] = true, held across the CanAfford -> DeductCurrency window
	_scheduled = {}, -- [player] = the token for the wait on their running repair -- see ScheduleRepair
	_storing = {}, -- [player] = true across a deposit's read -> write window, so a mashed prompt banks once
	_builders = {}, -- [player] = their repair's builder; also the token its lap loop checks it's still the live one
}

-- The equipped plain stick's id, or nil. A filled skewer wears its own tag, so this never matches one.
local function getEquippedStickId(player: Player): string?
	local character = player.Character
	if not character then
		return nil
	end

	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:HasTag(STICK_TOOL_TAG) then
			return child:GetAttribute("StickId")
		end
	end

	return nil
end

-- A stored item's name for a toast, in its own colour. `kind` is "Ingredients" or "Sticks".
local function getColorizedItemName(kind: string, id: string): string
	if kind == "Ingredients" then
		-- Its own colour rather than its tier's, so it reads as that ingredient rather than as a rarity
		local ingredient = Ingredients.GetIngredientFromId(id)
		return if ingredient then GuiUtil.Colorize(ingredient.Name, ingredient.Color) else "Ingredient"
	end

	local stick = Sticks.GetStickFromId(id)
	return if stick then GuiUtil.Colorize(`{stick.Name} Stick`, stick.TextColor) else "Stick"
end

-- Announces that the player opened the hut's repair panel.
function EmployeeHutManager:RecordRepairPanelOpened(player: Player)
	self.OnRepairPanelOpened:Fire(player)
end

-- Repairs the player's hut and hands them the structure, dropped on the marker it was standing on.
function EmployeeHutManager:RepairHut(player: Player): boolean
	if self._purchasing[player] then
		return false
	end
	self._purchasing[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._purchasing[player] = nil
		return false
	end

	-- Both are states the panel already prevents -- an unowned plot never gets past the prompt's refusal, which
	-- points at the plot instead of opening. Reaching them means a forged call, so it's refused without a toast
	if data.HutRepaired or not Plots.IsOwned(EmployeeHut.REQUIRED_PLOT, data.Plots) then
		self._purchasing[player] = nil
		return false
	end

	if not CurrencyManager:CanAfford(player, EmployeeHut.REPAIR_COST) then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = "You can't afford this repair!",
			Effect = "Error",
			Duration = 3,
			Sound = "Reject",
		})
		return false
	end

	CurrencyManager:DeductCurrency(player, EmployeeHut.REPAIR_COST, "HutRepair")

	-- Absolute and on the synced clock, so it runs down offline and a client can count it without a server tick
	PlayerDataManager:SetPlayerDataKey(
		player,
		"HutRepairEndsAt",
		workspace:GetServerTimeNow() + EmployeeHut.REPAIR_DURATION
	)

	self.OnHutRepairPurchased:Fire(player, EmployeeHut.REPAIR_COST)

	self._purchasing[player] = nil

	self:ScheduleRepair(player, EmployeeHut.REPAIR_DURATION)
	self:SpawnRepairBuilder(player)

	NotificationManager:NotifyNormal(player, {
		Text = "Repair started!",
		Duration = 3,
		Sound = "BasePurchase",
		Effect = "Success",
	})

	return true
end

-- Arms the wait for a running repair. Only a nudge -- CompleteRepair re-reads the stamp, so a missed or doubled delay costs nothing.
function EmployeeHutManager:ScheduleRepair(player: Player, delay: number)
	-- A token, not a flag: it answers both "is one armed" and "am I still the one that should fire"
	local token = {}
	self._scheduled[player] = token

	task.delay(delay, function()
		if self._scheduled[player] ~= token then
			return
		end

		self._scheduled[player] = nil
		self:CompleteRepair(player)
	end)
end

-- Finishes a repair whose time is up and hands over the hut. The stamp is the authority here, never the timer that called it.
function EmployeeHutManager:CompleteRepair(player: Player): boolean
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return false
	end

	-- Re-checked rather than trusted, so an early timer or a second call can't hand over a second hut
	if data.HutRepaired or data.HutRepairEndsAt < 0 or workspace:GetServerTimeNow() < data.HutRepairEndsAt then
		return false
	end

	-- Written before the placement below, which is what lifts the reservation holding those cells for it
	PlayerDataManager:SetPlayerDataKey(player, "HutRepaired", true)
	PlayerDataManager:SetPlayerDataKey(player, "HutRepairEndsAt", -1)

	-- Before the placement below, which takes away the broken hut he's been circling
	self:DespawnRepairBuilder(player)

	local placed = self:PlaceHutOnMarker(player)

	NotificationManager:NotifyNormal(player, {
		-- A hut that couldn't be dropped is sitting in their backpack, and saying nothing would read as a lost purchase
		Text = if placed then "Worker Hut Repaired!" else "Worker Hut Repaired! Place it from your backpack",
		Duration = 3,
		Sound = "FinishedRepair",
		Effect = "Success",
	})

	return true
end

-- Picks a repair back up on handover: finishes one whose time passed while they were away, or waits out the rest.
function EmployeeHutManager:ResumeRepair(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	if data.HutRepaired or data.HutRepairEndsAt < 0 then
		return
	end

	-- Time away is already in the stamp, so a past one simply finishes here
	local remaining = data.HutRepairEndsAt - workspace:GetServerTimeNow()
	if remaining <= 0 then
		self:CompleteRepair(player)
		return
	end

	self:ScheduleRepair(player, remaining)
	self:SpawnRepairBuilder(player)
end

-- Drops the repaired hut on the marker it was standing on, so it doesn't jump. Grants it either way -- a refused placement leaves it in their backpack to put down themselves.
function EmployeeHutManager:PlaceHutOnMarker(player: Player): boolean
	BuildManager:GrantStructure(player, EmployeeHut.STRUCTURE_ID)

	local base = BaseManager:GetBaseFromPlayer(player)
	if not base then
		return false
	end

	local cellX, cellZ, rotation = base:GetHutPlacement()
	if not cellX then
		return false
	end

	-- Through the normal path, so it lands with the same checks, uid and drop-in every other structure gets
	return BaseManager:PlaceStructureOnBase(player, EmployeeHut.STRUCTURE_ID, cellX, cellZ, rotation)
end

-- A point on the ring the builder circles, `angle` around the hut he's working.
local function ringPoint(center: Vector3, radius: number, angle: number): Vector3
	return center + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
end

-- Puts a builder on a hut for as long as its repair runs, so the site looks worked on rather than merely counted down.
function EmployeeHutManager:SpawnRepairBuilder(player: Player)
	if not BuilderTemplate or self._builders[player] then
		return
	end

	local base = BaseManager:GetBaseFromPlayer(player)
	local hut = base and base:GetHutModel()
	if not hut then
		return
	end

	-- Measured off the hut's own bounds, so he circles whatever shape it is and stands on the ground it rests on
	local hutCFrame, hutSize = hut:GetBoundingBox()
	local center = Vector3.new(hutCFrame.Position.X, hutCFrame.Position.Y - hutSize.Y / 2, hutCFrame.Position.Z)
	local radius = math.max(hutSize.X, hutSize.Z) / 2 + EmployeeHut.BUILDER_CLEARANCE

	local rig = BuilderTemplate:Clone()

	-- Passes through the hut he's circling, the owner and every other NPC, so nothing can box him in against it
	CollisionManager:SetModelGroup(rig, CollisionManager.NPC)

	-- Whole or not at all: under default mode his parts land on the client piecemeal
	rig.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	-- Worth checking: the template is authored in the place file rather than synced, so it can arrive rigless
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warn(`ServerStorage.Assets.{EmployeeHut.BUILDER_MODEL} has no Humanoid, no hut will show a builder`)
		rig:Destroy()
		return
	end

	local angle = rng:NextNumber(0, math.pi * 2)

	-- Primed while still parked, so he fades in rather than popping
	NpcRig.Fade(rig, true, EmployeeHut.BUILDER_FADE_DURATION)
	rig:PivotTo(CFrame.new(ringPoint(center, radius, angle) + Vector3.new(0, 3, 0)))

	-- Stamped before he lands, so he arrives owned rather than a frame behind it
	rig:SetAttribute(Structures.OWNER_ATTRIBUTE, player.UserId)
	rig.Parent = workspace

	-- Server-driven movement, so the root goes to the server rather than a nearby client
	local rootPart = rig:FindFirstChild("HumanoidRootPart")
	if rootPart and not rootPart.Anchored then
		rootPart:SetNetworkOwner(nil)
	end

	local builder = {
		rig = rig,
		humanoid = humanoid,
		center = center,
		radius = radius,
		angle = angle,
		track = nil, -- the bout he's playing, held here so a despawn can stop it and release the wait on it
	}
	self._builders[player] = builder

	task.spawn(function()
		self:RunBuilderLaps(player, builder)
	end)
end

-- Walks the builder round and round the hut, stopping now and then to face it and work on it. Runs until the record it started with stops being the live one, which is how a finished repair or a leave calls it off.
function EmployeeHutManager:RunBuilderLaps(player: Player, builder)
	while self._builders[player] == builder do
		builder.angle += EmployeeHut.BUILDER_LAP_STEP

		NpcRig.WalkTo(builder.humanoid, ringPoint(builder.center, builder.radius, builder.angle))

		-- A leg yields for as long as it takes to walk, so the repair can have finished under it
		if self._builders[player] ~= builder then
			return
		end

		if rng:NextNumber() >= EmployeeHut.BUILDER_WORK_CHANCE then
			continue
		end

		local pivot = builder.rig:GetPivot()
		local look = (builder.center - pivot.Position) * Vector3.new(1, 0, 1)

		-- Standing dead on the hut's centre leaves no direction to take, and lookAt would throw on a zero vector
		if look.Magnitude < 0.1 then
			continue
		end

		-- Told to stop where he stands first, or the tail of the last MoveTo turns him straight back off the hut
		builder.humanoid:MoveTo(builder.humanoid.RootPart.Position)
		builder.rig:PivotTo(CFrame.lookAt(pivot.Position, pivot.Position + look.Unit))

		-- Swung a few times over rather than once, so he works at the hut instead of tapping it and walking off
		for _ = 1, rng:NextInteger(EmployeeHut.BUILDER_SWINGS_MIN, EmployeeHut.BUILDER_SWINGS_MAX) do
			builder.track = NpcRig.PlayAnimationId(builder.rig, Animations.Builder, "Builder", false)
			if not builder.track then
				break
			end

			builder.track.Stopped:Wait()

			-- A despawn is the other thing that stops the track, and it has already cleaned it up
			if self._builders[player] ~= builder then
				return
			end

			NpcRig.StopAnimationTrack(builder.track)
			builder.track = nil
		end

		task.wait(EmployeeHut.BUILDER_SWING_PAUSE)

		if self._builders[player] ~= builder then
			return
		end
	end
end

-- Takes the builder off a hut, whether the repair finished or the player left. Whatever the laps could be waiting on is released first, so nothing sits parked on a rig that's about to go.
function EmployeeHutManager:DespawnRepairBuilder(player: Player)
	local builder = self._builders[player]
	if not builder then
		return
	end

	-- Cleared first: this is what the lap loop reads to know it's no longer the live one
	self._builders[player] = nil

	-- Both release a wait the loop could be sitting in -- the bout it's playing, and the leg it's walking
	NpcRig.StopAnimationTrack(builder.track)
	builder.humanoid:MoveTo(builder.humanoid.RootPart.Position)

	-- Spawned, since the fade yields and a finished repair has a hut to hand over
	task.spawn(function()
		NpcRig.Fade(builder.rig, false, EmployeeHut.BUILDER_FADE_DURATION)
		builder.rig:Destroy()
	end)
end

-- Puts what they're holding into one hut's store, just the one or the whole stack if `storeAll`. Ingredients and plain sticks only: a built BBQ is the cooker's to carry, not stock.
function EmployeeHutManager:StoreHeldItem(player: Player, uid: string, storeAll: boolean?)
	if self._storing[player] then
		return
	end
	self._storing[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._storing[player] = nil
		return
	end

	-- Read off their build rather than the world, which proves it exists, is a hut, and is theirs. This is
	-- what lets a base carry several huts -- HutRepaired only ever gated the first one's repair
	local structure = data.Structures[uid]
	if not structure or not Structures.IsCategory(structure.Type, EmployeeHut.CATEGORY) then
		self._storing[player] = nil
		return
	end

	-- Checked first: a filled skewer carries the StickTool template but not its tag, so a plain-stick scan
	-- would take a whole built BBQ in as an empty stick
	if StickManager:GetEquippedFilledStick(player, data) then
		NotificationManager:NotifyNormal(player, {
			Text = "Only ingredients and sticks go in here!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		self._storing[player] = nil
		return
	end

	local ingredientId = IngredientManager:GetEquippedIngredientId(player)
	local stickId = if ingredientId then nil else getEquippedStickId(player)

	-- Empty-handed can't reach this: the prompt is disabled without something to put in
	if not ingredientId and not stickId then
		self._storing[player] = nil
		return
	end

	-- The count, not the tool, is the proof they have one. A tool outlives its last unit by however long the
	-- reconcile takes to destroy it, so trusting the tool alone would bank a free item off a fast second press
	local owned = if ingredientId then data.Ingredients[ingredientId] else data.Sticks[stickId]
	if (owned or 0) <= 0 then
		self._storing[player] = nil
		return
	end

	-- The whole owned count rather than the tool's Count, since the count is what's just been proven
	local amount = if storeAll then owned else 1

	-- Made on the first deposit, so an untouched hut has no entry for the pickup path to hand back
	local store = data.HutStorage[uid]
	if not store then
		store = { Ingredients = {}, Sticks = {} }
		PlayerDataManager:SetPlayerDataKey(player, { "HutStorage", uid }, store)
	end

	if ingredientId then
		IngredientManager:ConsumeIngredient(player, ingredientId, amount)
		PlayerDataManager:SetPlayerDataKey(
			player,
			{ "HutStorage", uid, "Ingredients", ingredientId },
			(store.Ingredients[ingredientId] or 0) + amount
		)
	else
		StickManager:ConsumeStick(player, stickId, amount)
		PlayerDataManager:SetPlayerDataKey(
			player,
			{ "HutStorage", uid, "Sticks", stickId },
			(store.Sticks[stickId] or 0) + amount
		)
	end

	local kind = if ingredientId then "Ingredients" else "Sticks"
	local itemId = ingredientId or stickId
	local itemName = getColorizedItemName(kind, itemId)

	self.OnHutItemStored:Fire(player, kind, itemId, amount, storeAll)

	-- A position rather than the hut, which a far-off client may not have streamed in and would receive as nil
	local base = BaseManager:GetBaseFromPlayer(player)
	local hutModel = base and base:GetStructureModel(uid)
	if hutModel then
		local hitbox = hutModel:FindFirstChild(Structures.HITBOX_NAME)
		local attachment = hitbox and hitbox:FindFirstChild(EmployeeHut.STORAGE_INGREDIENT_ATTACHMENT)
		local targetPosition = if attachment then attachment.WorldPosition else hutModel:GetPivot().Position

		EffectManager:RunEffect(
			"All",
			"HutStoreItem",
			{ targetPosition, player, kind, itemId, amount },
			{ MaxDistance = STORE_EFFECT_MAX_DISTANCE }
		)
	end

	-- Said out loud, unlike a stand's: the hut swallows what goes in, so nothing else confirms it landed
	NotificationManager:NotifyNormal(player, {
		Text = if amount > 1 then `Stored {itemName} x{amount}` else `Stored {itemName}`,
		Duration = 3,
		Sound = "Notify",
		Effect = "Success",
	})

	self._storing[player] = nil
end

-- Whether a hut still holds `amount` of something, read without taking it. Lets a maker pick a hut to walk to before it commits to the trip.
function EmployeeHutManager:GetStoredAmount(data, hutUid: string, kind: string, id: string): number
	local store = data.HutStorage[hutUid]
	local shelf = store and store[kind]

	return (shelf and shelf[id]) or 0
end

-- Takes one item out of a hut's store for an employee to carry. `kind` is "Ingredients" or "Sticks". False when the store no longer has it, which is the caller's cue to go and look again.
function EmployeeHutManager:TakeFromStore(player: Player, hutUid: string, kind: string, id: string): boolean
	if self._storing[player] then
		return false
	end
	self._storing[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._storing[player] = nil
		return false
	end

	-- Re-read after the yield rather than trusting the count that chose this trip: the player can have
	-- picked the hut up, or spent the last of it by hand, while the employee was walking over
	local owned = self:GetStoredAmount(data, hutUid, kind, id)
	if owned <= 0 then
		self._storing[player] = nil
		return false
	end

	PlayerDataManager:SetPlayerDataKey(player, { "HutStorage", hutUid, kind, id }, owned - 1)

	self._storing[player] = nil

	return true
end

-- Hands one stored item back to the player's inventory, from the storage panel. Taken out of the store before it's added, so a race can never copy it.
function EmployeeHutManager:WithdrawStoredItem(player: Player, hutUid: string, kind: string, id: string)
	-- Also the whole of the validation: their own store only has Ingredients and Sticks shelves, so a forged uid, kind or id reads 0
	if not self:TakeFromStore(player, hutUid, kind, id) then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- Straight to the count rather than through GrantIngredient, which would record an obtain and equip it
	PlayerDataManager:SetPlayerDataKey(player, { kind, id }, (data[kind][id] or 0) + 1)

	self.OnHutItemWithdrawn:Fire(player, kind, id)

	NotificationManager:NotifyNormal(player, {
		Text = `Took {getColorizedItemName(kind, id)}`,
		Duration = 3,
		Sound = "Notify",
		Effect = "Success",
	})
end

-- Hands a hut's whole store back when it's picked up. Always returns true -- a hut has nothing in flight to interrupt.
function EmployeeHutManager:ReturnContentsToPlayer(player: Player, data, _uid: string, record, fromPickup: boolean?): boolean
	local returned = 0

	-- Written straight to the counts rather than through GrantIngredient: that records an obtain, so handing
	-- a player's own stock back would count every item as newly discovered and inflate their index
	for ingredientId, amount in record.Ingredients or {} do
		if amount > 0 then
			returned += amount
			PlayerDataManager:SetPlayerDataKey(
				player,
				{ "Ingredients", ingredientId },
				(data.Ingredients[ingredientId] or 0) + amount
			)
		end
	end

	for stickId, amount in record.Sticks or {} do
		if amount > 0 then
			returned += amount
			PlayerDataManager:SetPlayerDataKey(player, { "Sticks", stickId }, (data.Sticks[stickId] or 0) + amount)
		end
	end

	if fromPickup and returned > 0 then
		NotificationManager:NotifyNormal(player, {
			Text = `{returned} item(s) returned from the hut`,
			Duration = 3,
			Sound = "Notify",
			Effect = "Success",
		})
	end

	return true
end

-- Unlocks the next hut slot. Slots are bought in order, so the only one on sale is the one after the last unlocked. `skipCurrencyCost` is a Robux receipt's, which is already paid for.
function EmployeeHutManager:PurchaseHutSlot(player: Player, slot: number, skipCurrencyCost: boolean?): boolean
	if self._purchasing[player] then
		if not skipCurrencyCost then
			return false
		end

		-- A paid receipt waits its turn rather than being dropped. Leaving is checked too, so a stranded guard can't spin this past the session
		repeat
			task.wait()
		until not self._purchasing[player] or not player:IsDescendantOf(Players)

		if not player:IsDescendantOf(Players) then
			return false
		end
	end
	self._purchasing[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._purchasing[player] = nil
		return false
	end

	-- A receipt can't be refused, so it takes whichever slot is next by now rather than the one its button showed
	if skipCurrencyCost then
		slot = data.HutSlotsUnlocked + 1
	end

	-- Refused without a toast: the panel only offers the next slot on a repaired hut. A receipt skips the hut, since an early slot is harmless
	local price = EmployeeHut.SLOT_PRICES[slot]
	if not price or slot ~= data.HutSlotsUnlocked + 1 or (not skipCurrencyCost and not data.HutRepaired) then
		self._purchasing[player] = nil

		-- Only a receipt landing with every slot already unlocked gets here, and a paid purchase shouldn't vanish silently
		if skipCurrencyCost then
			warn(`[EmployeeHutManager] {player.Name} bought a hut slot with none left to unlock`)
		end

		return false
	end

	if not skipCurrencyCost then
		if not CurrencyManager:CanAfford(player, price) then
			self._purchasing[player] = nil
			NotificationManager:NotifyNormal(player, {
				Text = "You can't afford this slot!",
				Effect = "Error",
				Duration = 3,
				Sound = "Reject",
			})
			return false
		end

		CurrencyManager:DeductCurrency(player, price, "HutSlot")
	end

	PlayerDataManager:SetPlayerDataKey(player, "HutSlotsUnlocked", slot)

	self.OnHutSlotPurchased:Fire(
		player,
		slot,
		if skipCurrencyCost then 0 else price,
		if skipCurrencyCost then "Robux" else "Currency"
	)

	self._purchasing[player] = nil

	NotificationManager:NotifyNormal(player, {
		Text = "Slot Unlocked!",
		Duration = 3,
		Sound = "BasePurchase",
		Effect = "Success",
	})

	return true
end

function EmployeeHutManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	NotificationManager = require(script.Parent.NotificationManager)
	BuildManager = require(script.Parent.BuildManager)
	BaseManager = require(script.Parent.BaseManager)
	IngredientManager = require(script.Parent.IngredientManager)
	StickManager = require(script.Parent.StickManager)
end

function EmployeeHutManager:OnStart()
	self.RepairHutEvent:OnServerEvent(function(player: Player)
		self:RepairHut(player)
	end)

	self.RepairPanelOpenedEvent:OnServerEvent(function(player: Player)
		self:RecordRepairPanelOpened(player)
	end)

	self.StoreItemEvent:OnServerEvent(function(player: Player, uid: string, storeAll: boolean?)
		-- Compared rather than passed on, since anything can arrive over the remote
		self:StoreHeldItem(player, uid, storeAll == true)
	end)

	self.WithdrawItemEvent:OnServerEvent(function(player: Player, hutUid: string, kind: string, id: string)
		self:WithdrawStoredItem(player, hutUid, kind, id)
	end)

	self.PurchaseHutSlotEvent:OnServerEvent(function(player: Player, slot: number)
		self:PurchaseHutSlot(player, slot)
	end)

	-- Off the handover rather than PlayerAdded, since finishing one has to place a hut on a base they own
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:ResumeRepair(player)
	end)

	-- This manager can load after a player is already on a base, so sweep whoever is here
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:ResumeRepair(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		self:DespawnRepairBuilder(player)

		self._purchasing[player] = nil
		self._scheduled[player] = nil
		self._storing[player] = nil
	end)
end

return EmployeeHutManager
