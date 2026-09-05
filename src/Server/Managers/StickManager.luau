-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

-- Shared
local Shared = ReplicatedStorage.Shared
local Sticks = require(Shared.Config.Sticks)
local Ingredients = require(Shared.Config.Ingredients)
local Sauces = require(Shared.Config.Sauces)
local Mutations = require(Shared.Config.Mutations)
local CookStates = require(Shared.Config.CookStates)
local StickModel = require(Shared.StickModel)
local GuiUtil = require(Shared.GuiUtil)

-- Assets
local Assets = ReplicatedStorage.Assets
local ToolTemplate = Assets.Tools.StickTool

--
local PlayerDataManager

--
local TOOL_TAG = "StickTool"
local FILLED_TOOL_TAG = "FilledStickTool"
local HELD_TAG = "HeldItem"

-- Most ingredient names to spell out on the label before collapsing the rest into a trailing "..."
local LABEL_MAX_INGREDIENTS = 5

-- What a filled skewer's name reads as after the ingredients on it -- "Tomato,Garlic BBQ"
local NAME_SUFFIX = "BBQ"

export type FilledStick = {
	StickId: string,
	Ingredients: { string },
	Cooked: boolean?, -- true once cooked on a griller; renders from the cooked models wherever it shows
	CookState: string?, -- a CookStates id, how well that cook went; scales what the skewer sells for
	CookProgress: number?, -- bar fraction banked by a pull off the raw band, so the next light resumes there
	Sauce: string?, -- a Sauces id, applied at a dispenser once it's cooked; multiplies what it sells for
	Mutation: string?, -- a Mutations id, stamped by the grill it cooked on; multiplies what it sells for
}

-- Owns the player's stick and filled-skewer tools, reconciling them against player data on every change and spawn.

--
local StickManager = {
	_listeners = {}, -- [player] = { sticks = conn, filled = conn }
	_pendingEquips = {}, -- [player] = the stick id or filled-stick uid to equip once its tool exists
}

-- Equips a tool. A no-op mid-respawn, since the new character's reconcile rebuilds their tools.
local function equipTool(player: Player, tool: Tool)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:EquipTool(tool)
	end
end

-- The player's stick tools by id. Both containers, since an equipped tool sits in the character.
local function getStickTools(player: Player): { [string]: Tool }
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

			local stickId = child:GetAttribute("StickId")
			if stickId then
				tools[stickId] = child
			end
		end
	end

	return tools
end

-- The player's filled-stick tools by uid -- the distinct, non-stacking skewers.
local function getFilledStickTools(player: Player): { [string]: Tool }
	local tools = {}
	local containers = { player:FindFirstChildOfClass("Backpack"), player.Character }

	for _, container in containers do
		if not container then
			continue
		end

		for _, child in container:GetChildren() do
			if not (child:IsA("Tool") and child:HasTag(FILLED_TOOL_TAG)) then
				continue
			end

			local uid = child:GetAttribute("FilledStickUid")
			if uid then
				tools[uid] = child
			end
		end
	end

	return tools
end

-- The equipped filled skewer's record, or nil. Takes the caller's already-awaited `data`, so it doesn't yield.
function StickManager:GetEquippedFilledStick(player: Player, data)
	local character = player.Character
	if not character then
		return nil
	end

	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:HasTag(FILLED_TOOL_TAG) then
			local uid = child:GetAttribute("FilledStickUid")
			local record = uid and data.FilledSticks[uid]
			if record then
				return {
					StickId = record.StickId,
					Ingredients = record.Ingredients,
					Cooked = record.Cooked,
					CookState = record.CookState,
					CookProgress = record.CookProgress,
					Sauce = record.Sauce,
					Mutation = record.Mutation,
					Uid = uid,
				}
			end
		end
	end

	return nil
end

-- An empty tagged tool carrying a stick's id and count; HeldItem draws the visual off these.
function StickManager:_buildTool(stick: Sticks.Stick, count: number): Tool
	local tool = ToolTemplate:Clone()

	tool.Name = `{stick.Name} Stick`
	tool.TextureId = stick.Icon
	tool.ToolTip = GuiUtil.Colorize(tool.Name, stick.TextColor)
	tool:SetAttribute("StickId", stick.Id)
	tool:SetAttribute("Count", count)
	tool:SetAttribute("NameStrokeColor", stick.StrokeColor)

	-- Tag last, against a fully assembled tool
	tool:AddTag(TOOL_TAG)
	tool:AddTag(HELD_TAG)
	return tool
