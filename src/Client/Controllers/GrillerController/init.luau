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

-- The structure category grillers are, which is also the tag every placed one wears. The category and
-- not one model's id, so a second kind of griller renders through this controller with nothing changed.
local GRILLER_CATEGORY = "Grillers"

-- The parts a Grill has to have to do anything. They come off the structure's template, so they're
-- always there -- but a placed griller replicates in mid-session rather than existing from place-load,
-- so they're waited on rather than assumed (see _addGrill).
--
-- Knob isn't among them on purpose: the server streams a griller whole (Base:BuildStructure sets it
-- atomic), so nothing here is ever merely late, and a missing knob costs the owner the stove rather
-- than costing everyone the cook -- Grill warns for it and renders the rest.
local REQUIRED_DESCENDANTS = { "Grill", "StickAttachment", "GrillAttachment" }
local CHILD_TIMEOUT = 10

-- How long the skip has to be left alone between requests. The offer used to be a prompt with a hold on
-- it, which is what made it hard to brush past; it's a button on the cooking bar now, so a mashed one
-- would raise the same Robux purchase a dozen times over.
local SKIP_COOK_COOLDOWN = 1

--[[
    Renders the cook on every base's grillers and drives the owner's place/cook interaction.

    One Grill instance per placed griller, across every base, so a cooking skewer spins and browns for
    visitors too -- the server clones the static skewer model in and mirrors the cook state onto the
    griller's attributes, and the class animates it off those. The place/remove prompt and the cook
    knob only appear on grillers the local player owns.

    Grillers are structures a player builds rather than slots authored into their base, so they're
    found off the Griller tag: one appearing mid-session is picked up the same way as one that was
    already down when the client started, and the OwnerUserId attribute on it is what says whose it is.
]]

-- Waits for a named descendant of a griller, the way WaitForChild waits for a child. The two
-- attachments sit on Grill.Main.Base rather than on the griller itself, and WaitForChild only looks
-- one level down, so these are polled out against the same timeout instead.
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
	StartCookEvent = Network.Event("StartCooking"),
	StopCookEvent = Network.Event("StopCooking"),
	RequestSkipCookEvent = Network.Event("RequestSkipCook"),

	_grills = {}, -- [model: Instance] = Grill
	_cleaner = Trove.new(),
	_takeLocked = false, -- while true, no grill offers to hand a skewer back (see SetTakeLocked)
	_skipLocked = false, -- while true, no grill shows its Robux skip (see SetSkipLocked)
	_skipCookNextAt = 0, -- the clock the next skip request is allowed at, so a mashed button sends one
}

-- Builds a Grill for a placed griller, unless one already tracks it.
function GrillerController:_addGrill(model: Instance)
	if self._grills[model] then
		return
	end

	-- The server builds the griller complete before it tags it, and streams it atomically so it can't
	-- arrive in pieces either, so this is belt-and-braces -- but a Grill built without them is dead for
	-- good rather than merely late, which is worth waiting to rule out.
	for _, name in REQUIRED_DESCENDANTS do
		if not waitForDescendant(model, name, CHILD_TIMEOUT) then
			warn(`[Griller] {model.Name} has no {name}, it won't render`)
			return
		end
	end

	-- Waiting above yields, so the griller can have been taken away in the meantime.
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

-- Asks the server to put the equipped filled skewer on this grill, or take the finished one back off.
function GrillerController:RequestToggle(uid: string)
	self.ToggleGrillEvent:FireServer(uid)
end

-- Asks the server to light the stove under this grill's eligible skewer.
function GrillerController:RequestCook(uid: string)
	self.StartCookEvent:FireServer(uid)
end

-- Asks the server to turn this grill's stove back off, settling the skewer at whatever the bar has
-- reached. Deliberately unthrottled: this is a timing call, and the server takes the player's ping off
-- the moment it lands, so anything held back here would land as a worse cook than they aimed for.
function GrillerController:RequestStopCook(uid: string)
	self.StopCookEvent:FireServer(uid)
end

-- Asks the server to raise the Robux prompt for skipping the cook running on this grill. Opened
-- server-side rather than through ShopController so the grill it was raised from is remembered there:
-- the receipt says nothing about which cook was being bought out.
--
-- Throttled, unlike the stop above: this one costs money rather than timing, so the cost of holding a
-- press back is nothing and the cost of letting a dozen through is a stream of purchase prompts. The
-- server holds the same window (see GrillerManager:PromptSkipCookProduct) -- this only saves the traffic.
function GrillerController:RequestSkipCook(uid: string)
	if os.clock() < self._skipCookNextAt then
		return
	end
	self._skipCookNextAt = os.clock() + SKIP_COOK_COOLDOWN

	self.RequestSkipCookEvent:FireServer(uid)
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
-- class already computes rather than reaching in and disabling prompts, because the take prompt rides on
-- the skewer model -- which the server rebuilds on every record write, taking the prompt with it -- so
-- anything holding a captured instance would be handing back to one that's already gone.
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

-- Holds every grill's Robux skip off, so a cook that's meant to be waited out can't be bought out. The
-- skip is a button on the cooking bar rather than a prompt, so TutorialController:DisablePrompts has
-- nothing to hold it by -- this is its equivalent, gating the eligibility the class already computes.
--
-- Set by the tutorial across the beat teaching the cook's timing: a step asking the player to watch the
-- bar shouldn't be offering to sell them out of the thing it's teaching.
function GrillerController:SetSkipLocked(locked: boolean)
	if self._skipLocked == locked then
		return
	end

	self._skipLocked = locked
	self:RefreshInteractions()
end

-- Whether the skip is currently held off. Read by Grill when it works out what a slot is offering.
function GrillerController:IsSkipLocked(): boolean
	return self._skipLocked
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

	-- A griller placed on any base wires itself up here, whether it went down before this client
	-- started or while it's running.
	self._cleaner:Connect(CollectionService:GetInstanceAddedSignal(GRILLER_CATEGORY), function(model)
		self:_addGrill(model)
	end)

	self._cleaner:Connect(CollectionService:GetInstanceRemovedSignal(GRILLER_CATEGORY), function(model)
		self:_removeGrill(model)
	end)

	-- _addGrill waits on the griller's children, so keep the sweep off the main thread.
	for _, model in CollectionService:GetTagged(GRILLER_CATEGORY) do
		task.spawn(function()
			self:_addGrill(model)
		end)
	end

	-- One loop drives every grill's cook animation.
	RunService.RenderStepped:Connect(function()
		for _, grill in self._grills do
			grill:Update()
		end
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
