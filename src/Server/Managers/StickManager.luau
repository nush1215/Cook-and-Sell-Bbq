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

--[[
    Projects a player's owned sticks onto tools in their backpack: one tool per stick tier they own,
    carrying how many on a Count attribute.

    Player data is the only source of truth here -- nothing grants a tool directly. Any write to
    Sticks re-runs the reconcile, which diffs what the player owns against what's in their backpack
    and creates, updates or destroys tools to match. Stacking, respawn and rejoin all fall out of
    that one path.

    Nothing here listens to the client. Every way a stick is handed over -- the stick shop, a crate,
    the starter pack, the group reward, a code -- goes through GrantStick from the server side that
    already decided the player had earned it. There is deliberately no remote that grants one on
    request: giving a stick for testing is the giveStick command, which the CommandManager's BeforeRun
    hook gates on staff rank.
]]

--
local StickManager = {
	_listeners = {}, -- [player] = { sticks = conn, filled = conn }
	_pendingEquips = {}, -- [player] = the stick id or filled-stick uid to equip once its tool exists
}

-- Puts a tool straight into the player's hands, swapping out whatever they were holding. Nothing to
-- do if they're mid-respawn -- the reconcile the new character kicks off rebuilds their tools anyway.
local function equipTool(player: Player, tool: Tool)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:EquipTool(tool)
	end
end

-- Collects the player's stick tools, keyed by stick id. An equipped tool sits in the character
-- rather than the backpack, so both get scanned.
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

-- Collects the player's filled-stick tools, keyed by their uid. Like getStickTools but for the
-- distinct, non-stacking skewers.
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

-- Returns the filled skewer the player currently has equipped as { StickId, Ingredients, Cooked,
-- CookState, CookProgress, Sauce, Mutation, Uid }, or nil. Only FilledStickTools qualify; a character holds at
-- most one equipped tool. `data` is the caller's already-awaited player data, so this doesn't yield --
-- every caller has read it to act on the skewer anyway.
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

-- Builds the tool for one stick: an empty tagged tool carrying its id + count. The held visual is
-- drawn client-side by the HeldItem component off these attributes.
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

-- What a filled skewer is called, as one line: the distinct ingredients on it in first-appearance
-- order joined with "+", duplicates collapsed into "Name xN", capped at LABEL_MAX_INGREDIENTS with a
-- trailing "..." when there are more, then NAME_SUFFIX -- "Tomato+Garlic BBQ". The overflow marker is
-- "..." rather than another "+" so it can't be read as a separator with the last name missing. Built
-- twice off the same tally -- plain for the slot label, which is a 70px square with no room for colour,
-- and coloured for the tooltip that slot pops up, which has room for it. A skewer always carries at
-- least one ingredient, since StickStandManager hands a stick taken off a stand empty back as a plain
-- stick rather than a filled one.
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

-- Builds the tooltip the skewer's slot pops up on hover: a coloured tag for whichever cook state it
-- landed on, then the mutation's and the sauce's own tags if it carries them, then the skewer's name
-- with every ingredient in it tinted its own colour. The slot itself only has room for that name plain
-- and a badge for the cook state, so everything else lives here. The mutation comes first of the two
-- because it's the rarer thing to be carrying. Rendered as RichText by Satchel off the tool's ToolTip.
local function buildSkewerToolTip(record: FilledStick): string
	-- The tag is whatever state the cook landed on, and the same read the sell price comes off, so the
	-- tooltip and the money always agree.
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