end

-- A filled skewer's name: distinct ingredients joined with "+", duplicates as "Name xN", capped with "...". Built plain for the slot and coloured for its tooltip.
local function buildSkewerName(record: FilledStick, colored: boolean): string
	-- Tally duplicates while keeping each ingredient's first-appearance order
	local order = {}
	local counts = {}
	for _, id in record.Ingredients do
		if counts[id] then
			counts[id] += 1
		else
			counts[id] = 1
			table.insert(order, id)
		end
	end

	local names = {}
	for i = 1, math.min(#order, LABEL_MAX_INGREDIENTS) do
		local id = order[i]
		local ingredient = Ingredients.GetIngredientFromId(id)
		local text = if counts[id] > 1 then `{ingredient.Name} x{counts[id]}` else ingredient.Name
		table.insert(names, if colored then GuiUtil.Colorize(text, ingredient.Color) else text)
	end

	local list = table.concat(names, "+")
	if #order > LABEL_MAX_INGREDIENTS then
		list ..= "..."
	end

	return `{list} {NAME_SUFFIX}`
end

-- The skewer's hover tooltip: cook-state tag, then mutation and sauce, then the name tinted per ingredient.
local function buildSkewerToolTip(record: FilledStick): string
	-- The same read the sell price comes off, so the tooltip and the money always agree
	local stateId = StickModel.GetCookStateId(record)
	local tag = GuiUtil.Colorize(`[{string.upper(stateId)}]`, CookStates.GetStateFromId(stateId).Color)

	local mutation = record.Mutation and Mutations.GetMutationFromId(record.Mutation)
	if mutation then
		tag ..= ` {GuiUtil.Colorize(Mutations.GetLabelTag(mutation.Id), mutation.Color)}`
	end

	local sauce = record.Sauce and Sauces.GetSauceFromId(record.Sauce)
	if sauce then
		tag ..= ` {GuiUtil.Colorize(Sauces.GetLabelTag(sauce.Id), sauce.Color)}`
	end

	return `{tag} {buildSkewerName(record, true)}`
end

-- The distinct tool for a filled skewer. Composition rides the tool so every client can draw it, ingredients as JSON.
function StickManager:_buildFilledTool(record: FilledStick, uid: string): Tool?
	local stick = Sticks.GetStickFromId(record.StickId)
	if not stick then
		return nil
	end

	local tool = ToolTemplate:Clone()

	tool.Name = `{stick.Name} BBQ`
	tool:SetAttribute("StickId", stick.Id)
	tool:SetAttribute("FilledStickUid", uid)
	tool:SetAttribute("Cooked", record.Cooked == true)
	tool:SetAttribute("CookState", record.CookState)
	tool:SetAttribute("Sauce", record.Sauce)
	tool:SetAttribute("Mutation", record.Mutation)
	tool:SetAttribute("Ingredients", HttpService:JSONEncode(record.Ingredients))
	tool:SetAttribute("NameStrokeColor", stick.StrokeColor)
	tool:SetAttribute("NameText", buildSkewerName(record, false))
	tool.ToolTip = buildSkewerToolTip(record)

	-- Tag last, against a fully assembled tool
	tool:AddTag(FILLED_TOOL_TAG)
	tool:AddTag(HELD_TAG)
	return tool
end

-- Builds the skewer as a static anchored model through the shared builder, for the caller to place.
function StickManager:BuildPlacedStickModel(record: FilledStick): Model?
	local model = StickModel.BuildStickModel(record)
	if not model then
		return nil
	end

	-- Anchored and non-collidable; PivotTo still moves it, so the caller can place the whole thing
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
		end
	end

	return model
end

-- Brings the player's stick tools in line with the sticks they own.
function StickManager:_reconcileTools(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or not player:IsDescendantOf(Players) then
		return
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end

	local owned = data.Sticks
	local existing = getStickTools(player)

	-- Drop the tools for anything they've run out of
	for stickId, tool in existing do
		if (owned[stickId] or 0) <= 0 then
			tool:Destroy()
		end
	end

	for stickId, count in owned do
		if count <= 0 then
			continue
		end

		-- Buying the same stick again stacks onto the tool that's already there
		local tool = existing[stickId]
		if tool then
			tool:SetAttribute("Count", count)
		else
			-- Data can hold an id the config no longer has, removed outright or dropped at load
			local stick = Sticks.GetStickFromId(stickId)
			if not stick then
				continue
			end

			tool = self:_buildTool(stick, count)
			tool.Parent = backpack
		end

		-- The stick the player just took goes straight into their hands
		if self._pendingEquips[player] == stickId then
			self._pendingEquips[player] = nil
			equipTool(player, tool)
		end
	end
end

-- The one way a stick is handed over. `skipEquip` keeps the hammer in hand so a base can be cleared in one go.
function StickManager:GrantStick(player: Player, stickId: string, amount: number?, skipEquip: boolean?)
	local stick = Sticks.GetStickFromId(stickId)
	if not stick then
		return
	end

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- Flagged before the write, since that's what runs the reconcile that builds the tool to equip.
	if not skipEquip then
		self._pendingEquips[player] = stickId
	end

	local owned = data.Sticks[stickId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "Sticks", stickId }, owned + (amount or 1))
end

-- Takes from the player's owned sticks; the reconcile turns it into a lower Count or a destroyed tool.
function StickManager:ConsumeStick(player: Player, stickId: string, amount: number?)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local owned = data.Sticks[stickId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "Sticks", stickId }, math.max(0, owned - (amount or 1)))
end

