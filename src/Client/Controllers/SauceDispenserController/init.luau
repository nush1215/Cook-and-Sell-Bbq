-- Sauce dispensers are postponed to a future update: the models are out of the workspace and the server
-- side is dormant, so there's nothing to render or fire at. Everything below is intact -- un-comment it
-- alongside SauceDispenserManager to bring it back.

--[==[
-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

-- Modules
local SauceDispenser = require(script.SauceDispenser)

--
local LocalPlayer = Players.LocalPlayer

--[[
    Renders the pour on every base's sauce dispensers and drives the owner's place/sauce interaction.

    One SauceDispenser instance per dispenser slot, across every base, so a pour plays out for visitors
    too -- the server clones the bottle and the plated skewer in and mirrors the state onto the slot's
    attributes, and the class animates the bottle off those. The place/take prompt, the fill prompt and
    the bottle's click only appear on the local player's own base.
]]

--
local SauceDispenserController = {
	ToggleSkewerEvent = Network.Event("ToggleSauceSkewer"),
	StartSaucingEvent = Network.Event("StartSaucing"),
	RefillEvent = Network.Event("RefillSauceDispenser"),
	PurchaseUnlockUpgradeEvent = Network.Event("PurchaseUnlockUpgrade"),
	UpgradeSizeEvent = Network.Event("UpgradeSauceDispenserSize"),

	_dispensers = {}, -- [slot: Instance] = SauceDispenser
	_cleaner = Trove.new(),
}

-- Builds a SauceDispenser for a dispenser slot, unless one already tracks it.
function SauceDispenserController:_addDispenser(slot: Instance, baseId: string)
	if self._dispensers[slot] then
		return
	end

	local dispenser = SauceDispenser.new(slot, baseId)
	self._dispensers[slot] = dispenser
	self._cleaner:Add(dispenser)
end

-- Drops the SauceDispenser for a slot the base took away.
function SauceDispenserController:_removeDispenser(slot: Instance)
	local dispenser = self._dispensers[slot]
	if not dispenser then
		return
	end

	self._cleaner:Remove(dispenser)
	self._dispensers[slot] = nil
end

-- Tracks a base's dispenser slots. Dispensers are static Ghost interactables always in the folder, so
-- a one-off sweep plus watching for changes covers them.
function SauceDispenserController:_setupBase(baseModel: Model)
	local interactables = baseModel:FindFirstChild("Interactables")
	local dispenserFolder = interactables and interactables:FindFirstChild("SauceDispenser")
	if not dispenserFolder then
		return
	end

	for _, slot in dispenserFolder:GetChildren() do
		if tonumber(slot.Name) then
			self:_addDispenser(slot, baseModel.Name)
		end
	end

	self._cleaner:Connect(dispenserFolder.ChildAdded, function(slot)
		if tonumber(slot.Name) then
			self:_addDispenser(slot, baseModel.Name)
		end
	end)

	self._cleaner:Connect(dispenserFolder.ChildRemoved, function(slot)
		self:_removeDispenser(slot)
	end)
end

-- Asks the server to put the equipped cooked skewer on this dispenser's plate, or take the one
-- sitting there back off.
function SauceDispenserController:RequestToggle(slotId: string)
	self.ToggleSkewerEvent:FireServer(slotId)
end

-- Asks the server to pour this dispenser's sauce over the skewer on its plate.
function SauceDispenserController:RequestSauce(slotId: string)
	self.StartSaucingEvent:FireServer(slotId)
end

-- Asks the server to spend the sauce bottle the player is holding on this dispenser, filling it.
function SauceDispenserController:RequestRefill(slotId: string)
	self.RefillEvent:FireServer(slotId)
end

-- Asks the server to unlock this base's sauce dispenser (its unlock sign's buy button).
function SauceDispenserController:RequestUnlockDispenser()
	self.PurchaseUnlockUpgradeEvent:FireServer("SauceDispenser")
end

-- Asks the server to upgrade this dispenser to the next size up (its size sign's buy button).
function SauceDispenserController:RequestUpgradeSize(slotId: string)
	self.UpgradeSizeEvent:FireServer(slotId)
end

-- Re-checks every dispenser's prompts/highlights (ownership + eligibility). Cheap, and it depends
-- on both the local player's base and what they're holding, so it's called whenever either changes.
function SauceDispenserController:_refreshInteractions()
	for _, dispenser in self._dispensers do
		dispenser:RefreshInteraction()
	end
end

-- Watches the local character's tools so a dispenser lights up as they equip a cooked skewer or a
-- sauce bottle.
function SauceDispenserController:_watchCharacter(character: Model)
	self._characterCleaner:Clean()

	self._characterCleaner:Connect(character.ChildAdded, function(child)
		if child:IsA("Tool") then
			self:_refreshInteractions()
		end
	end)
	self._characterCleaner:Connect(character.ChildRemoved, function(child)
		if child:IsA("Tool") then
			self:_refreshInteractions()
		end
	end)

	self:_refreshInteractions()
end

function SauceDispenserController:OnStart()
	self._characterCleaner = self._cleaner:Construct(Trove)

	-- Bases are fixed in the place file, so sweep them once. Each base drives its own dispensers.
	for _, baseModel in workspace.Base:GetChildren() do
		self:_setupBase(baseModel)
	end

	-- BaseId lands after the dispensers are already built, and changes when the local player is
	-- assigned or loses a base -- re-check which should show a prompt.
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:_refreshInteractions()
	end)

	-- Equipping/unequipping a cooked skewer or a sauce bottle changes which dispensers should be lit up.
	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_watchCharacter(character)
	end)
end

return SauceDispenserController
]==]

return {}
