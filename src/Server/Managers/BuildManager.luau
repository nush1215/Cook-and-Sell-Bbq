-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Structures = require(Shared.Config.Structures)

-- Assets
local Assets = ReplicatedStorage.Assets
local PickupToolTemplate = Assets.Tools.Hammer

-- Managers
local PlayerDataManager
local BaseManager

-- Owns what structures a player is carrying: the backpack tools, and the pickup hammer. Where they go is BaseManager's.

-- The tag and attributes a structure tool wears, named here so the client reading them can't drift
local TOOL_TAG = "StructureTool"
local STRUCTURE_ATTRIBUTE = "StructureId"
local COUNT_ATTRIBUTE = "Count"

-- The pickup tool. A mode rather than an owned item, so it's handed over on every spawn
local PICKUP_TOOL_ATTRIBUTE = "PickupTool"
local PICKUP_TOOL_NAME = "Pickup"

-- Pins it to the first hotbar slot, so the one tool they never chose is always in the same place
local PINNED_TOOL_TAG = "PinnedTool"

-- A whole, finite number -- the only shape a cell or rotation may arrive in. Infinity survives a floor but becomes NaN once wrapped.
local function isWholeNumber(value: any): boolean
	return type(value) == "number" and value == value // 1 and value > -math.huge and value < math.huge
end

-- The player's structure tools by id. Both containers, since an equipped tool sits in the character.
local function getStructureTools(player: Player): { [string]: Tool }
	local tools = {}

	for _, container in { player:FindFirstChildOfClass("Backpack"), player.Character } do
		if not container then
			continue
		end

		for _, child in container:GetChildren() do
			if child:IsA("Tool") and child:HasTag(TOOL_TAG) then
				local structureId = child:GetAttribute(STRUCTURE_ATTRIBUTE)

				if structureId then
					tools[structureId] = child
				end
			end
		end
	end

	return tools
end

--
local BuildManager = {
	PlaceStructureEvent = Network.Event("PlaceStructure", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 20 },
		Validate = function(_player, structureType, cellX, cellZ, rotation)
			return type(structureType) == "string"
				and isWholeNumber(cellX)
				and isWholeNumber(cellZ)
				and isWholeNumber(rotation)
		end,
	}),

	RemoveStructureEvent = Network.Event("RemoveStructure", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 20 },
		Validate = function(_player, uid)
			return type(uid) == "string"
		end,
	}),

	_listeners = {}, -- [player] = the OwnedStructures data listener
}

-- Reconciles structure tools against OwnedStructures, one per kind with a Count. Every write comes back through here.
function BuildManager:_reconcileTools(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or not player:IsDescendantOf(Players) then
		return
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end

	local owned = data.OwnedStructures
	local existing = getStructureTools(player)

	-- Dropped when they run out, which is what takes the tool out of your hand on the last placement
	for structureId, tool in existing do
		if (owned[structureId] or 0) <= 0 then
			tool:Destroy()
		end
	end

	for structureId, count in owned do
		if count <= 0 then
			continue
		end

		-- Stacked, so three grillers is one tool reading 3 rather than three tools
		local tool = existing[structureId]
		if tool then
			tool:SetAttribute(COUNT_ATTRIBUTE, count)
			continue
		end

		-- Data can hold an id the config no longer has, removed outright or dropped at load
		local structure = Structures.GetStructureFromId(structureId)
		if not structure then
			continue
		end

		local newTool = Instance.new("Tool")
		newTool.Name = structure.Name
		newTool.ToolTip = structure.Name
		newTool.TextureId = structure.Icon
		newTool.RequiresHandle = false
		newTool.CanBeDropped = false
		newTool:SetAttribute(STRUCTURE_ATTRIBUTE, structure.Id)
		newTool:SetAttribute(COUNT_ATTRIBUTE, count)

		-- Tag last, against a fully assembled tool -- the client reads the attributes off the back of it
		newTool:AddTag(TOOL_TAG)
		newTool.Parent = backpack
	end
end

-- Hands over the pickup hammer, clearing any left from a previous life. Held back until the tutorial is done, which is what finishing it pays out.
function BuildManager:GivePickupTool(player: Player)
	local hasData, completed = PlayerDataManager:GetPlayerDataKey(player, "TutorialCompleted"):await()
	if not hasData or not completed then
		return
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end

	for _, tool in backpack:GetChildren() do
		if tool:GetAttribute(PICKUP_TOOL_ATTRIBUTE) then
			tool:Destroy()
		end
	end

	local tool = PickupToolTemplate:Clone()
	tool.Name = PICKUP_TOOL_NAME
	tool.ToolTip = PICKUP_TOOL_NAME
	tool.CanBeDropped = false
	tool:SetAttribute(PICKUP_TOOL_ATTRIBUTE, true)

	-- Tag last, so the backpack reads it off the back of the parenting and picks the right slot
	tool:AddTag(PINNED_TOOL_TAG)
	tool.Parent = backpack
end

-- Adds to what the player owns; the reconcile turns it into a tool or a higher Count.
function BuildManager:GrantStructure(player: Player, structureId: string, amount: number?)
	if not Structures.GetStructureFromId(structureId) then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local owned = data.OwnedStructures[structureId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "OwnedStructures", structureId }, owned + (amount or 1))
end

-- Spends structures the player owns, for one they've just put down.
function BuildManager:ConsumeStructure(player: Player, structureId: string, amount: number?)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local owned = data.OwnedStructures[structureId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "OwnedStructures", structureId }, math.max(0, owned - (amount or 1)))
end

-- Puts a structure down. Thin on purpose -- where it may go is BaseManager's call.
function BuildManager:HandlePlaceRequest(
	player: Player,
	structureType: string,
	cellX: number,
	cellZ: number,
	rotation: number
)
	BaseManager:PlaceStructureOnBase(player, structureType, cellX, cellZ, rotation)
end

-- Takes one of the player's structures back down, returning it to their inventory.
function BuildManager:HandleRemoveRequest(player: Player, uid: string)
	BaseManager:RemoveStructureFromBase(player, uid)
end

-- Starts keeping one player's tools in step with what they own.
function BuildManager:_setupPlayer(player: Player)
	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "OwnedStructures", function()
		self:_reconcileTools(player)
	end)

	-- Rebuilt each spawn, the backpack being cleared and runtime tools not being in StarterGear. The pickup tool goes first so the rest fill in behind it
	player.CharacterAdded:Connect(function()
		self:GivePickupTool(player)
		self:_reconcileTools(player)
	end)

	self:GivePickupTool(player)
	self:_reconcileTools(player)
end

function BuildManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	BaseManager = require(script.Parent.BaseManager)
end

function BuildManager:OnStart()
	self.PlaceStructureEvent:OnServerEvent(
		function(player: Player, structureType: string, cellX: number, cellZ: number, rotation: number)
			self:HandlePlaceRequest(player, structureType, cellX, cellZ, rotation)
		end
	)

	self.RemoveStructureEvent:OnServerEvent(function(player: Player, uid: string)
		self:HandleRemoveRequest(player, uid)
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		self:_setupPlayer(player)
	end)

	-- Reconciling yields on the player's data, so sweep existing players off the main thread
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_setupPlayer(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		local listener = self._listeners[player]

		if listener then
			listener:Disconnect()
			self._listeners[player] = nil
		end
	end)
end

return BuildManager
