-- Sauce dispensers are postponed to a future update: the models are out of the workspace, so the whole
-- manager is dormant. Everything below is intact -- un-comment it (and the rest of the sauce system:
-- SauceToolManager, SauceDispenserController, Shared.Config.Sauces / SauceDispenser, the BaseUnlocks
-- entry and DebugUpgradeController's rows) to bring it back.

--[==[
-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local SauceDispenser = require(Shared.Config.SauceDispenser)
local Sauces = require(Shared.Config.Sauces)
local BaseUnlocks = require(Shared.Config.BaseUnlocks)

--
local PlayerDataManager
local CurrencyManager
local NotificationManager
local BaseManager
local StickManager
local SauceToolManager
local StatsManager

--[[
    Renders each player's sauce dispensers into their base and drives their size upgrades.

    A dispenser exists once its base's SauceDispenser unlock is bought (Base:ApplyUnlocks handles the
    locked/ghosted visual). On unlock a per-dispenser record is created at the default size; from
    there it upgrades Small -> Medium -> Large -> Huge, each size swapping the model shown on the
    slot's SpawnPart.

    A dispenser also sauces skewers, the same shape the griller cooks them in: the player puts a cooked
    skewer on the slot's Plate.StickAttachment (ToggleSauceSkewer), clicks the bottle (StartSaucing),
    and SAUCE_DURATION later the sauce lands on the skewer and one of the dispenser's Remaining is
    spent. The sauce rides on the skewer's record from there -- multiplying what it sells for, tagging
    its inventory label, and putting its particles on every ingredient wherever the skewer is drawn.

    Player data is the source of truth: data.SauceDispensers[slotId] = { Size, Sauce?, Remaining,
    Skewer? }, where Skewer is the record sitting on the plate. While it's being sauced the record also
    carries Saucing = true and SauceStartedAt = workspace:GetServerTimeNow(), so an interrupted
    application still finishes across a rejoin -- the same synced clock the griller stamps its cooks
    with. Rendering happens on the server -- like Base's unlock render and GrillerManager --
    because owner-only data doesn't replicate to visitors, but the models the server clones in do.

    The bottle's animation is NOT rendered here: the server just mirrors the record onto the slot's
    replicated attributes, and every client's SauceDispenserController plays the bottle's lift/tilt/pour
    off the Saucing edge, so the motion is smooth and local instead of replicated per frame.

    Which sauce a dispenser holds comes from the player: a fresh record has no Sauce, so it dispenses
    nothing until a sauce bottle is used on it (RefillSauceDispenser), which loads the flavor and fills
    it to its size's capacity. The bottles themselves are SauceToolManager's.
]]

-- How see-through the preview of the next size up is. Applied as a floor, never a set, so a part the
-- place file authored invisible doesn't fade *into* view. Lived on Config.BaseUnlocks while grillers
-- were a Ghost unlock and shared it; this is the only reader left.
local GHOST_TRANSPARENCY = 0.7

--
local SauceDispenserManager = {
	-- The size upgrade is driven by the dispenser's size sign (the unlock by BaseManager's generic
	-- PurchaseUnlockUpgrade); the rest are driven by the dispenser's own prompts and bottle click.
	UpgradeSizeEvent = Network.Event("UpgradeSauceDispenserSize"),
	ToggleSkewerEvent = Network.Event("ToggleSauceSkewer"),
	StartSaucingEvent = Network.Event("StartSaucing"),
	RefillDispenserEvent = Network.Event("RefillSauceDispenser"),
	FillDispenserEvent = Network.Event("FillSauceDispenser"),

	_bottles = {}, -- [player] = { [slotId] = Model }, the size models we've cloned in
	_skewers = {}, -- [player] = { [slotId] = Model }, the skewers we've cloned onto the plates
	_listeners = {}, -- [player] = { unlocks = conn, sauce = conn }
	_purchasing = {}, -- [player] = true, held across the CanAfford -> DeductCurrency window
	_toggling = {}, -- [player] = true across ToggleSauceSkewer's read -> write window
	_saucing = {}, -- [player] = true across StartSaucing's read -> write window
	_refilling = {}, -- [player] = true across RefillSauceDispenser's read -> write window
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Creates a default record for every dispenser slot the player owns but hasn't got one for yet, so a
-- freshly-unlocked dispenser starts at the default size, empty. The write re-renders through the listener.
function SauceDispenserManager:_ensureRecords(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- A dispenser is loaded and filled in one go (a sauce bottle used on it), so it comes out of the
	-- unlock with nothing in it -- no sauce and no level to render. The unlock level is how many
	-- dispenser slots this base has bought.
	local level = data.Unlocks.SauceDispenser or 0
	for slotNumber = 1, level do
		local slotId = tostring(slotNumber)
		if not data.SauceDispensers[slotId] then
			PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId }, {
				Size = SauceDispenser.DEFAULT_SIZE,
				Remaining = 0,
			})
		end
	end
end

-- Mirrors a dispenser's record onto the slot's replicated attributes. The client reads these to drive
-- its prompt, its bottle click, the pour animation it plays (the Saucing edge kicks it off) and the
-- size sign (DispenserSize is the current size the sign shows and prices the next one off). DispenserSauce
-- / SauceRemaining are what say the bottle has anything to give, and SkewerSauce whether the skewer on
-- the plate has already been done. A nil record clears the slot.
function SauceDispenserManager:_writeSlotAttributes(slot: Instance, record)
	local skewer = record and record.Skewer

	slot:SetAttribute("DispenserSize", if record then record.Size else nil)
	slot:SetAttribute("DispenserSauce", if record then record.Sauce else nil)
	slot:SetAttribute("SauceRemaining", if record then record.Remaining else nil)
	slot:SetAttribute("PlacedStickId", if skewer then skewer.StickId else nil)
	slot:SetAttribute("SkewerSauce", if skewer then skewer.Sauce else nil)
	slot:SetAttribute("Saucing", if record and record.Saucing then true else nil)
	slot:SetAttribute("SauceStartedAt", if record then record.SauceStartedAt else nil)
end

-- Brings the skewer model on a slot's plate in line with its record: the placed skewer sits on the
-- plate's StickAttachment, and an empty dispenser has nothing on it. The signature attribute is what
-- keeps an unrelated write (a Remaining tick, a size upgrade) from rebuilding an unchanged skewer.
function SauceDispenserManager:_renderSkewer(player: Player, slot: Instance, record)
	local skewers = self._skewers[player]
	if not skewers then
		skewers = {}
		self._skewers[player] = skewers
	end

	local slotId = slot.Name
	local existing = skewers[slotId]
	local skewer = record and record.Skewer

	if not skewer then
		if existing then
			existing:Destroy()
			skewers[slotId] = nil
		end
		return
	end

	-- Everything about the skewer that changes what it looks like -- so the sauce landing on it at the
	-- end of a pour rebuilds it (and its new particles show), and nothing else does.
	local signature = `{skewer.StickId}|{table.concat(skewer.Ingredients, ",")}|{skewer.Sauce or ""}`
	if existing and existing:GetAttribute("Signature") == signature then
		return
	end

	local model = StickManager:BuildPlacedStickModel(skewer)
	if not model then
		return
	end

	-- The plate and its attachment live in the place file, so a missing one is a real failure case
	-- rather than something the code guarantees. Searched rather than read off a fixed path, since the
	-- plate is a model and the attachment sits on the mesh inside it.
	local plate = slot:FindFirstChild("Plate")
	local attachment = plate and plate:FindFirstChild("StickAttachment", true)
	if not attachment then
		warn(`[SauceDispenser] slot {slotId} has no StickAttachment under its Plate, its skewer won't render`)
		model:Destroy()
		return
	end

	if existing then
		existing:Destroy()
	end

	-- A fixed name is the client's handle on the skewer, matching the griller's.
	model.Name = "Skewer"
	model:SetAttribute("Signature", signature)
	model:PivotTo(attachment.WorldCFrame)
	model.Parent = slot
	skewers[slotId] = model
end

-- Brings the models on the player's base in line with their dispenser records: the right size model
-- sits on each unlocked slot's SpawnPart, a ghosted preview sits on the next slot up for purchase,
-- and nothing sits on the rest. Each owned slot also gets its placed skewer and its attributes.
function SauceDispenserManager:_renderDispensers(player: Player)
	local baseId = player:GetAttribute("BaseId")
	if not baseId then
		return
	end

	local baseModel = workspace.Base:FindFirstChild(baseId)
	if not baseModel then
		return
	end

	local interactables = baseModel:FindFirstChild("Interactables")
	local dispenserFolder = interactables and interactables:FindFirstChild("SauceDispenser")
	if not dispenserFolder then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local level = data.Unlocks.SauceDispenser or 0
	local records = data.SauceDispensers
	local unlock = BaseUnlocks.GetUnlockFromId("SauceDispenser")

	local bottles = self._bottles[player]
	if not bottles then
		bottles = {}
		self._bottles[player] = bottles
	end

	for _, slot in dispenserFolder:GetChildren() do
		-- Anything in the folder that isn't a numbered slot isn't ours to drive.
		local slotNumber = tonumber(slot.Name)
		if not slotNumber then
			continue
		end

		local slotId = slot.Name
		local record = records[slotId]

		-- What this slot should show:
		--  * an owned dispenser  -> its real (solid) size model
		--  * the next slot up for purchase -> a ghosted preview of a fresh (default-size) dispenser,
		--    so the player can see what they'd get, matching the Ghost lock Base fades around it
		--  * anything further out -> nothing
		local isUnlocked = slotNumber <= level and record ~= nil
		local isPreview = not isUnlocked and slotNumber == level + 1 and unlock.Costs[slotNumber] ~= nil

		-- Only an owned dispenser has a record to act on -- a preview is a picture of one.
		local owned = if isUnlocked then record else nil

		self:_renderBottle(baseId, slot, bottles, isUnlocked or isPreview, isPreview, owned)
		self:_renderSkewer(player, slot, owned)
		self:_writeSlotAttributes(slot, owned)
	end
end

-- Puts the right bottle model on a slot's SpawnPart: the record's size when it's owned, a ghosted
-- default-size preview when it's the next one up for purchase, and nothing when it's neither.
function SauceDispenserManager:_renderBottle(
	baseId: string,
	slot: Instance,
	bottles: { [string]: Model },
	shown: boolean,
	isPreview: boolean,
	record
)
	local slotId = slot.Name
	local existing = bottles[slotId]

	if not shown then
		if existing then
			existing:Destroy()
			bottles[slotId] = nil
		end
		return
	end

	local sizeId = if record then record.Size else SauceDispenser.DEFAULT_SIZE

	-- Already showing the right thing: leave it, so an unrelated data write doesn't flicker it -- and,
	-- more to the point, doesn't yank the bottle back to rest mid-pour.
	if existing and existing:GetAttribute("Size") == sizeId and existing:GetAttribute("Ghosted") == isPreview then
		return
	end

	-- Data can hold a size the config no longer has.
	local size = SauceDispenser.GetSizeFromId(sizeId)
	if not size then
		return
	end

	-- The slot's parts live in the place file, not this repo, so a missing SpawnPart is a real
	-- failure case rather than something the code guarantees.
	local spawnPart = slot:FindFirstChild("SpawnPart")
	if not spawnPart then
		warn(`[SauceDispenser] {baseId} slot {slotId} has no SpawnPart, its bottle won't render`)
		return
	end

	if existing then
		existing:Destroy()
	end

	local model = size.Model:Clone()
	model:PivotTo(spawnPart.CFrame)
	model:SetAttribute("Size", size.Id)
	model:SetAttribute("Ghosted", isPreview)

	-- A fixed name is the client's handle on the bottle it animates, matching the skewer's.
	model.Name = "Bottle"

	-- Anchored so the client can pivot it through the pour without physics fighting it. Collidable so
	-- it reads as solid scenery, like the rest of the dispenser.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = true
		end
	end

	-- Locked-but-next: fade it so it reads as a preview, the same way Base ghosts the slot frame
	-- around it.
	if isPreview then
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Transparency = math.max(descendant.Transparency, GHOST_TRANSPARENCY)
			end
		end
	end

	model.Parent = slot
	bottles[slotId] = model
end

-- Registers the player's data listeners and does the first render. Guarded so the base-assigned
-- signal and the OnStart sweep can't set the same player up twice.
function SauceDispenserManager:_setupPlayer(player: Player)
	if self._listeners[player] then
		return
	end

	-- A new unlock level means new dispensers to seed and render; a record change (a size upgrade)
	-- just re-renders. Both signals only report the top-level key, so we re-read the whole table.
	self._listeners[player] = {
		unlocks = PlayerDataManager:ListenForChanges(player, "Unlocks", function()
			self:_ensureRecords(player)
			self:_renderDispensers(player)
		end),
		sauce = PlayerDataManager:ListenForChanges(player, "SauceDispensers", function()
			self:_renderDispensers(player)
		end),
	}

	self:_ensureRecords(player)
	self:_renderDispensers(player)
	self:_scheduleSauceCompletions(player)
end

-- Upgrades one dispenser to the next size up, charging the player. Nothing here touches the world:
-- the data write re-renders the base through the listener _setupPlayer registered.
function SauceDispenserManager:UpgradeSauceDispenserSize(player: Player, slotId: string): boolean
	if not validatePlayer(player) then
		return false
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return false
	end

	-- The id comes off a remote, so it can be anything -- a missing record covers a bad or
	-- not-yet-unlocked slot.
	local record = data.SauceDispensers[slotId]
	if not record then
		return false
	end

	local nextSize = SauceDispenser.GetNextSize(record.Size)
	if not nextSize then
		NotificationManager:NotifyNormal(player, {
			Text = "That's already the biggest size!",
			Duration = 3,
			Sound = "Reject",
		})
		return false
	end

	-- CanAfford yields, so without this guard two rapid purchases could both pass the affordability
	-- check before either of them deducts.
	if self._purchasing[player] then
		return false
	end
	self._purchasing[player] = true

	local canAfford = CurrencyManager:CanAfford(player, nextSize.Cost)
	if not canAfford then
		self._purchasing[player] = nil
		NotificationManager:NotifyNormal(player, {
			Text = "You can't afford this upgrade!",
			Effect = "Error",
			Duration = 3,
			Sound = "Reject",
		})
		return false
	end

	CurrencyManager:DeductCurrency(player, nextSize.Cost, "SauceDispenserUpgrade")
	PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "Size" }, nextSize.Id)

	-- A bigger bottle comes full, so the upgrade is worth taking even on a half-empty dispenser.
	PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "Remaining" }, nextSize.Capacity)

	self._purchasing[player] = nil

	NotificationManager:NotifyNormal(player, {
		Text = "Sauce Dispenser Upgraded!",
		Duration = 3,
		Sound = "Upgrade",
		Effect = "Success",
	})

	return true
