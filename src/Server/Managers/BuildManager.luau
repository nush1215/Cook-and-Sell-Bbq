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

--[[
    Owns building: the structures a player has bought but not yet put down, the tools they place them
    with, and the two remotes they build and pick back up through.

    Player data is the only source of truth. Nothing hands a tool over directly -- any write to
    OwnedStructures re-runs the reconcile, which diffs what the player owns against what's in their
    backpack and creates, updates or destroys tools to match. Stacking, respawn and rejoin all fall
    out of that one path, the same way sticks and ingredients work (see StickManager).

    A structure is therefore only ever in one of two places: in the backpack as an owned item, or
    standing on a plot. Placing moves it from the first to the second and picking it up moves it back,
    so nothing is ever spent by putting something in the wrong spot -- which is what lets a player
    rearrange a base they've paid for.

    Only integer cells cross the wire. The client works out which cell of the base its ghost is hovering
    and sends that; the server turns it back into a pose itself and re-checks that every cell of the
    block is on ground they own and that nothing is already there (see
    BaseManager:PlaceStructureOnBase). So a client can't forge a placement off-grid, onto a plot it
    hasn't bought, or on top of something else -- the worst a hacked client manages is picking a legal
    cell it wasn't looking at.

    There's nowhere to buy a structure yet: players start with one of each (see the data template) and
    GrantStructure is what a shop will call when there is one.
]]

-- The tag every structure tool wears, and the attributes carrying which structure it places and how
-- many of it the player has left. Named here so the client that reads them can't drift.
local TOOL_TAG = "StructureTool"
local STRUCTURE_ATTRIBUTE = "StructureId"
local COUNT_ATTRIBUTE = "Count"

-- The pickup tool. Not an owned item -- it's a mode rather than a thing you have, so it's handed
-- over on every spawn rather than reconciled against data.
local PICKUP_TOOL_ATTRIBUTE = "PickupTool"
local PICKUP_TOOL_NAME = "Pickup"

-- Keeps it on the first hotbar slot however many structures the player is carrying, so the one tool
-- they never choose to have is always in the same place. Read by the backpack (see Modules.Satchel).
local PINNED_TOOL_TAG = "PinnedTool"

-- A whole, finite number, which is the only shape a cell or a rotation may arrive in. Both halves
-- matter against a crafted payload: a fraction would sit between two blocks and overlap neither, and
-- an infinity passes a plain whole-number test (infinity floors to itself) but turns into a NaN the
-- moment it's wrapped into a rotation -- which player data then can't hold. NaN fails the first test
-- on its own, since it never equals itself.
local function isWholeNumber(value: any): boolean
	return type(value) == "number" and value == value // 1 and value > -math.huge and value < math.huge
end

-- Collects the player's structure tools, keyed by structure id. An equipped tool sits in the
-- character rather than the backpack, so both get scanned.
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

-- Brings the player's structure tools in line with data.OwnedStructures: one tool per kind they own,
-- carrying how many on a Count attribute. Every write to that table comes back through here, so a
-- purchase, a placement and a pickup all reconcile down the same path.
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

	-- Drop the tools for anything they've run out of, which is what makes placing your last griller
	-- take the tool out of your hands.
	for structureId, tool in existing do
		if (owned[structureId] or 0) <= 0 then
			tool:Destroy()
		end
	end

	for structureId, count in owned do
		if count <= 0 then
			continue
		end

		-- Owning another of the same kind stacks onto the tool that's already there, so a player who
		-- buys three grillers holds one tool reading 3 rather than three tools.
		local tool = existing[structureId]
		if tool then
			tool:SetAttribute(COUNT_ATTRIBUTE, count)
			continue
		end

		-- Data can hold an id the config no longer has, either removed outright or dropped at load
		-- because its model went missing from Assets.
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

		-- Tag last, against a fully assembled tool -- the client reads the attributes off the back of it.
		newTool:AddTag(TOOL_TAG)
		newTool.Parent = backpack
	end
end

-- Hands over the pickup tool, clearing any left from a previous life so respawns don't stack
-- duplicates. Kept apart from the reconcile above because it isn't something the player owns any
-- number of -- they either can take structures back up or they can't.
--
-- Cloned from the authored hammer rather than built from nothing, unlike the structure tools above:
-- those are one per kind and would each need a model, where this is the single tool every player
-- carries. So RequiresHandle is deliberately left alone -- the template comes with its handle, and
-- forcing it off is what would leave the hammer invisible in hand.
function BuildManager:_givePickupTool(player: Player)
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

	-- Tag last, against a fully assembled tool -- the backpack reads it off the back of the parenting
	-- below to decide which slot it lands in.
	tool:AddTag(PINNED_TOOL_TAG)
	tool.Parent = backpack
end

-- Adds structures to what the player owns (default one), which the reconcile turns into a backpack
-- tool or a higher Count. What a shop calls once there is one, and what a picked-up structure comes
-- back through.
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

-- Spends structures the player owns (default one), for one they've just put down.
function BuildManager:ConsumeStructure(player: Player, structureId: string, amount: number?)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local owned = data.OwnedStructures[structureId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "OwnedStructures", structureId }, math.max(0, owned - (amount or 1)))
end

-- Puts a structure down for the player. Thin on purpose: where it may go is BaseManager's call, since
-- a placement is a write into the build a base renders.
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

	-- CharacterAutoLoads is off and Base drives every respawn through LoadCharacterAsync, which clears
	-- the backpack. Runtime tools aren't in StarterGear, so rebuild them on each spawn.
	--
	-- The pickup tool goes in first, ahead of the reconcile that yields on player data: it claims the
	-- first slot either way, but arriving first means the structure tools fill in behind it rather than
	-- one of them being bumped along to make room.
	player.CharacterAdded:Connect(function()
		self:_givePickupTool(player)
		self:_reconcileTools(player)
	end)

	self:_givePickupTool(player)
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

	-- Reconciling yields on the player's data, so sweep existing players off the main thread.
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
