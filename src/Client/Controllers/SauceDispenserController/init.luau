-- Dormant while sauce dispensers are postponed -- un-comment alongside SauceDispenserManager.

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

-- How long a streamed-in base gets to finish replicating the pieces _setupBase indexes.
local CHILD_TIMEOUT = 10

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

-- Tracks a base's dispenser slots once its folder has replicated. Models stream in non-atomically,
-- so the waits live here; the folder is then watched as well as swept, since slots come and go with
-- the Ghost interactables.
function SauceDispenserController:_setupBase(baseModel: Model)
	local interactables = baseModel:WaitForChild("Interactables", CHILD_TIMEOUT)
	local dispenserFolder = interactables and interactables:WaitForChild("SauceDispenser", CHILD_TIMEOUT)
	if not dispenserFolder then
		warn(`[SauceDispenser] {baseModel.Name}'s dispenser folder never replicated, it won't render`)
		return
	end

	-- Waiting above yields, so the base can have streamed back out in the meantime.
	if not baseModel.Parent then
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

-- Drops the SauceDispensers for a base that's streamed out or been removed. The folder's ChildRemoved
-- doesn't fire per slot when the whole base goes at once, so sweep them out by ancestry.
function SauceDispenserController:_removeBase(baseModel: Model)
	for slot in self._dispensers do
		if slot:IsDescendantOf(baseModel) then
			self:_removeDispenser(slot)
		end
	end
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

	-- Bases stream out and back in as brand-new instances, and at boot the folder's contents can still
	-- be in flight -- so watch the folder rather than sweeping it once. Off this thread because the
	-- loader runs every OnStart on one, and both the folder wait and _setupBase's child waits yield.
	task.spawn(function()
		local baseFolder = workspace:WaitForChild("Base")

		self._cleaner:Connect(baseFolder.ChildAdded, function(baseModel)
			self:_setupBase(baseModel)
		end)
		self._cleaner:Connect(baseFolder.ChildRemoved, function(baseModel)
			self:_removeBase(baseModel)
		end)

		-- _setupBase waits on the base's children, so keep the sweep off this thread too.
		for _, baseModel in baseFolder:GetChildren() do
			task.spawn(function()
				self:_setupBase(baseModel)
			end)
		end
	end)

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
