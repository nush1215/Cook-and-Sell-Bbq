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
local Grill = require(script.Grill)

--
local LocalPlayer = Players.LocalPlayer

--[[
    Renders the cook on every base's grillers and drives the owner's place/cook interaction.

    One Grill instance per griller slot, across every base, so a cooking skewer spins and browns for
    visitors too -- the server clones the static skewer model in and mirrors the cook state onto the
    slot's attributes, and the class animates it off those. The place/remove prompt and the cook knob
    only appear on the local player's own base.
]]

--
local GrillerController = {
	ToggleGrillEvent = Network.Event("ToggleGrillStick"),
	StartCookEvent = Network.Event("StartCooking"),
	StopCookEvent = Network.Event("StopCooking"),
	PurchaseUnlockUpgradeEvent = Network.Event("PurchaseUnlockUpgrade"),
	PurchaseCookSpeedUpgradeEvent = Network.Event("PurchaseCookSpeedUpgrade"),
	RequestCookSpeedProductEvent = Network.Event("RequestCookSpeedProduct"),
	RequestSkipCookEvent = Network.Event("RequestSkipCook"),

	_grills = {}, -- [slot: Instance] = Grill
	_cleaner = Trove.new(),
	_takeLocked = false, -- while true, no grill offers to hand a skewer back (see SetTakeLocked)
}

-- Builds a Grill for a griller slot, unless one already tracks it.
function GrillerController:_addGrill(slot: Instance, baseId: string)
	if self._grills[slot] then
		return
	end

	local grill = Grill.new(slot, baseId)
	self._grills[slot] = grill
	self._cleaner:Add(grill)
end

-- Drops the Grill for a slot the base took away.
function GrillerController:_removeGrill(slot: Instance)
	local grill = self._grills[slot]
	if not grill then
		return
	end

	self._cleaner:Remove(grill)
	self._grills[slot] = nil
end

-- Tracks a base's griller slots. Grillers are static Ghost interactables always in the folder, so a
-- one-off sweep plus watching for changes covers them.
function GrillerController:_setupBase(baseModel: Model)
	local interactables = baseModel:FindFirstChild("Interactables")
	local grillFolder = interactables and interactables:FindFirstChild("Grillers")
	if not grillFolder then
		return
	end

	for _, slot in grillFolder:GetChildren() do
		if tonumber(slot.Name) then
			self:_addGrill(slot, baseModel.Name)
		end
	end

	self._cleaner:Connect(grillFolder.ChildAdded, function(slot)
		if tonumber(slot.Name) then
			self:_addGrill(slot, baseModel.Name)
		end
	end)

	self._cleaner:Connect(grillFolder.ChildRemoved, function(slot)
		self:_removeGrill(slot)
	end)
end

-- Asks the server to put the equipped filled skewer on this grill, or take the finished one back off.
function GrillerController:RequestToggle(slotId: string)
	self.ToggleGrillEvent:FireServer(slotId)
end

-- Asks the server to light the stove under this grill's eligible skewer.
function GrillerController:RequestCook(slotId: string)
	self.StartCookEvent:FireServer(slotId)
end

-- Asks the server to turn this grill's stove back off, settling the skewer at whatever the bar has
-- reached. Deliberately unthrottled: this is a timing call, and the server takes the player's ping off
-- the moment it lands, so anything held back here would land as a worse cook than they aimed for.
function GrillerController:RequestStopCook(slotId: string)
	self.StopCookEvent:FireServer(slotId)
end

-- Asks the server to buy the next grill. Only the next locked grill ever wears an unlock sign, so the
-- sequential unlock purchase is always the one its sign is priced at.
function GrillerController:RequestUnlockGrill()
	self.PurchaseUnlockUpgradeEvent:FireServer("Griller")
end

-- Asks the server to buy the next CookSpeed level on this grill.
function GrillerController:RequestCookSpeedUpgrade(slotId: string)
	self.PurchaseCookSpeedUpgradeEvent:FireServer(slotId)
end

-- Asks the server to raise the Robux prompt for this grill's next CookSpeed level. The prompt is opened
-- server-side rather than through ShopController so the grill it was raised from is remembered there --
-- a cook-speed product is a price band shared by several levels, and its receipt says nothing about which
-- grill was being upgraded.
function GrillerController:RequestCookSpeedUpgradeProduct(slotId: string)
	self.RequestCookSpeedProductEvent:FireServer(slotId)
end

-- Asks the server to raise the Robux prompt for skipping the cook running on this grill. Opened
-- server-side for the same reason the cook-speed one is: the grill it was raised from is remembered
-- there, and the receipt says nothing about which cook was being bought out.
function GrillerController:RequestSkipCook(slotId: string)
	self.RequestSkipCookEvent:FireServer(slotId)
end

-- Re-checks every grill's prompt/knob/highlights (ownership + eligibility). Cheap, and it depends on
-- both the local player's base and what they're holding, so it's called whenever either changes.
-- Public so anything that has forced a prompt off itself can hand control back rather than guessing
-- what state to restore it to (see TutorialController:DisablePrompts).
function GrillerController:RefreshInteractions()
	for _, grill in self._grills do
		grill:RefreshInteraction()
	end
end

-- Holds every grill's take off, so a skewer that's been put down stays put. Gates the eligibility the
-- class already computes rather than reaching in and disabling prompts, because taking is offered from
-- two attachments and one of those prompts is built and torn down as eligibility changes -- so anything
-- holding captured instances would race its creation and have nothing to hand back to.
--
-- Set by the tutorial across the beat between placing a BBQ and lighting it: the stove is the only thing
-- being asked for there, and a prompt offering to undo the step they just finished is the one other
-- thing in reach.
function GrillerController:SetTakeLocked(locked: boolean)
	if self._takeLocked == locked then
		return
	end

	self._takeLocked = locked
	self:RefreshInteractions()
end

-- Whether taking is currently held off. Read by Grill when it works out what a slot is offering.
function GrillerController:IsTakeLocked(): boolean
	return self._takeLocked
end

-- Watches the local character's tools so a free griller lights up as they equip a raw skewer.
function GrillerController:_watchCharacter(character: Model)
	self._characterCleaner:Clean()

	self._characterCleaner:Connect(character.ChildAdded, function(child)
		if child:IsA("Tool") then
			self:RefreshInteractions()
		end
	end)
	self._characterCleaner:Connect(character.ChildRemoved, function(child)
		if child:IsA("Tool") then
			self:RefreshInteractions()
		end
	end)

	self:RefreshInteractions()
end

function GrillerController:OnStart()
	self._characterCleaner = self._cleaner:Construct(Trove)

	-- Bases are fixed in the place file, so sweep them once. Each base drives its own grillers.
	for _, baseModel in workspace.Base:GetChildren() do
		self:_setupBase(baseModel)
	end

	-- One loop drives every grill's cook animation.
	RunService.RenderStepped:Connect(function()
		for _, grill in self._grills do
			grill:Update()
		end
	end)

	-- BaseId lands after the grills are already built, and changes when the local player is assigned or
	-- loses a base -- re-check which grills should show a prompt/knob.
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:RefreshInteractions()
	end)

	-- Equipping/unequipping a raw skewer changes whether a free griller should be lit up.
	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_watchCharacter(character)
	end)
end

return GrillerController