-- Builds the distinct tool for a filled skewer: an empty tagged tool carrying the ids the HeldItem
-- component needs to rebuild the skewer client-side. The composition rides on the tool (not the
-- owner's private data) so every client can draw it; attributes can't hold a list, so the ingredients
-- go on as a JSON string. Non-stacking -- one tool per uid.
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

-- Builds the filled skewer as a static, anchored model for showing in the world (e.g. on a grill),
-- via the shared StickModel builder so it matches the held skewer exactly. The caller pivots and
-- parents the returned model.
function StickManager:BuildPlacedStickModel(record: FilledStick): Model?
	local model = StickModel.BuildStickModel(record)
	if not model then
		return nil
	end

	-- Static display: anchored so it just sits there, non-collidable so players walk through it. PivotTo
	-- moves anchored parts too, so the caller can still place the whole thing.
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
			-- Data can hold an id the config no longer has, either removed outright or dropped at load
			-- because its model went missing from Assets.
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

-- Adds some of the given stick tier to the player's owned count (default one), which the reconcile
-- turns into a backpack tool or a higher Count, equipped. The one way a stick is ever handed over, so
-- it's what the stick shop, the crates, the starter pack and the giveStick command all call -- the
-- last three of those hand over several of one tier at a time.
-- @param skipEquip Leave it in the backpack rather than putting it in their hands, for a stick that
-- came back off a structure the player picked up: taking the hammer out of their hand there would end
-- the pickup after every structure, so a base couldn't be cleared in one go.
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

-- Takes some of the player's owned sticks of a tier (default one), which the reconcile turns into a
-- lower Count or a destroyed tool. Reused by placing a stick on a stand and, later, by cooking.
function StickManager:ConsumeStick(player: Player, stickId: string, amount: number?)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local owned = data.Sticks[stickId] or 0
	PlayerDataManager:SetPlayerDataKey(player, { "Sticks", stickId }, math.max(0, owned - (amount or 1)))
end

-- Brings the player's filled-skewer tools in line with data.FilledSticks: one distinct tool per uid.
-- A filled skewer's composition never changes once built, so existing tools are left alone -- only new
-- uids are built and removed ones destroyed. The one exception is sauce, which a dispenser applies to a
-- skewer that's already in the inventory: a tool whose Sauce no longer matches its record is rebuilt so
-- its label and held visual catch up.
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

	-- Drop tools whose filled skewer is gone (placed back on a stand, or cooked later).
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

			-- Sauce was applied to a skewer already in the inventory: rebuild it so the label and the
			-- held visual pick the sauce up. Rebuilding an equipped tool unequips it for a frame.
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

-- Adds a filled skewer to the player's inventory as a fresh, distinct tool, equipped. Reused by
-- taking a loaded stick off a stand or a griller (where it comes back carrying however its cook
-- went), or off the sell stand (where it may come back sauced). The record goes straight into player
-- data, so callers hand over one they've built rather than one they're still holding.
-- @param skipEquip Leave it in the backpack rather than putting it in their hands, for a skewer that
-- came back off a structure the player picked up: taking the hammer out of their hand there would end
-- the pickup after every structure, so a base couldn't be cleared in one go.
function StickManager:AddFilledStick(player: Player, record: FilledStick, skipEquip: boolean?)
	local uid = HttpService:GenerateGUID(false)

	-- Flagged before the write, since that's what runs the reconcile that builds the tool to equip.
	if not skipEquip then
		self._pendingEquips[player] = uid
	end

	PlayerDataManager:SetPlayerDataKey(player, { "FilledSticks", uid }, record)
end

function StickManager:_setupPlayer(player: Player)
	-- The signals only report the top-level key, so they can't say which stick moved. The reconciles
	-- re-diff everything anyway, so they don't need to know.
	self._listeners[player] = {
		sticks = PlayerDataManager:ListenForChanges(player, "Sticks", function()
			self:_reconcileTools(player)
		end),
		filled = PlayerDataManager:ListenForChanges(player, "FilledSticks", function()
			self:_reconcileFilledSticks(player)
		end),
	}

	-- CharacterAutoLoads is off and Base drives every respawn through LoadCharacterAsync, which
	-- clears the backpack. Runtime tools aren't in StarterGear, so rebuild them on each spawn.
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