end

-- Puts the player's equipped cooked skewer on the dispenser's plate, or takes the one sitting there
-- back off. A skewer mid-pour is locked on. The SauceDispensers write re-renders through the listener.
function SauceDispenserManager:ToggleSauceSkewer(player: Player, slotId: string)
	if not validatePlayer(player) then
		return
	end

	-- The read yields, so guard the whole window: without it a spammed prompt could place twice or
	-- place-and-remove off one stale read.
	if self._toggling[player] then
		return
	end
	self._toggling[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._toggling[player] = nil
		return
	end

	-- The id comes off a remote, so it can be anything -- a missing record covers a bad or
	-- not-yet-unlocked slot.
	local record = data.SauceDispensers[slotId]
	if not record then
		self._toggling[player] = nil
		return
	end

	if record.Skewer then
		-- Mid-pour skewers are committed until the bottle's done.
		if record.Saucing then
			self._toggling[player] = nil
			return
		end

		-- Occupied: hand the skewer back as a distinct filled tool, carrying whatever sauce it picked
		-- up here, and clear the plate.
		local skewer = record.Skewer
		StickManager:AddFilledStick(player, {
			StickId = skewer.StickId,
			Ingredients = table.clone(skewer.Ingredients),
			Cooked = skewer.Cooked,
			CookState = skewer.CookState,
			Sauce = skewer.Sauce,
			Mutation = skewer.Mutation,
		}, nil, skewer.Uid)
		PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "Skewer" }, nil)

		self._toggling[player] = nil
		return
	end

	local filled = StickManager:GetEquippedFilledStick(player, data)
	if not filled then
		NotificationManager:NotifyNormal(player, {
			Text = "You need a cooked BBQ to sauce!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		self._toggling[player] = nil
		return
	end

	-- Sauce goes on after the grill, the same order the sell stand expects a skewer in.
	if not filled.Cooked then
		NotificationManager:NotifyNormal(player, {
			Text = "Cook this BBQ first!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		self._toggling[player] = nil
		return
	end

	-- One sauce per skewer -- a second one doesn't replace the first, so there's nothing here for an
	-- already-sauced skewer to gain.
	if filled.Sauce then
		NotificationManager:NotifyNormal(player, {
			Text = "This BBQ already has sauce!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		self._toggling[player] = nil
		return
	end

	PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "Skewer" }, {
		-- Carried across so taking it back hands the same skewer over -- the held estimate is seeded off it.
		Uid = filled.Uid,
		StickId = filled.StickId,
		Ingredients = table.clone(filled.Ingredients),
		Cooked = filled.Cooked,
		CookState = filled.CookState,
		Mutation = filled.Mutation,
	})
	-- The skewer moves from the inventory onto the plate.
	PlayerDataManager:SetPlayerDataKey(player, { "FilledSticks", filled.Uid }, nil)

	self._toggling[player] = nil
end

-- Starts the pour over the skewer on a dispenser's plate: stamps the record so the application
-- survives a rejoin, and schedules the finish SAUCE_DURATION out. The bottle's lift/tilt/pour is the
-- client's, self-timed off the Saucing edge -- the finish just lands the sauce while it's dabbing.
function SauceDispenserManager:StartSaucing(player: Player, slotId: string)
	if not validatePlayer(player) then
		return
	end

	if self._saucing[player] then
		return
	end
	self._saucing[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._saucing[player] = nil
		return
	end

	local record = data.SauceDispensers[slotId]
	if not record then
		self._saucing[player] = nil
		return
	end

	-- A dispenser is only loaded once a sauce bottle has been used on it, so one that's never been
	-- filled is a real state a player can walk up to.
	local sauce = record.Sauce and Sauces.GetSauceFromId(record.Sauce)
	if not sauce then
		NotificationManager:NotifyNormal(player, {
			Text = "This dispenser is empty!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		self._saucing[player] = nil
		return
	end

	if record.Remaining <= 0 then
		NotificationManager:NotifyNormal(player, {
			Text = `This dispenser is out of {sauce.Name}!`,
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		self._saucing[player] = nil
		return
	end

	-- Only an unsauced skewer that's sitting there and isn't already being poured on can be started.
	local skewer = record.Skewer
	if not skewer or skewer.Sauce or record.Saucing then
		self._saucing[player] = nil
		return
	end

	-- Stamp before flipping the flag: each write re-renders, and Saucing is what starts the client's
	-- animation, so it has to be the one that lands with the timestamp already in place. The synced clock
	-- rather than os.time() because a pour is only SAUCE_DURATION long, which os.time()'s whole seconds
	-- are most of -- and because two pours starting in the same second would otherwise share a stamp,
	-- which is what FinishSaucing tells one application from the next by.
	local startedAt = workspace:GetServerTimeNow()
	PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "SauceStartedAt" }, startedAt)
	PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "Saucing" }, true)

	self._saucing[player] = nil

	task.delay(SauceDispenser.SAUCE_DURATION, function()
		self:FinishSaucing(player, slotId, startedAt)
	end)
end

-- Lands the sauce on the plated skewer once the pour's played out, provided the same application is
-- still running. Spending the dispenser's Remaining happens here rather than at the start, so a pour
-- interrupted by the dispenser being emptied out from under it doesn't charge for nothing.
function SauceDispenserManager:FinishSaucing(player: Player, slotId: string, startedAt: number)
	if not validatePlayer(player) then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- The skewer could have been swapped out and a new pour started while we waited; only finish the
	-- one we were timing.
	local record = data.SauceDispensers[slotId]
	if not record or not record.Saucing or record.SauceStartedAt ~= startedAt then
		return
	end

	local sauce = record.Sauce and Sauces.GetSauceFromId(record.Sauce)
	local skewer = record.Skewer

	-- The dispenser could have been emptied, or the skewer swapped, while the pour ran.
	local landed = sauce ~= nil and skewer ~= nil and not skewer.Sauce and record.Remaining > 0

	-- Land the sauce before clearing the pour, so the skewer's particles come in as the bottle settles
	-- rather than a frame after it's already back at rest.
	if landed then
		PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "Skewer", "Sauce" }, sauce.Id)
		PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "Remaining" }, record.Remaining - 1)
		StatsManager:RecordSkewerSauced(player)
	end

	-- Cleared whatever happened above, or the plate stays locked forever on a dispenser that ran dry
	-- mid-application.
	PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "Saucing" }, nil)
	PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "SauceStartedAt" }, nil)

	if landed then
		NotificationManager:NotifyNormal(player, {
			Text = `{sauce.Name} applied!`,
			Duration = 3,
			Effect = "Success",
		})
	end
