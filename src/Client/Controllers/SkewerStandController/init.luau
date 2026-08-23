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

	_stands = {}, -- [part: BasePart] = SkewerStand
	_cleaner = Trove.new(),
	_takeLocked = false, -- while true, no stand offers a placed skewer back (see SetTakeLocked)
}

-- Wires up a base's sell-stall stand, unless one already tracks it. The part is fixed in the place
-- file, so there's nothing to add or remove later -- just build it once.
function SkewerStandController:_setupBase(baseModel: Model)
	local stalls = baseModel:FindFirstChild("Stalls")
	local sellStall = stalls and stalls:FindFirstChild("SellStall")
	local stand = sellStall and sellStall:FindFirstChild("SkewerStand")
	if not stand then
		return
	end

	if self._stands[stand] then
		return
	end

	local instance = SkewerStand.new(stand, baseModel.Name, sellStall)
	self._stands[stand] = instance
	self._cleaner:Add(instance)
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

	-- Bases are fixed in the place file, so sweep them once. The stand part is static, so nothing has
	-- to keep the placed skewers glued after they're seated.
	for _, baseModel in workspace.Base:GetChildren() do
		self:_setupBase(baseModel)
	end

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
