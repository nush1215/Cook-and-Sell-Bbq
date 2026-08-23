-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Sticks = require(Shared.Config.Sticks)

--
local PlayerDataManager
local NotificationManager
local BaseManager
local StickManager
local IngredientManager

--
local STICK_TOOL_TAG = "StickTool"
local INGREDIENT_TOOL_TAG = "IngredientTool"

--[[
    Drives the stick stands: placing a stick, loading ingredients onto it, and taking it back off.

    Player data is the source of truth -- data.StickStands[slotId] = { StickId, Ingredients }. One
    prompt does three things depending on state and what the player holds: place the equipped stick on
    an empty stand, load the equipped ingredient onto a placed stick (up to the stick's Capacity), or
    take the stick off (a loaded stick leaves as a distinct filled tool, an empty one stacks back).
    Placing a filled skewer restores its ingredients. Everything moves through StickManager /
    IngredientManager so inventory tools reconcile.

    The only world state this writes is the replicated PlacedStickId / PlacedIngredients attributes on
    each stand clone -- the client renders the models from those, because the stands are a Layout
    unlock the client animates into place, so the server never holds their real on-screen pose.
]]

--
local StickStandManager = {
	ToggleStickEvent = Network.Event("ToggleStickOnStand"),

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
	local baseId = player:GetAttribute("BaseId")
	if not baseId then
		return
	end

	local baseModel = workspace.Base:FindFirstChild(baseId)
	if not baseModel then
		return
	end

	local interactables = baseModel:FindFirstChild("Interactables")
	local standFolder = interactables and interactables:FindFirstChild("StickStand")
	if not standFolder then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	for _, clone in standFolder:GetChildren() do
		-- Anything in the folder that isn't a numbered stand isn't ours to drive.
		if not tonumber(clone.Name) then
			continue
		end

		-- A record is { StickId, Ingredients }; guard the type so a legacy string-shaped entry (from
		-- before ingredients existed) reads as empty rather than erroring on .Ingredients.
		local record = data.StickStands[clone.Name]
		local isRecord = type(record) == "table"
		clone:SetAttribute("PlacedStickId", if isRecord then record.StickId else nil)
		-- Ingredients replicate as a csv so every client (visitors too) can render them in order.
		clone:SetAttribute("PlacedIngredients", if isRecord then table.concat(record.Ingredients, ",") else nil)
		-- A cooked skewer renders from the cooked models on the stand too.
		clone:SetAttribute("PlacedCooked", if isRecord then record.Cooked or nil else nil)
	end
end

-- Places the player's equipped stick on an empty stand, or takes the placed one back off. The
-- StickStands write re-renders the attribute through the listener; nothing here touches the world.
function StickStandManager:ToggleStickOnStand(player: Player, slotId: string)
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

	-- The id comes off a remote, so it can be anything -- only act on a real, unlocked stand.
	local slotNumber = tonumber(slotId)
	local level = data.Unlocks.StickStand or 0
	if not slotNumber or slotNumber < 1 or slotNumber > level then
		self._toggling[player] = nil
		return
	end

	-- A valid record is a table; a legacy string-shaped entry is treated as empty (and gets overwritten).
	local record = data.StickStands[slotId]
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
		PlayerDataManager:SetPlayerDataKey(player, { "StickStands", slotId }, {
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
		PlayerDataManager:SetPlayerDataKey(player, { "StickStands", slotId, "Ingredients" }, ingredients)

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
	PlayerDataManager:SetPlayerDataKey(player, { "StickStands", slotId }, nil)

	self._toggling[player] = nil
end

-- Registers the player's data listener and does the first render. Guarded so the base-assigned
-- signal and the OnStart sweep can't set the same player up twice.
function StickStandManager:_setupPlayer(player: Player)
	if self._listeners[player] then
		return
	end

	-- The signal only reports the top-level key, so re-render every stand off the whole table.
	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "StickStands", function()
		self:_renderStands(player)
	end)

	self:_renderStands(player)
end

-- Drops the player's listener. The stand clones (and their attributes) are Base's to destroy.
function StickStandManager:_cleanupPlayer(player: Player)
	local listener = self._listeners[player]
	if listener then
		listener:Disconnect()
		self._listeners[player] = nil
	end

	self._toggling[player] = nil
end

function StickStandManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	NotificationManager = require(script.Parent.NotificationManager)
	BaseManager = require(script.Parent.BaseManager)
	StickManager = require(script.Parent.StickManager)
	IngredientManager = require(script.Parent.IngredientManager)
end

function StickStandManager:OnStart()
	-- The base is what says which stands exist, so set a player up only once it's been assigned one.
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

	self.ToggleStickEvent:OnServerEvent(function(player: Player, slotId: string)
		self:ToggleStickOnStand(player, slotId)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)
end

return StickStandManager
