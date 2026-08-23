-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Sticks = require(Shared.Config.Sticks)
local Structures = require(Shared.Config.Structures)

--
local PlayerDataManager
local NotificationManager
local StickManager
local IngredientManager

--
local STICK_TOOL_TAG = "StickTool"
local INGREDIENT_TOOL_TAG = "IngredientTool"

-- The structure category stick stands are, which is also the tag every placed one wears. The category
-- and not one model's id, so a second kind of stand added to Config.Structures is picked up here with
-- nothing changed: this manager owns stands, not one particular stand.
local STAND_CATEGORY = "StickStands"

--[[
    Drives the stick stands: placing a stick, loading ingredients onto it, and taking it back off.

    Player data is the source of truth -- data.StickStands[structureUid] = { StickId, Ingredients }.
    One prompt does three things depending on state and what the player holds: place the equipped stick
    on an empty stand, load the equipped ingredient onto a placed stick (up to the stick's Capacity), or
    take the stick off (a loaded stick leaves as a distinct filled tool, an empty one stacks back).
    Placing a filled skewer restores its ingredients. Everything moves through StickManager /
    IngredientManager so inventory tools reconcile.

    Stands are structures the player builds rather than slots authored into their base (see
    Config.Structures), so which ones exist is discovered off the StickStand tag: every placed one is
    bound as it appears and dropped as it goes, keyed by the uid on it -- which is also the key its
    record sits under.

    The only world state this writes is the replicated PlacedStickId / PlacedIngredients attributes on
    each stand -- the client renders the models from those, and it animates the stand itself into place
    on a fresh placement, so the server never holds its real on-screen pose.
]]

--
local StickStandManager = {
	ToggleStickEvent = Network.Event("ToggleStickOnStand"),

	_stands = {}, -- [player] = { [uid] = Model }, every placed stand they own
	_listeners = {}, -- [player] = the StickStands data listener
	_toggling = {}, -- [player] = true across the read -> write window, so a spammed prompt can't double up
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Returns the id of the ingredient tool the player currently has equipped, or nil. An equipped tool
-- sits in the character rather than the backpack, and a character holds at most one.
local function getEquippedIngredientId(player: Player): string?
	local character = player.Character
	if not character then
		return nil
	end

	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:HasTag(INGREDIENT_TOOL_TAG) then
			return child:GetAttribute("IngredientId")
		end
	end

	return nil
end

-- What placing the player's equipped stick would put on a stand, or nil if they aren't holding one.
-- An empty StickTool places a bare stick; a FilledStickTool brings its skewer's ingredients along and
-- is consumed from FilledSticks when placed.
local function getEquippedStickPlacement(player: Player, data)
	local character = player.Character
	if not character then
		return nil
	end

	-- A filled skewer's placement is just the equipped skewer StickManager already resolves, flagged so
	-- the caller knows to consume it from FilledSticks rather than the plain stick count.
	local filled = StickManager:GetEquippedFilledStick(player, data)
	if filled then
		filled.IsFilled = true
		return filled
	end

	for _, child in character:GetChildren() do
		if not child:IsA("Tool") then
			continue
		end

		if child:HasTag(STICK_TOOL_TAG) then
			local stickId = child:GetAttribute("StickId")
			if stickId then
				return { StickId = stickId, Ingredients = {}, IsFilled = false }
			end
		end
	end

	return nil
end

-- Writes each stand clone's PlacedStickId attribute to match the player's records, so the client can
-- render (or clear) the stick sitting on it. Setting nil removes the attribute.
function StickStandManager:_renderStands(player: Player)
	local stands = self._stands[player]
	if not stands then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	for uid, stand in stands do
		-- A record is { StickId, Ingredients }; guard the type so a legacy string-shaped entry (from
		-- before ingredients existed) reads as empty rather than erroring on .Ingredients.
		local record = data.StickStands[uid]
		local isRecord = type(record) == "table"
		stand:SetAttribute("PlacedStickId", if isRecord then record.StickId else nil)
		-- Ingredients replicate as a csv so every client (visitors too) can render them in order.
		stand:SetAttribute("PlacedIngredients", if isRecord then table.concat(record.Ingredients, ",") else nil)
		-- A cooked skewer renders from the cooked models on the stand too.
		stand:SetAttribute("PlacedCooked", if isRecord then record.Cooked or nil else nil)
	end
end

-- Takes on a stand as it's placed, and sets its owner up if this is their first.
function StickStandManager:_bindStand(model: Model)
	local player = Players:GetPlayerByUserId(model:GetAttribute(Structures.OWNER_ATTRIBUTE))

	-- The owner can leave between their base being torn down and this signal being handled.
	if not player then
		return
	end

	local stands = self._stands[player]
	if not stands then
		stands = {}
		self._stands[player] = stands
	end

	stands[model:GetAttribute(Structures.UID_ATTRIBUTE)] = model

	self:_setupPlayer(player)
	self:_renderStands(player)
end

-- Drops a stand as it's taken away. The model itself is the base's to destroy.
function StickStandManager:_unbindStand(model: Model)
	local player = Players:GetPlayerByUserId(model:GetAttribute(Structures.OWNER_ATTRIBUTE))
	if not player or not self._stands[player] then
		return
	end

	self._stands[player][model:GetAttribute(Structures.UID_ATTRIBUTE)] = nil
end

-- Places the player's equipped stick on an empty stand, or takes the placed one back off. The
-- StickStands write re-renders the attribute through the listener; nothing here touches the world.
function StickStandManager:ToggleStickOnStand(player: Player, uid: string)
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

	-- The uid comes off a remote, so it can be anything -- only act on one of their own stands. Read
	-- off their build rather than the world, which proves the structure exists, is a stand, and is
	-- theirs, in one.
	local structure = data.Structures[uid]
	if not structure or not Structures.IsCategory(structure.Type, STAND_CATEGORY) then
		self._toggling[player] = nil
		return
	end

	-- A valid record is a table; a legacy string-shaped entry is treated as empty (and gets overwritten).
	local record = data.StickStands[uid]
	if type(record) ~= "table" then
		record = nil
	end

	if not record then
		-- Empty stand: place whatever stick they're holding (a filled skewer brings its ingredients).
		local placement = getEquippedStickPlacement(player, data)
		if not placement then
			-- Holding an ingredient over an empty stand means they're trying to load it but skipped the
			-- stick -- point them at that rather than the generic "equip a stick" they'd get empty-handed.
			local holdingIngredient = getEquippedIngredientId(player) ~= nil
			NotificationManager:NotifyNormal(player, {
				Text = if holdingIngredient then "Place a stick first!" else "Equip a stick first!",
				Duration = 3,
				Sound = "Reject",
				Effect = "Error",
			})
			self._toggling[player] = nil
			return
		end

		-- A cooked skewer is done -- it stays in the inventory rather than going back on a stand.
		if placement.Cooked then
			NotificationManager:NotifyNormal(player, {
				Text = "This BBQ's already cooked!",
				Duration = 3,
				Sound = "Reject",
				Effect = "Error",
			})
			self._toggling[player] = nil
			return
		end

		-- CookProgress is dropped here rather than carried, and that's the rule and not an oversight: a
		-- stand is where ingredients go on, and a raw one added to a part-cooked skewer means the cook
		-- starts over. Coming back off the stand it's a skewer nobody's ever lit.
		PlayerDataManager:SetPlayerDataKey(player, { "StickStands", uid }, {
			StickId = placement.StickId,
			Ingredients = table.clone(placement.Ingredients),
			Cooked = placement.Cooked,
		})

		if placement.IsFilled then
			-- The filled skewer moves onto the stand, so it leaves the inventory.
			PlayerDataManager:SetPlayerDataKey(player, { "FilledSticks", placement.Uid }, nil)
		else
			StickManager:ConsumeStick(player, placement.StickId)
		end

		self._toggling[player] = nil
		return
	end

	-- Stick on the stand. Holding an ingredient loads it; holding nothing takes the stick off.
	local ingredientId = getEquippedIngredientId(player)
	if ingredientId then
		local stick = Sticks.GetStickFromId(record.StickId)
		local capacity = if stick then stick.Capacity else 0
		if #record.Ingredients >= capacity then
			NotificationManager:NotifyNormal(player, {
				Text = "This BBQ is full!",
				Duration = 3,
				Sound = "Reject",
				Effect = "Error",
			})
			self._toggling[player] = nil
			return
		end

		IngredientManager:ConsumeIngredient(player, ingredientId)

		local ingredients = table.clone(record.Ingredients)
		table.insert(ingredients, ingredientId)
		PlayerDataManager:SetPlayerDataKey(player, { "StickStands", uid, "Ingredients" }, ingredients)

		self._toggling[player] = nil
		return
	end

	-- Not holding an ingredient: take the stick off. With ingredients it's a distinct filled tool
	-- that can't stack; empty, it just stacks back onto the plain stick tool.
	if #record.Ingredients > 0 then
		StickManager:AddFilledStick(player, {
			StickId = record.StickId,
			Ingredients = table.clone(record.Ingredients),
			Cooked = record.Cooked,
			CookState = record.CookState,
		})
	else
		StickManager:GrantStick(player, record.StickId)
	end
	PlayerDataManager:SetPlayerDataKey(player, { "StickStands", uid }, nil)

	self._toggling[player] = nil
end

-- Registers the player's data listener. Guarded so two stands being bound in the same frame can't
-- set the same player up twice.
function StickStandManager:_setupPlayer(player: Player)
	if self._listeners[player] then
		return
	end

	-- The signal only reports the top-level key, so re-render every stand off the whole table.
	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "StickStands", function()
		self:_renderStands(player)
	end)
end

-- Drops the player's listener. The stand models (and their attributes) are Base's to destroy.
function StickStandManager:_cleanupPlayer(player: Player)
	local listener = self._listeners[player]
	if listener then
		listener:Disconnect()
		self._listeners[player] = nil
	end

	self._stands[player] = nil
	self._toggling[player] = nil
end

function StickStandManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	NotificationManager = require(script.Parent.NotificationManager)
	StickManager = require(script.Parent.StickManager)
	IngredientManager = require(script.Parent.IngredientManager)
end

function StickStandManager:OnStart()
	-- A stand placed on any base wires itself up here, so nothing has to be told about it -- not the
	-- base going up on join, and not a player building one mid-session.
	CollectionService:GetInstanceAddedSignal(STAND_CATEGORY):Connect(function(model: Model)
		self:_bindStand(model)
	end)

	CollectionService:GetInstanceRemovedSignal(STAND_CATEGORY):Connect(function(model: Model)
		self:_unbindStand(model)
	end)

	-- Bases assigned before this manager started won't have fired the signal above, so sweep them.
	-- Binding yields on the owner's data, so keep it off the main thread.
	for _, model in CollectionService:GetTagged(STAND_CATEGORY) do
		task.spawn(function()
			self:_bindStand(model)
		end)
	end

	self.ToggleStickEvent:OnServerEvent(function(player: Player, uid: string)
		self:ToggleStickOnStand(player, uid)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)
end

return StickStandManager