-- Reconciles filled-skewer tools by uid. Existing ones are left alone unless their Sauce no longer matches.
function StickManager:_reconcileFilledSticks(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or not player:IsDescendantOf(Players) then
		return
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end

	local owned = data.FilledSticks
	local existing = getFilledStickTools(player)

	-- Drop tools whose filled skewer is gone (placed back on a stand, or cooked later)
	for uid, tool in existing do
		if not owned[uid] then
			tool:Destroy()
		end
	end

	for uid, record in owned do
		local current = existing[uid]
		if current then
			if current:GetAttribute("Sauce") == record.Sauce then
				continue
			end

			-- Rebuilt so the label and held visual pick the sauce up; an equipped tool unequips for a frame
			current:Destroy()
		end

		local tool = self:_buildFilledTool(record, uid)
		if tool then
			tool.Parent = backpack

			-- The skewer the player just took goes straight into their hands
			if self._pendingEquips[player] == uid then
				self._pendingEquips[player] = nil
				equipTool(player, tool)
			end
		end
	end
end

-- Adds a filled skewer as a distinct tool. `uid` is reused where a structure only held it, so uid-seeded values don't shift.
function StickManager:AddFilledStick(player: Player, record: FilledStick, skipEquip: boolean?, uid: string?)
	uid = uid or HttpService:GenerateGUID(false)

	-- Flagged before the write, since that's what runs the reconcile that builds the tool to equip.
	if not skipEquip then
		self._pendingEquips[player] = uid
	end

	PlayerDataManager:SetPlayerDataKey(player, { "FilledSticks", uid }, record)
end

function StickManager:_setupPlayer(player: Player)
	-- The signals only report the top-level key, but the reconciles re-diff everything anyway
	self._listeners[player] = {
		sticks = PlayerDataManager:ListenForChanges(player, "Sticks", function()
			self:_reconcileTools(player)
		end),
		filled = PlayerDataManager:ListenForChanges(player, "FilledSticks", function()
			self:_reconcileFilledSticks(player)
		end),
	}

	-- Every respawn clears the backpack and runtime tools aren't in StarterGear, so they're rebuilt
	player.CharacterAdded:Connect(function()
		self:_reconcileTools(player)
		self:_reconcileFilledSticks(player)
	end)

	self:_reconcileTools(player)
	self:_reconcileFilledSticks(player)
end

function StickManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
end

function StickManager:OnStart()
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
		local listeners = self._listeners[player]
		if listeners then
			listeners.sticks:Disconnect()
			listeners.filled:Disconnect()
			self._listeners[player] = nil
		end

		self._pendingEquips[player] = nil
	end)
end

return StickManager
