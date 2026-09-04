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

--[[
    Drives the sell stall's SkewerStand: placing the skewer the player is holding onto the stand (the
    stand's place prompt), and taking a specific placed skewer back off (a per-skewer prompt).

    Player data is the source of truth -- data.SkewerStand is an array (max 6) of skewer records
    { StickId, Ingredients, Cooked, CookState, CookProgress, Sauce, Mutation }, in placement order. Placing
    appends the equipped skewer and consumes its filled tool; removing pulls the skewer at a given
    index back as a fresh tool. However it was cooked is carried through both ways untouched -- a raw skewer belongs
    here as much as any other, it just sells for almost nothing. Everything moves through StickManager
    / FilledSticks so inventory tools reconcile.

    The only world state this writes is the replicated PlacedSkewers attribute on the stand part -- the
    client renders the models from it. The list rides on one JSON string because attributes can't hold
    a nested array.
]]

--
local SkewerStandManager = {
	-- Up to this many cooked skewers sit on the sell stand at once. Public because SellNpcManager caps
	-- against it when it hands a customer's skewers back.
	MAX_SKEWERS = 6,

	PlaceSkewerEvent = Network.Event("PlaceSkewerOnStand"),
	RemoveSkewerEvent = Network.Event("RemoveSkewerFromStand"),

	-- Fires (player, record, placedCount) each time a skewer is placed on the stand; the sell NPC system
	-- listens on this to send a customer for it.
	OnSkewerPlaced = Signal.new(),

	_listeners = {}, -- [player] = the SkewerStand data listener
	_toggling = {}, -- [player] = true across the read -> write window, so a spammed prompt can't double up
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- Mirrors the player's SkewerStand records onto the stand part's replicated PlacedSkewers attribute, so
-- every client (visitors too) can render the placed skewers. The whole list rides on one JSON string;
-- an empty stand clears the attribute.
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

-- Places the player's equipped skewer on the stand, however it was cooked -- a raw one goes on the
-- same as any other, it just barely sells. The client only enables the place prompt while they hold
-- an eligible skewer, but the checks here are the authority.
function SkewerStandManager:PlaceSkewer(player: Player)
	if not validatePlayer(player) then
		return
	end

	-- The read yields, so guard the whole window: without it a spammed prompt could place twice.
	if self._toggling[player] then
		return
	end
	self._toggling[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		self._toggling[player] = nil
		return
	end

	-- The stand lives on the player's base; no base, nothing to place on.
	if not player:GetAttribute("BaseId") then
		self._toggling[player] = nil
		return
	end

	-- Holding nothing can't reach this -- no skewer, no prompt.
	local filled = StickManager:GetEquippedFilledStick(player, data)
	if not filled then
		self._toggling[player] = nil
		return
	end

	local skewers = data.SkewerStand
	if #skewers >= self.MAX_SKEWERS then
		NotificationManager:NotifyNormal(player, {
			Text = "The stand is full!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		self._toggling[player] = nil
		return
	end

	-- Carried across as-is rather than stamped cooked: a raw skewer sells for almost nothing, and
	-- laundering it into a cooked one on the way to the stand is exactly what that has to avoid.
	local record = {
		-- Carried across so taking it back hands the same skewer over -- the held estimate is seeded off it.
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

	-- The skewer moves onto the stand, so it leaves the inventory -- this also clears the held visual.
	PlayerDataManager:SetPlayerDataKey(player, { "FilledSticks", filled.Uid }, nil)

	-- A skewer is now on display, so a customer should come for it.
	self.OnSkewerPlaced:Fire(player, record, #placed)

	self._toggling[player] = nil
end

-- Takes the placed skewer at `index` back off the stand and hands it to the player as a fresh tool.
-- The index comes off a remote and the row shifts as skewers come and go, so it's validated against
-- the live data.
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
		-- A customer takes off this same list while the player is reaching for it, so a stale index is
		-- a genuine race, not just a spoof. No error effect -- they didn't do anything wrong.
		NotificationManager:NotifyNormal(player, {
			Text = "A customer just took that one!",
			Duration = 3,
			Sound = "Reject",
		})
		self._toggling[player] = nil
		return
	end

	-- Cooked comes back off the record rather than being stamped: a raw skewer can sit on the stand now,
	-- and taking it back has to hand over the same raw skewer that went on -- down to whatever cook a
	-- pull off the raw band banked on it, which a trip through the stand shouldn't cost them.
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

-- How many skewers are on the player's stand. The sell NPC system reads this to decide whether a stand is
-- stocked enough to be worth sending a rich customer to, without having to take anything off it.
function SkewerStandManager:GetPlacedSkewerCount(player: Player): number
	if not validatePlayer(player) then
		return 0
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return 0
	end

	return #data.SkewerStand
end

-- Takes the top skewer off the stand for a customer NPC to consider, returning a copy of its record (or
-- nil if the stand is empty). Unlike RemoveSkewer it hands nothing back to the player -- the NPC has it.
function SkewerStandManager:TakeSkewer(player: Player)
	if not validatePlayer(player) then
		return nil
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return nil
	end

	local skewers = data.SkewerStand
	if #skewers == 0 then
		return nil
	end

	local placed = table.clone(skewers)
	local record = table.remove(placed)
	PlayerDataManager:SetPlayerDataKey(player, { "SkewerStand" }, placed)

	return {
		-- Carried so a customer who declines puts the same skewer back rather than a re-minted one.
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

-- Clears the whole stand for a rich customer buying in bulk, returning copies of every record on it
-- (an empty array if there was nothing). One read and one write rather than TakeSkewer's per-skewer
-- round trip, so the stand can't be half-emptied if the player places something mid-take.
function SkewerStandManager:TakeAllSkewers(player: Player)
	if not validatePlayer(player) then
		return {}
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return {}
	end

	local taken = {}
	for _, record in data.SkewerStand do
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

	PlayerDataManager:SetPlayerDataKey(player, { "SkewerStand" }, {})

	return taken
end

-- Puts a taken batch back on the stand (the customer decided against it, or its offer lapsed). Every
-- customer carries an array of skewers, so a normal one just returns its array of one.
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
end

-- Registers the player's data listener and does the first render. Guarded so the base-assigned signal
-- and the OnStart sweep can't set the same player up twice.
function SkewerStandManager:_setupPlayer(player: Player)
	if self._listeners[player] then
		return
	end

	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "SkewerStand", function()
		self:_renderStand(player)
	end)

	self:_renderStand(player)
end

-- Drops the player's listener. The stand part (and its attribute) is Base's to destroy.
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
end

function SkewerStandManager:OnStart()
	-- The base is what says the stand exists, so set a player up only once it's been assigned one.
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:_setupPlayer(player)
	end)

	-- A player assigned a base before this manager started won't fire the signal above, so sweep them.
	-- Setting up yields on their data, so keep it off the main thread.
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
