-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

--
local PlayerDataManager
local NotificationManager
local BaseManager
local StickManager
local CustomOrderNpcManager

-- The sell stand: what cooked skewers are on display, and the reads customers take them off it with.

--
local SkewerStandManager = {
	-- Max skewers on the sell stand. Public, since SellNpcManager caps against it when handing them back
	MAX_SKEWERS = 6,

	PlaceSkewerEvent = Network.Event("PlaceSkewerOnStand"),
	RemoveSkewerEvent = Network.Event("RemoveSkewerFromStand"),

	-- (player, record, placedCount, heldForOrder) on a place; the sell NPC system listens to send a customer for one not held for a custom order
	OnSkewerPlaced = Signal.new(),

	_listeners = {}, -- [player] = the SkewerStand data listener
	_toggling = {}, -- [player] = true across the read -> write window, so a spammed prompt can't double up
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Mirrors the SkewerStand records onto the stand's attribute as one JSON string, so every client renders them.
function SkewerStandManager:_renderStand(player: Player)
	local baseId = player:GetAttribute("BaseId")
	if not baseId then
		return
	end

	local baseModel = workspace.Base:FindFirstChild(baseId)
	if not baseModel then
		return
	end

	local stalls = baseModel:FindFirstChild("Stalls")
	local sellStall = stalls and stalls:FindFirstChild("SellStall")
	local stand = sellStall and sellStall:FindFirstChild("SkewerStand")
	if not stand then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local records = data.SkewerStand
	stand:SetAttribute("PlacedSkewers", if #records > 0 then HttpService:JSONEncode(records) else nil)
end

-- Places the equipped skewer on the stand, however it cooked. The checks here are the authority.
function SkewerStandManager:PlaceSkewer(player: Player)
	if not validatePlayer(player) then
		return
	end

	-- The read yields, so guard the whole window or a spammed prompt could place twice
	if self._toggling[player] then
		return
	end
	self._toggling[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._toggling[player] = nil
		return
	end

	-- The stand lives on the player's base; no base, nothing to place on
	if not player:GetAttribute("BaseId") then
		self._toggling[player] = nil
		return
	end

	-- Holding nothing can't reach this -- no skewer, no prompt
	local filled = StickManager:GetEquippedFilledStick(player, data)
	if not filled then
		self._toggling[player] = nil
		return
	end

	if not self:PlaceSkewerRecord(player, data, filled) then
		self._toggling[player] = nil
		return
	end

	-- The skewer moves onto the stand, so it leaves the inventory and the held visual with it
	PlayerDataManager:SetPlayerDataKey(player, { "FilledSticks", filled.Uid }, nil)

	self._toggling[player] = nil
end

-- Puts a skewer record on display and calls the customer. Takes the caller's already-awaited `data`, so an employee delivering one reaches the same checks as a player placing one.
function SkewerStandManager:PlaceSkewerRecord(player: Player, data, filled): boolean
	local skewers = data.SkewerStand
	if #skewers >= self.MAX_SKEWERS then
		NotificationManager:NotifyNormal(player, {
			Text = "The stand is full!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return false
	end

	-- Carried as-is, not stamped cooked -- laundering a raw skewer on the way to the stand is the thing to avoid
	local record = {
		-- Carried so taking it back hands the same skewer over -- the held estimate is seeded off it
		Uid = filled.Uid,
		StickId = filled.StickId,
		Ingredients = table.clone(filled.Ingredients),
		Cooked = filled.Cooked,
		CookState = filled.CookState,
		CookProgress = filled.CookProgress,
		Sauce = filled.Sauce,
		Mutation = filled.Mutation,
	}
	local placed = table.clone(skewers)
	table.insert(placed, record)
	PlayerDataManager:SetPlayerDataKey(player, { "SkewerStand" }, placed)

	-- Claimed in the frame it lands, so no customer can reach a BBQ a waiting custom order wants before its own customer does
	local heldForOrder = CustomOrderNpcManager:ClaimStandSkewerForOrder(player, { record })

	-- A skewer is now on display, so a customer should come for it
	self.OnSkewerPlaced:Fire(player, record, #placed, heldForOrder)

	return true
end

-- Takes the skewer at `index` back and hands it over. The index comes off a remote, so it's validated live.
function SkewerStandManager:RemoveSkewer(player: Player, index: number)
	if not validatePlayer(player) or typeof(index) ~= "number" then
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

	local skewers = data.SkewerStand
	index = math.floor(index)
	if index < 1 or index > #skewers then
		-- A customer takes off this same list, so a stale index is a genuine race. No error effect
		NotificationManager:NotifyNormal(player, {
			Text = "A customer just took that one!",
			Duration = 3,
			Sound = "Reject",
		})
		self._toggling[player] = nil
		return
	end

	-- Off the record, not stamped: a raw skewer must come back raw, banked cook progress included
	local record = skewers[index]
	StickManager:AddFilledStick(player, {
		StickId = record.StickId,
		Ingredients = table.clone(record.Ingredients),
		Cooked = record.Cooked,
		CookState = record.CookState,
		CookProgress = record.CookProgress,
		Sauce = record.Sauce,
		Mutation = record.Mutation,
	}, nil, record.Uid)

	local placed = table.clone(skewers)
	table.remove(placed, index)
	PlayerDataManager:SetPlayerDataKey(player, { "SkewerStand" }, placed)

	self._toggling[player] = nil
end

-- How many skewers on the player's stand are up for sale, read without taking anything off it. One held for a custom order isn't.
function SkewerStandManager:GetPlacedSkewerCount(player: Player): number
	if not validatePlayer(player) then
		return 0
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return 0
	end

	local heldUid = CustomOrderNpcManager:GetHeldStandSkewerUid(player)
	local count = 0

	for _, record in data.SkewerStand do
		if heldUid == nil or record.Uid ~= heldUid then
			count += 1
		end
	end

	return count
end

-- Takes a skewer off for a customer, returning a copy: the one with `uid` when named, else the top one not held for a custom order. Hands nothing back to the player.
function SkewerStandManager:TakeSkewer(player: Player, uid: string?)
	if not validatePlayer(player) then
		return nil
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return nil
	end

	local skewers = data.SkewerStand
	local heldUid = CustomOrderNpcManager:GetHeldStandSkewerUid(player)

	-- Top down, so an ordinary customer still takes the newest one it's allowed to
	local index = nil
	for candidate = #skewers, 1, -1 do
		local candidateUid = skewers[candidate].Uid
		local takeable = if uid then candidateUid == uid else (heldUid == nil or candidateUid ~= heldUid)

		if takeable then
			index = candidate
			break
		end
	end

	if not index then
		return nil
	end

	local placed = table.clone(skewers)
	local record = table.remove(placed, index)
	PlayerDataManager:SetPlayerDataKey(player, { "SkewerStand" }, placed)

	return {
		-- Carried so a customer who declines puts the same skewer back rather than a re-minted one
		Uid = record.Uid,
		StickId = record.StickId,
		Ingredients = table.clone(record.Ingredients),
		Cooked = record.Cooked,
		CookState = record.CookState,
		CookProgress = record.CookProgress,
		Sauce = record.Sauce,
		Mutation = record.Mutation,
	}
end

-- Clears the stand for a rich customer, in one read and write so it can't be half-emptied. One held for a custom order stays put.
function SkewerStandManager:TakeAllSkewers(player: Player)
	if not validatePlayer(player) then
		return {}
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return {}
	end

	local heldUid = CustomOrderNpcManager:GetHeldStandSkewerUid(player)
	local taken, kept = {}, {}

	for _, record in data.SkewerStand do
		if heldUid and record.Uid == heldUid then
			table.insert(kept, record)
			continue
		end

		table.insert(taken, {
			Uid = record.Uid,
			StickId = record.StickId,
			Ingredients = table.clone(record.Ingredients),
			Cooked = record.Cooked,
			CookState = record.CookState,
			CookProgress = record.CookProgress,
			Sauce = record.Sauce,
			Mutation = record.Mutation,
		})
	end

	PlayerDataManager:SetPlayerDataKey(player, { "SkewerStand" }, kept)

	return taken
end

-- Puts a taken batch back. Every customer carries an array, so a normal one returns its array of one.
function SkewerStandManager:ReturnSkewers(player: Player, records)
	if not validatePlayer(player) then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local placed = table.clone(data.SkewerStand)
	for _, record in records do
		table.insert(placed, record)
	end
	PlayerDataManager:SetPlayerDataKey(player, { "SkewerStand" }, placed)

	-- Locked the moment it's back, as a freshly placed one is, so the customer sent next can't walk off with it
	CustomOrderNpcManager:ClaimStandSkewerForOrder(player, records)
end

-- Registers the player's data listener and renders, guarded against a double setup.
function SkewerStandManager:_setupPlayer(player: Player)
	if self._listeners[player] then
		return
	end

	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "SkewerStand", function()
		self:_renderStand(player)
	end)

	self:_renderStand(player)
end

-- Drops the player's listener. The stand part and its attribute are Base's to destroy.
function SkewerStandManager:_cleanupPlayer(player: Player)
	local listener = self._listeners[player]
	if listener then
		listener:Disconnect()
		self._listeners[player] = nil
	end

	self._toggling[player] = nil
end

function SkewerStandManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	NotificationManager = require(script.Parent.NotificationManager)
	BaseManager = require(script.Parent.BaseManager)
	StickManager = require(script.Parent.StickManager)
	CustomOrderNpcManager = require(script.Parent.CustomOrderNpcManager)
end

function SkewerStandManager:OnStart()
	-- The base is what says the stand exists, so set a player up only once it's been assigned one
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:_setupPlayer(player)
	end)

	-- Sweeps players assigned a base before this manager started; setting up yields, so keep it off the main thread
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("BaseId") then
			task.spawn(function()
				self:_setupPlayer(player)
			end)
		end
	end

	self.PlaceSkewerEvent:OnServerEvent(function(player: Player)
		self:PlaceSkewer(player)
	end)

	self.RemoveSkewerEvent:OnServerEvent(function(player: Player, index: number)
		self:RemoveSkewer(player, index)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)
end

return SkewerStandManager
