-- Sauce dispensers are postponed to a future update, so the bottles that fill them are dormant too.
-- Everything below is intact -- un-comment it alongside SauceDispenserManager to bring it back.

--[==[
-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Sauces = require(Shared.Config.Sauces)

-- Assets
local Assets = ReplicatedStorage.Assets
local ToolTemplate = Assets.Tools.SauceTool

--
local PlayerDataManager

--
local TOOL_TAG = "SauceTool"

--[[
    Projects a player's owned sauce bottles onto tools in their backpack: one tool per flavor they own,
    carrying how many on a Count attribute.

    Player data is the only source of truth here -- nothing grants a tool directly. Any write to Sauces
    re-runs the reconcile, which diffs what the player owns against what's in their backpack and creates,
    updates or destroys tools to match. Stacking, respawn and rejoin all fall out of that one path.
    Modelled on IngredientManager, which does the same for loose ingredients.

    A bottle is spent on a sauce dispenser (SauceDispenserManager:RefillSauceDispenser), loading it with
    that flavor and filling it to its size's capacity. The buying flow doesn't exist yet, so GrantSauce is
    fired off a debug remote for now, the way StickManager's GrantStick is.

    Unlike the stick and ingredient tools these carry no HeldItem tag: the carried visual for a bottle
    isn't bound yet, and HeldItem has no branch that could draw one. Add the tag alongside that branch.
]]

--
local SauceToolManager = {
	GiveSauceEvent = Network.Event("GiveSauce"),

	_listeners = {}, -- [player] = the Sauces data listener
	_pendingEquips = {}, -- [player] = the sauce id to equip once its tool exists
}

-- Puts a tool straight into the player's hands, swapping out whatever they were holding. Nothing to
-- do if they're mid-respawn -- the reconcile the new character kicks off rebuilds their tools anyway.
local function equipTool(player: Player, tool: Tool)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:EquipTool(tool)
	end
end

-- Collects the player's sauce tools, keyed by sauce id. An equipped tool sits in the character rather
-- than the backpack, so both get scanned.
local function getSauceTools(player: Player): { [string]: Tool }
	local tools = {}
	local containers = { player:FindFirstChildOfClass("Backpack"), player.Character }

	for _, container in containers do
		if not container then
			continue
		end

		for _, child in container:GetChildren() do
			if not (child:IsA("Tool") and child:HasTag(TOOL_TAG)) then
				continue
			end

			local sauceId = child:GetAttribute("SauceId")
			if sauceId then
				tools[sauceId] = child
			end
		end
	end

	return tools
end

-- The id of the sauce bottle the player currently has equipped, or nil. A character holds at most one
-- equipped tool, so the first hit is the answer. The dispenser reads this to know what it's being
-- filled with.
function SauceToolManager:GetEquippedSauceId(player: Player): string?
	local character = player.Character
	if not character then
		return nil
	end

	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:HasTag(TOOL_TAG) then
			return child:GetAttribute("SauceId")
		end
	end

	return nil
end

-- Builds the tool for one sauce: an empty tagged tool carrying its id + count.
function SauceToolManager:_buildTool(sauce: Sauces.Sauce, count: number): Tool
	local tool = ToolTemplate:Clone()

	tool.Name = `{sauce.Name} Bottle`
	tool:SetAttribute("SauceId", sauce.Id)
	tool:SetAttribute("Count", count)
	tool:SetAttribute("NameColor", sauce.Color)

	-- Tag last, against a fully assembled tool
	tool:AddTag(TOOL_TAG)
	return tool
end

-- Brings the player's sauce tools in line with the bottles they own.
function SauceToolManager:_reconcileTools(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or not player:IsDescendantOf(Players) then
		return
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end

	local owned = data.Sauces
	local existing = getSauceTools(player)

	-- Drop the tools for anything they've run out of
	for sauceId, tool in existing do
		if (owned[sauceId] or 0) <= 0 then
			tool:Destroy()
		end
	end

	for sauceId, count in owned do
		if count <= 0 then
			continue
		end

		-- Picking up the same flavor again stacks onto the tool that's already there
		local tool = existing[sauceId]
		if tool then
			tool:SetAttribute("Count", count)
		else
			-- Data can hold an id the config no longer has, either removed outright or dropped at load
			-- because its particles went missing from Assets.
			local sauce = Sauces.GetSauceFromId(sauceId)
			if not sauce then
				continue
			end

			tool = self:_buildTool(sauce, count)
			tool.Parent = backpack
		end

		-- The bottle the player just took goes straight into their hands
		if self._pendingEquips[player] == sauceId then
			self._pendingEquips[player] = nil
			equipTool(player, tool)
		end
	end
end

-- Adds some bottles of a sauce to the player's owned count (default one), which the reconcile turns
-- into a backpack tool or a higher Count, equipped. Reused by the real buying flow once it exists.
function SauceToolManager:GrantSauce(player: Player, sauceId: string, amount: number?)
	local sauce = Sauces.GetSauceFromId(sauceId)
	if not sauce then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- Flagged before the write, since that's what runs the reconcile that builds the tool to equip.
	self._pendingEquips[player] = sauce.Id

	local owned = data.Sauces[sauce.Id] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "Sauces", sauce.Id }, owned + (amount or 1))
end

-- Takes some of the player's owned bottles of a sauce (default one), which the reconcile turns into a
-- lower Count or a destroyed tool. Reused by filling a dispenser with one.
function SauceToolManager:ConsumeSauce(player: Player, sauceId: string, amount: number?)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local owned = data.Sauces[sauceId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "Sauces", sauceId }, math.max(0, owned - (amount or 1)))
end

function SauceToolManager:_setupPlayer(player: Player)
	-- The signal only reports the top-level key, so it can't say which flavor moved. The reconcile
	-- re-diffs everything anyway, so it doesn't need to know.
	self._listeners[player] = PlayerDataManager:ListenForChanges(player, "Sauces", function()
		self:_reconcileTools(player)
	end)

	-- CharacterAutoLoads is off and Base drives every respawn through LoadCharacterAsync, which
	-- clears the backpack. Runtime tools aren't in StarterGear, so rebuild them on each spawn.
	player.CharacterAdded:Connect(function()
		self:_reconcileTools(player)
	end)

	self:_reconcileTools(player)
end

function SauceToolManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
end

function SauceToolManager:OnStart()
	self.GiveSauceEvent:OnServerEvent(function(player: Player, sauceId: string)
		self:GrantSauce(player, sauceId)
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

		self._pendingEquips[player] = nil
	end)
end

return SauceToolManager
]==]

return {}
