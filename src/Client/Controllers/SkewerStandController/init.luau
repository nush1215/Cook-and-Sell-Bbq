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
local SkewerStand = require(script.SkewerStand)

--
local LocalPlayer = Players.LocalPlayer

-- How long a streamed-in base gets to finish replicating the pieces _setupBase indexes.
local CHILD_TIMEOUT = 10

--[[
    Renders the cooked skewers placed on every base's sell-stall SkewerStand and drives the owner's
    prompts.

    One SkewerStand instance per base, so visitors see placed skewers too -- the server writes the
    placed skewers to a PlacedSkewers attribute on the stand part and the class renders them. Prompts
    are the class's own concern and only appear on the local player's own base: a place prompt on the
    stand (enabled only while holding a cooked skewer) and a "take it back" prompt on each placed skewer.
]]

--
local SkewerStandController = {
	PlaceSkewerEvent = Network.Event("PlaceSkewerOnStand"),
	RemoveSkewerEvent = Network.Event("RemoveSkewerFromStand"),

	_stands = {}, -- [baseModel: Model] = SkewerStand
	_cleaner = Trove.new(),
	_takeLocked = false, -- while true, no stand offers a placed skewer back (see SetTakeLocked)
}

-- Wires up a base's sell-stall stand once the pieces have replicated, unless one already tracks it.
-- Models stream in non-atomically, so the waits live here and SkewerStand.new keeps trusting its
-- children.
function SkewerStandController:_setupBase(baseModel: Model)
	if self._stands[baseModel] then
		return
	end

	local stalls = baseModel:WaitForChild("Stalls", CHILD_TIMEOUT)
	local sellStall = stalls and stalls:WaitForChild("SellStall", CHILD_TIMEOUT)
	local stand = sellStall and sellStall:WaitForChild("SkewerStand", CHILD_TIMEOUT)
	if not stand then
		warn(`[SkewerStand] {baseModel.Name}'s stand setup is incomplete, it won't render`)
		return
	end

	-- Waiting above yields, so the base can have streamed back out (or been built by a racing thread)
	-- in the meantime.
	if not baseModel.Parent or self._stands[baseModel] then
		return
	end

	local instance = SkewerStand.new(stand, baseModel.Name, sellStall)
	self._stands[baseModel] = instance
	self._cleaner:Add(instance)
end

-- Drops the stand for a base that's streamed out or been removed.
function SkewerStandController:_removeBase(baseModel: Model)
	local instance = self._stands[baseModel]
	if not instance then
		return
	end

	self._cleaner:Remove(instance)
	self._stands[baseModel] = nil
end

-- Asks the server to place the equipped cooked skewer on this base's stand.
function SkewerStandController:RequestPlace()
	self.PlaceSkewerEvent:FireServer()
end

-- Asks the server to take the placed skewer at `index` back off this base's stand.
function SkewerStandController:RequestRemove(index: number)
	self.RemoveSkewerEvent:FireServer(index)
end

-- Re-checks every stand's prompts (ownership + the place prompt's enabled state). Cheap, and the place
-- prompt depends on what the local player is holding, so it's called whenever their base or equipped
-- tool changes.
function SkewerStandController:_refreshPrompts()
	for _, stand in self._stands do
		stand:RefreshPrompt()
	end
end

-- Holds every stand's take back off, so a skewer put out for sale stays out. Gates the eligibility the
-- class already computes rather than reaching in and disabling the prompts: there's one per placed
-- skewer, each built and torn down with the model it rides on, so anything holding captured instances
-- would be holding the wrong ones a moment later.
--
-- Set by the tutorial from the skewer going out to the sale going through: the beat after it is a wait,
-- and taking back the thing they're waiting on has nothing to offer them but a dead end.
function SkewerStandController:SetTakeLocked(locked: boolean)
	if self._takeLocked == locked then
		return
	end

	self._takeLocked = locked
	self:_refreshPrompts()
end

-- Whether taking placed skewers back is currently held off. Read by SkewerStand as it builds its prompts.
function SkewerStandController:IsTakeLocked(): boolean
	return self._takeLocked
end

-- Watches the local character's tools so the place prompt enables/disables as they equip a skewer.
function SkewerStandController:_watchCharacter(character: Model)
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

function SkewerStandController:OnStart()
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

	-- BaseId lands after the stands are already built, and it changes when the local player is assigned
	-- or loses a base -- re-check every stand's prompts.
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:_refreshPrompts()
	end)

	-- Equipping/unequipping a skewer changes whether the place prompt should show.
	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_watchCharacter(character)
	end)
end

return SkewerStandController
