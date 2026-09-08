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

-- The category, not one model's id, so a second kind of stand renders here unchanged
local STAND_CATEGORY = "StickStands"

-- The child a stand needs to seat anything. Waited on, since a placed stand replicates mid-session
local REQUIRED_CHILD = "Stand"
local CHILD_TIMEOUT = 10

-- One StickStand per placed stand, rendering off its PlacedStickId attribute so visitors see them too. Found off the StickStand tag, since stands are built rather than authored.

--
local StickStandController = {
	ToggleStickEvent = Network.Event("ToggleStickOnStand"),

	_stands = {}, -- [model: Model] = StickStand
	_takeLocked = false, -- while true, no stand offers what it's holding back (see SetTakeLocked)
	_placeLocked = false, -- while true, no empty stand offers to seat anything (see SetPlaceLocked)
	_cleaner = Trove.new(),
}

-- Builds a StickStand for a placed stand, unless one already tracks it.
function StickStandController:_addStand(model: Model)
	if self._stands[model] then
		return
	end

	-- Belt-and-braces, but a stand built without it has nowhere to seat a stick for good
	if not model:WaitForChild(REQUIRED_CHILD, CHILD_TIMEOUT) then
		warn(`[StickStand] {model.Name} has no {REQUIRED_CHILD}, it won't render`)
		return
	end

	-- Waiting above yields, so the stand can have been taken away in the meantime
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

-- Asks the server to act on this stand; it decides which from what's held and the stand's state.
function StickStandController:RequestToggle(uid: string)
	self.ToggleStickEvent:FireServer(uid)
end

-- The stick seated on a stand, or nil. A sibling of the stand and re-created on every change, so it's re-resolved.
function StickStandController:GetPlacedStickModel(model: Model): Model?
	local stand = self._stands[model]
	return stand and stand:GetStickModel()
end

-- Re-checks every stand's prompt. Cheap, and what it says depends on what the player is holding.
function StickStandController:_refreshPrompts()
	for _, stand in self._stands do
		stand:RefreshPrompt()
	end
end

-- Holds every stand's take off, gating eligibility rather than the prompt -- one prompt covers place, add and take.
function StickStandController:SetTakeLocked(locked: boolean)
	if self._takeLocked == locked then
		return
	end

	self._takeLocked = locked
	self:_refreshPrompts()
end

-- Whether taking is held off. Read by StickStand when it works out what its prompt offers.
function StickStandController:IsTakeLocked(): boolean
	return self._takeLocked
end

-- Holds every stand's place off, so a loaded BBQ can't be put straight back on the way to the griller.
function StickStandController:SetPlaceLocked(locked: boolean)
	if self._placeLocked == locked then
		return
	end

	self._placeLocked = locked
	self:_refreshPrompts()
end

-- Whether placing is held off. Read by StickStand when it works out what its prompt offers.
function StickStandController:IsPlaceLocked(): boolean
	return self._placeLocked
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

	-- A stand placed on any base wires itself up here, before this client started or while it runs
	self._cleaner:Connect(CollectionService:GetInstanceAddedSignal(STAND_CATEGORY), function(model)
		self:_addStand(model)
	end)

	self._cleaner:Connect(CollectionService:GetInstanceRemovedSignal(STAND_CATEGORY), function(model)
		self:_removeStand(model)
	end)

	-- _addStand waits on the stand's children, so keep the sweep off the main thread
	for _, model in CollectionService:GetTagged(STAND_CATEGORY) do
		task.spawn(function()
			self:_addStand(model)
		end)
	end

	-- One loop keeps every placed stick and its ingredients glued as the client animates the stand
	RunService.Heartbeat:Connect(function(deltaTime: number)
		for _, stand in self._stands do
			stand:Update(deltaTime)
		end
	end)

	-- Equipping or unequipping an ingredient changes what the prompt should say
	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_watchCharacter(character)
	end)
end

return StickStandController
