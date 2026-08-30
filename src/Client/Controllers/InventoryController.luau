-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Controllers
local SoundController = require(script.Parent.SoundController)

-- Modules
local Modules = script.Parent.Parent.Modules

--
local LocalPlayer = Players.LocalPlayer

--
local InventoryController = {
	_satchel = nil,
	_characterCleaner = Trove.new(), -- holds the current character's tool watcher
}

function InventoryController:ShowInventory()
	self._satchel:SetBackpackEnabled(true)
end

function InventoryController:HideInventory()
	self._satchel:SetBackpackEnabled(false)
end

-- The hotbar or inventory frame a tool currently sits in, or nil if it has no slot. For anything that
-- wants to point at the slot rather than at what's in it -- the tutorial lights the one holding the
-- tool it's asking the player to equip.
function InventoryController:GetSlotFrame(tool: Tool): GuiObject?
	return self._satchel:GetSlotFrame(tool)
end

-- Rings the equip sound on every tool the local player pulls out. Equipping parents the tool to the
-- character, so that one signal covers every kind -- sticks, skewers, ingredients and sauce bottles all
-- land here without each having to bind its own.
function InventoryController:_watchCharacter(character: Model)
	self._characterCleaner:Clean()

	self._characterCleaner:Connect(character.ChildAdded, function(child)
		if child:IsA("Tool") then
			SoundController:PlaySound("ToolEquip")
		end
	end)
end

function InventoryController:OnInit()
	self._satchel = require(Modules.Satchel)
end

function InventoryController:OnStart()
	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end

	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_watchCharacter(character)
	end)
end

return InventoryController