end

-- Reschedules the finish for any dispenser that was mid-pour when the player left, so an application
-- interrupted by a rejoin still lands rather than leaving the plate locked.
function SauceDispenserManager:_scheduleSauceCompletions(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	for slotId, record in data.SauceDispensers do
		if not record.Saucing then
			continue
		end

		local startedAt = record.SauceStartedAt or 0
		local remaining = SauceDispenser.SAUCE_DURATION - (workspace:GetServerTimeNow() - startedAt)

		if remaining <= 0 then
			self:FinishSaucing(player, slotId, startedAt)
		else
			task.delay(remaining, function()
				self:FinishSaucing(player, slotId, startedAt)
			end)
		end
	end
end

-- Spends the sauce bottle the player is holding on a dispenser, loading it with that flavor and
-- filling it to the brim. A dispenser takes a bottle while it's empty, or while it holds the same
-- flavor and has room -- topping up a full one, or mixing two flavors, is refused rather than eating
-- the bottle. The fill itself is FillDispenser's.
function SauceDispenserManager:RefillSauceDispenser(player: Player, slotId: string)
	if not validatePlayer(player) then
		return
	end

	-- The reads yield, so guard the whole window: without it a spammed prompt could pass the checks
	-- twice off one stale read and spend two bottles on one fill.
	if self._refilling[player] then
		return
	end
	self._refilling[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._refilling[player] = nil
		return
	end

	-- The id comes off a remote, so it can be anything -- a missing record covers a bad or
	-- not-yet-unlocked slot.
	local record = data.SauceDispensers[slotId]
	if not record then
		self._refilling[player] = nil
		return
	end

	local sauceId = SauceToolManager:GetEquippedSauceId(player)
	if not sauceId or (data.Sauces[sauceId] or 0) <= 0 then
		NotificationManager:NotifyNormal(player, {
			Text = "You need a sauce bottle to fill this!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		self._refilling[player] = nil
		return
	end

	-- A skewer mid-pour is drawing off the level this would rewrite, so let it finish first.
	if record.Saucing then
		self._refilling[player] = nil
		return
	end

	-- A skewer carries one sauce, so a dispenser holds one too -- a second flavor would have to throw
	-- the first away, which is never what the player meant. One drained to nothing counts as empty
	-- even though it still names its last flavor, or it would only ever take that one again.
	if record.Sauce and record.Remaining > 0 and record.Sauce ~= sauceId then
		local loaded = Sauces.GetSauceFromId(record.Sauce)
		NotificationManager:NotifyNormal(player, {
			Text = `This dispenser is full of {if loaded then loaded.Name else "another sauce"}!`,
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		self._refilling[player] = nil
		return
	end

	-- Data can hold a size the config no longer has.
	local size = SauceDispenser.GetSizeFromId(record.Size)
	if not size then
		self._refilling[player] = nil
		return
	end

	if record.Sauce and record.Remaining >= size.Capacity then
		NotificationManager:NotifyNormal(player, {
			Text = "This dispenser is already full!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		self._refilling[player] = nil
		return
	end

	SauceToolManager:ConsumeSauce(player, sauceId)
	self:FillDispenser(player, slotId, sauceId)

	self._refilling[player] = nil

	local sauce = Sauces.GetSauceFromId(sauceId)
	NotificationManager:NotifyNormal(player, {
		Text = `{sauce.Name} filled!`,
		Duration = 3,
		Effect = "Success",
	})
end

-- Loads a dispenser with a sauce and fills it to its size's capacity. The write re-renders the base
-- through the listener _setupPlayer registered. Also fired bare off the debug panel, which skips the
-- bottle RefillSauceDispenser spends.
function SauceDispenserManager:FillDispenser(player: Player, slotId: string, sauceId: string)
	if not validatePlayer(player) then
		return
	end

	-- Both ids come off a remote, so neither is trusted.
	local sauce = Sauces.GetSauceFromId(sauceId)
	if not sauce then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local record = data.SauceDispensers[slotId]
	if not record then
		return
	end

	local size = SauceDispenser.GetSizeFromId(record.Size)
	if not size then
		return
	end

	PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "Sauce" }, sauce.Id)
	PlayerDataManager:SetPlayerDataKey(player, { "SauceDispensers", slotId, "Remaining" }, size.Capacity)
end

-- Drops the player's listeners and the models we cloned onto their base.
function SauceDispenserManager:_cleanupPlayer(player: Player)
	local listeners = self._listeners[player]
	if listeners then
		listeners.unlocks:Disconnect()
		listeners.sauce:Disconnect()
		self._listeners[player] = nil
	end

	local bottles = self._bottles[player]
	if bottles then
		for _, model in bottles do
			model:Destroy()
		end
		self._bottles[player] = nil
	end

	local skewers = self._skewers[player]
	if skewers then
		for _, model in skewers do
			model:Destroy()
		end
		self._skewers[player] = nil
	end

	self._purchasing[player] = nil
	self._toggling[player] = nil
	self._saucing[player] = nil
	self._refilling[player] = nil
end

function SauceDispenserManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	NotificationManager = require(script.Parent.NotificationManager)
	BaseManager = require(script.Parent.BaseManager)
	StickManager = require(script.Parent.StickManager)
	StatsManager = require(script.Parent.StatsManager)
	SauceToolManager = require(script.Parent.SauceToolManager)
end

function SauceDispenserManager:OnStart()
	-- The base is what says which dispensers exist and where their SpawnParts are, so set a player
	-- up only once it's been assigned one.
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:_setupPlayer(player)
	end)

	-- A player assigned a base before this manager started won't fire the signal above, so sweep
	-- them. Setting up yields on their data, so keep it off the main thread.
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("BaseId") then
			task.spawn(function()
				self:_setupPlayer(player)
			end)
		end
	end

	self.UpgradeSizeEvent:OnServerEvent(function(player: Player, slotId: string)
		self:UpgradeSauceDispenserSize(player, slotId)
	end)

	self.ToggleSkewerEvent:OnServerEvent(function(player: Player, slotId: string)
		self:ToggleSauceSkewer(player, slotId)
	end)

	self.StartSaucingEvent:OnServerEvent(function(player: Player, slotId: string)
		self:StartSaucing(player, slotId)
	end)

	self.RefillDispenserEvent:OnServerEvent(function(player: Player, slotId: string)
		self:RefillSauceDispenser(player, slotId)
	end)

	self.FillDispenserEvent:OnServerEvent(function(player: Player, slotId: string, sauceId: string)
		self:FillDispenser(player, slotId, sauceId)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)
end

return SauceDispenserManager
]==]

return {}
