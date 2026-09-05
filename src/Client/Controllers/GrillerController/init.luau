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
local Grill = require(script.Grill)

--
local LocalPlayer = Players.LocalPlayer

-- The category, not one model's id, so a second kind of griller renders here unchanged
local GRILLER_CATEGORY = "Grillers"

-- The parts a Grill needs. Waited on rather than assumed, since a griller replicates in mid-session
local REQUIRED_DESCENDANTS = { "Grill", "StickAttachment", "GrillAttachment" }
local CHILD_TIMEOUT = 10

-- How long the skip must be left alone -- it's a button now, so a mashed one would raise a dozen prompts
local SKIP_COOK_COOLDOWN = 1

-- Tracks every placed griller as a Grill, drives their cook animations, and owns the tutorial's locks on the take and skip.

-- Waits for a named descendant, since the attachments sit deeper than WaitForChild looks.
local function waitForDescendant(model: Instance, name: string, timeout: number): Instance?
	local deadline = os.clock() + timeout
	local found = model:FindFirstChild(name, true)

	while not found and os.clock() < deadline do
		task.wait()
		found = model:FindFirstChild(name, true)
	end

	return found
end

--
local GrillerController = {
	ToggleGrillEvent = Network.Event("ToggleGrillStick"),
	RequestSkipCookEvent = Network.Event("RequestSkipCook"),

	_grills = {}, -- [model: Instance] = Grill
	_cleaner = Trove.new(),
	_takeLocked = false, -- while true, no idle grill offers to hand a skewer back (see SetTakeLocked)
	_skipLocked = false, -- while true, no grill shows its Robux skip (see SetSkipLocked)
	_stopLocked = false, -- while true, no cooking grill offers to hand a skewer back (see SetStopLocked)
	_skipCookNextAt = 0, -- the clock the next skip request is allowed at, so a mashed button sends one
}

-- Builds a Grill for a placed griller, unless one already tracks it.
function GrillerController:_addGrill(model: Instance)
	if self._grills[model] then
		return
	end

	-- Belt-and-braces, but a Grill built without them is dead for good rather than merely late
	for _, name in REQUIRED_DESCENDANTS do
		if not waitForDescendant(model, name, CHILD_TIMEOUT) then
			warn(`[Griller] {model.Name} has no {name}, it won't render`)
			return
		end
	end

	-- Waiting above yields, so the griller can have been taken away in the meantime
	if not model.Parent or self._grills[model] then
		return
	end

	local grill = Grill.new(model)
	self._grills[model] = grill
	self._cleaner:Add(grill)
end

-- Drops the Grill for a griller that's been taken away.
function GrillerController:_removeGrill(model: Instance)
	local grill = self._grills[model]
	if not grill then
		return
	end

	self._cleaner:Remove(grill)
	self._grills[model] = nil
end

-- Places or takes the skewer on this grill. Deliberately unthrottled -- the take is a timing call the server ping-corrects.
function GrillerController:RequestToggle(uid: string)
	self.ToggleGrillEvent:FireServer(uid)
end

-- Asks the server to raise the skip prompt, which is where the grill is remembered. Throttled -- this costs money, not timing.
function GrillerController:RequestSkipCook(uid: string)
	if os.clock() < self._skipCookNextAt then
		return
	end
	self._skipCookNextAt = os.clock() + SKIP_COOK_COOLDOWN

	self.RequestSkipCookEvent:FireServer(uid)
end

-- Re-checks every grill's prompts and highlights. Cheap, and it depends on the base and what's held.
function GrillerController:RefreshInteractions()
	for _, grill in self._grills do
		grill:RefreshInteraction()
	end
end

-- Holds the take off on idle grills, gating eligibility rather than the prompt -- the server rebuilds the skewer it rides on.
function GrillerController:SetTakeLocked(locked: boolean)
	if self._takeLocked == locked then
		return
	end

	self._takeLocked = locked
	self:RefreshInteractions()
end

-- Whether taking is held off. Read by Grill when it works out what a slot is offering.
function GrillerController:IsTakeLocked(): boolean
	return self._takeLocked
end

-- Holds every grill's skip off. Set for the tutorial's whole run, its one cook spanning two beats.
function GrillerController:SetSkipLocked(locked: boolean)
	if self._skipLocked == locked then
		return
	end

	self._skipLocked = locked
	self:RefreshInteractions()
end

-- Whether the skip is held off. Read by Grill when it works out what a slot is offering.
function GrillerController:IsSkipLocked(): boolean
	return self._skipLocked
end

-- Holds the take off on cooking grills. Split from SetTakeLocked because the tutorial wants one without the other.
function GrillerController:SetStopLocked(locked: boolean)
	if self._stopLocked == locked then
		return
	end

	self._stopLocked = locked
	self:RefreshInteractions()
end

-- Whether stopping is held off. Read by Grill when it works out what a slot is offering.
function GrillerController:IsStopLocked(): boolean
	return self._stopLocked
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

	-- A griller placed on any base wires itself up here, before this client started or while it runs
	self._cleaner:Connect(CollectionService:GetInstanceAddedSignal(GRILLER_CATEGORY), function(model)
		self:_addGrill(model)
	end)

	self._cleaner:Connect(CollectionService:GetInstanceRemovedSignal(GRILLER_CATEGORY), function(model)
		self:_removeGrill(model)
	end)

	-- _addGrill waits on the griller's children, so keep the sweep off the main thread
	for _, model in CollectionService:GetTagged(GRILLER_CATEGORY) do
		task.spawn(function()
			self:_addGrill(model)
		end)
	end

	-- One loop drives every grill's cook animation
	RunService.RenderStepped:Connect(function()
		for _, grill in self._grills do
			grill:Update()
		end
	end)

	-- Equipping or unequipping a raw skewer changes whether a free griller should be lit
	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_watchCharacter(character)
	end)
end

return GrillerController
