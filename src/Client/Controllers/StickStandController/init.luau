-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

--[[
    Renders the sticks placed on every base's stick stands and drives the owner's place/remove prompt.

    One StickStand instance per stand clone, across every base, so visitors see placed sticks too --
    the server writes which stick sits on each stand to a PlacedStickId attribute and the class
    renders it. The prompt is the class's own concern and only appears on the local player's base.
]]

--
local StickStandController = {
	ToggleStickEvent = Network.Event("ToggleStickOnStand"),

	_stands = {}, -- [clone: Model] = StickStand
	_cleaner = Trove.new(),
}

-- Builds a StickStand for a stand clone the base just added, unless one already tracks it.
function StickStandController:_addStand(clone: Model, baseId: string)
	if self._stands[clone] then
		return
	end

	local stand = StickStand.new(clone, baseId)
	self._stands[clone] = stand
	self._cleaner:Add(stand)
end

-- Drops the StickStand for a stand clone the base took away (a downgrade, or the base being cleared).
function StickStandController:_removeStand(clone: Model)
	local stand = self._stands[clone]
	if not stand then
		return
	end

	self._cleaner:Remove(stand)
	self._stands[clone] = nil
end

-- Tracks a base's stick stands as its owner unlocks and (rarely) loses them. The server parks a
-- stand out of the world while it's locked and parents it back in when it's bought, so the folder is
-- what says which stands a base has.
function StickStandController:_setupBase(baseModel: Model)
	local interactables = baseModel:FindFirstChild("Interactables")
	local standFolder = interactables and interactables:FindFirstChild("StickStand")
	if not standFolder then
		return
	end

	for _, clone in standFolder:GetChildren() do
		if tonumber(clone.Name) then
			self:_addStand(clone, baseModel.Name)
		end
	end

	self._cleaner:Connect(standFolder.ChildAdded, function(clone)
		if tonumber(clone.Name) then
			self:_addStand(clone, baseModel.Name)
		end
	end)

	self._cleaner:Connect(standFolder.ChildRemoved, function(clone)
		self:_removeStand(clone)
	end)
end

-- Asks the server to place the equipped stick on this stand, load an ingredient onto it, or take it
-- back off -- the server decides which from what the player holds and the stand's state.
function StickStandController:RequestToggle(slotId: string)
	self.ToggleStickEvent:FireServer(slotId)
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

	-- Bases are fixed in the place file, so sweep them once. Each base drives its own stands as they
	-- come and go.
	for _, baseModel in workspace.Base:GetChildren() do
		self:_setupBase(baseModel)
	end

	-- One loop keeps every placed stick (and its ingredients) glued to its stand as the client
	-- animates the stand in and reflows the grid.
	RunService.Heartbeat:Connect(function(deltaTime: number)
		for _, stand in self._stands do
			stand:Update(deltaTime)
		end
	end)

	-- BaseId lands after the stands are already built (Base clones them before setting the attribute),
	-- and it changes when the local player is assigned or loses a base -- re-check every stand's prompt.
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:_refreshPrompts()
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
