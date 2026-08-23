-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

-- Modules
local StickStand = require(script.StickStand)

--
local LocalPlayer = Players.LocalPlayer

-- The structure category stick stands are, which is also the tag every placed one wears. The category
-- and not one model's id, so a second kind of stand renders through this controller with nothing changed.
local STAND_CATEGORY = "StickStands"

-- The child a StickStand has to have to seat anything. It comes off the structure's template, so it's
-- always there -- but a placed stand replicates in mid-session rather than existing from place-load,
-- so it's waited on rather than assumed (see _addStand).
local REQUIRED_CHILD = "Stand"
local CHILD_TIMEOUT = 10

--[[
    Renders the sticks placed on every base's stick stands and drives the owner's place/remove prompt.

    One StickStand instance per placed stand, across every base, so visitors see placed sticks too --
    the server writes which stick sits on each stand to a PlacedStickId attribute and the class
    renders it. The prompt is the class's own concern and only appears on stands the local player owns.

    Stands are structures a player builds rather than slots authored into their base, so they're found
    off the StickStand tag: one appearing mid-session is picked up the same way as one that was already
    down when the client started, and the OwnerUserId attribute on it is what says whose it is.
]]

--
local StickStandController = {
	ToggleStickEvent = Network.Event("ToggleStickOnStand"),

	_stands = {}, -- [model: Model] = StickStand
	_cleaner = Trove.new(),
}

-- Builds a StickStand for a placed stand, unless one already tracks it.
function StickStandController:_addStand(model: Model)
	if self._stands[model] then
		return
	end

	-- The server builds the stand complete before it tags it, and Roblox replicates a newly-parented
	-- model's descendants together, so this is belt-and-braces -- but a stand built without it has
	-- nowhere to seat a stick for good rather than merely late.
	if not model:WaitForChild(REQUIRED_CHILD, CHILD_TIMEOUT) then
		warn(`[StickStand] {model.Name} has no {REQUIRED_CHILD}, it won't render`)
		return
	end

	-- Waiting above yields, so the stand can have been taken away in the meantime.
	if not model.Parent or self._stands[model] then
		return
	end

	local stand = StickStand.new(model)
	self._stands[model] = stand
	self._cleaner:Add(stand)
end

-- Drops the StickStand for a stand that's been taken away.
function StickStandController:_removeStand(model: Model)
	local stand = self._stands[model]
	if not stand then
		return
	end

	self._cleaner:Remove(stand)
	self._stands[model] = nil
end

-- Asks the server to place the equipped stick on this stand, load an ingredient onto it, or take it
-- back off -- the server decides which from what the player holds and the stand's state.
function StickStandController:RequestToggle(uid: string)
	self.ToggleStickEvent:FireServer(uid)
end

-- Re-checks every stand's prompt (ownership + text). Cheap, and the prompt text depends on what the
-- local player is holding, so it's called whenever their base or equipped tool changes.
function StickStandController:_refreshPrompts()
	for _, stand in self._stands do
		stand:RefreshPrompt()
	end
end

-- Watches the local character's tools so the "Add {Ingredient}" prompt tracks what they equip.
function StickStandController:_watchCharacter(character: Model)
	self._characterCleaner:Clean()

	self._characterCleaner:Connect(character.ChildAdded, function(child)
		if child:IsA("Tool") then
			self:_refreshPrompts()
		end
	end)
	self._characterCleaner:Connect(character.ChildRemoved, function(child)
		if child:IsA("Tool") then
			self:_refreshPrompts()
		end
	end)

	self:_refreshPrompts()
end

function StickStandController:OnStart()
	self._characterCleaner = self._cleaner:Construct(Trove)

	-- A stand placed on any base wires itself up here, whether it went down before this client started
	-- or while it's running.
	self._cleaner:Connect(CollectionService:GetInstanceAddedSignal(STAND_CATEGORY), function(model)
		self:_addStand(model)
	end)

	self._cleaner:Connect(CollectionService:GetInstanceRemovedSignal(STAND_CATEGORY), function(model)
		self:_removeStand(model)
	end)

	-- _addStand waits on the stand's children, so keep the sweep off the main thread.
	for _, model in CollectionService:GetTagged(STAND_CATEGORY) do
		task.spawn(function()
			self:_addStand(model)
		end)
	end

	-- One loop keeps every placed stick (and its ingredients) glued to its stand as the client
	-- animates it into place.
	RunService.Heartbeat:Connect(function(deltaTime: number)
		for _, stand in self._stands do
			stand:Update(deltaTime)
		end
	end)

	-- Equipping/unequipping an ingredient changes what the prompt should say.
	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_watchCharacter(character)
	end)
end

return StickStandController
