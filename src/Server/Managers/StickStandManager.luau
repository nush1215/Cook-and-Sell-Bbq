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

-- The category, not one model's id, so a second kind of stand is picked up here unchanged
local STAND_CATEGORY = "StickStands"

-- Placing a stick on a stand and loading ingredients onto it. Player data is the source of truth; the models render off it.

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

-- The equipped ingredient tool's id, or nil. An equipped tool sits in the character, not the backpack.
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

-- What the equipped stick would put on a stand, or nil. A filled one brings its ingredients and is consumed.
local function getEquippedStickPlacement(player: Player, data)
	local character = player.Character
	if not character then
		return nil
	end

	-- Flagged so the caller consumes it from FilledSticks rather than the plain stick count
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

-- Mirrors the player's stand records onto each clone's attributes so the client can render them.
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
		-- Guarded so a legacy string-shaped entry reads as empty rather than erroring on .Ingredients
		local record = data.StickStands[uid]
		local isRecord = type(record) == "table"
		stand:SetAttribute("PlacedStickId", if isRecord then record.StickId else nil)
		-- Ingredients replicate as a csv so every client, visitors too, can render them in order
		stand:SetAttribute("PlacedIngredients", if isRecord then table.concat(record.Ingredients, ",") else nil)
		-- A cooked skewer renders from the cooked models on the stand too
		stand:SetAttribute("PlacedCooked", if isRecord then record.Cooked or nil else nil)
	end
end

-- Takes on a stand as it's placed, and sets its owner up if this is their first.
function StickStandManager:_bindStand(model: Model)
	local player = Players:GetPlayerByUserId(model:GetAttribute(Structures.OWNER_ATTRIBUTE))

	-- The owner can leave between their base being torn down and this signal being handled
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

-- Places the equipped stick on an empty stand or takes it back off; the data write re-renders it.
function StickStandManager:ToggleStickOnStand(player: Player, uid: string)
	if not validatePlayer(player) then
		return
	end

	-- The read yields, so guard the whole window or a spammed prompt could place twice off one stale read
	if self._toggling[player] then
		return
	end
	self._toggling[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._toggling[player] = nil
		return
	end

	-- Read off their build rather than the world, which proves it exists, is a stand, and is theirs
	local structure = data.Structures[uid]
	if not structure or not Structures.IsCategory(structure.Type, STAND_CATEGORY) then
		self._toggling[player] = nil
		return
	end

	-- A valid record is a table; a legacy string-shaped entry is treated as empty and overwritten
	local record = data.StickStands[uid]
	if type(record) ~= "table" then
		record = nil
	end

	if not record then
		-- Empty stand: place whatever stick they're holding, ingredients and all
		local placement = getEquippedStickPlacement(player, data)
		if not placement then
			-- They skipped the stick, so point them at that rather than the generic empty-handed advice
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

		-- A cooked skewer is done -- it stays in the inventory rather than going back on a stand
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

		-- Dropped, not carried: adding a raw ingredient means the cook starts over
		PlayerDataManager:SetPlayerDataKey(player, { "StickStands", uid }, {
			StickId = placement.StickId,
			Ingredients = table.clone(placement.Ingredients),
			Cooked = placement.Cooked,
		})

		if placement.IsFilled then
			-- The filled skewer moves onto the stand, so it leaves the inventory
			PlayerDataManager:SetPlayerDataKey(player, { "FilledSticks", placement.Uid }, nil)
		else
			StickManager:ConsumeStick(player, placement.StickId)
		end

		self._toggling[player] = nil
		return
	end

	-- Stick on the stand: holding an ingredient loads it, holding nothing takes the stick off
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

	-- Not holding an ingredient: take the stick off
	self:ReturnContentsToPlayer(player, data, uid, record)
	PlayerDataManager:SetPlayerDataKey(player, { "StickStands", uid }, nil)

	self._toggling[player] = nil
end

-- Hands a stand's stick back: a distinct filled tool with ingredients, or stacked back if empty. Always returns true -- a stand has nothing to interrupt.
function StickStandManager:ReturnContentsToPlayer(player: Player, _data, _uid: string, record, fromPickup: boolean?): boolean
	local isFilled = #record.Ingredients > 0

	if isFilled then
		StickManager:AddFilledStick(player, {
			StickId = record.StickId,
			Ingredients = table.clone(record.Ingredients),
			Cooked = record.Cooked,
			CookState = record.CookState,
		}, fromPickup)
	else
		StickManager:GrantStick(player, record.StickId, nil, fromPickup)
	end

	if fromPickup then
		NotificationManager:NotifyNormal(player, {
			Text = if isFilled
				then "BBQ returned to your inventory"
				else "Stick returned to your inventory",
			Duration = 3,
			Sound = "Notify",
			Effect = "Success",
		})
	end

	return true
end

-- Registers the player's data listener, guarded against two stands binding in one frame.
function StickStandManager:_setupPlayer(player: Player)
	if self._listeners[player] then
		return
	end

	-- The signal only reports the top-level key, so re-render every stand off the whole table
	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "StickStands", function()
		self:_renderStands(player)
	end)
end

-- Drops the player's listener. The stand models and their attributes are Base's to destroy.
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
	-- A stand placed on any base wires itself up here, join or mid-session
	CollectionService:GetInstanceAddedSignal(STAND_CATEGORY):Connect(function(model: Model)
		self:_bindStand(model)
	end)

	CollectionService:GetInstanceRemovedSignal(STAND_CATEGORY):Connect(function(model: Model)
		self:_unbindStand(model)
	end)

	-- Sweeps bases assigned before this manager started; binding yields, so keep it off the main thread
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
