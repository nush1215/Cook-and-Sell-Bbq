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
local RollingConfig = require(Shared.Config.Rolling)

-- Controllers
local SoundController = require(script.Parent.SoundController)

-- Modules
local Base = require(script.Base)

--
local LocalPlayer = Players.LocalPlayer

--[[
    Renders the rolling stands on every base and drives the owner's lever.

    One Base instance per base in the place, across all of them, so a pull is something visitors can
    watch rather than something only the puller sees. The server mirrors each roll onto the stand
    models' attributes and the stands render themselves off those -- player data only replicates to
    the player it belongs to, so those attributes are the one channel a visitor's client can read a
    roll through, and they're just as good at telling someone who walked up late what's already
    sitting on a stand.

    The lever's prompt and the stands' buy prompts only go up on the local player's own base;
    everyone else just watches.

    A roll clones a model per cycle step per stand, which makes it far and away the most expensive
    thing on a base -- so what gets drawn is banded on how near the local player is, and the sweep
    that works that out is folded into the same loop that animates them.
]]

--
local IngredientRollingController = {
	RequestRollFunction = Network.Function("RequestRoll"),
	PurchaseIngredientEvent = Network.Event("PurchaseIngredient"),
	OnPurchasedEvent = Network.Event("OnIngredientPurchased"),

	_bases = {}, -- [baseId] = Base
	_purchasing = {}, -- [standId] = true while a purchase is in flight

	_rollLocked = false, -- while true, no base offers its lever (see SetRollLocked)

	-- Holds every cycling ingredient on every base, under the one Highlight that blacks them out.
	_silhouetteContainer = nil,

	-- Seconds since the last proximity sweep, accumulated by the render loop below.
	_sweepElapsed = 0,

	_cleaner = Trove.new(),
	_characterCleaner = nil,
}

-- Asks the server for a roll, and hands back the server time the pull it stamped landed on and how
-- long that pull runs for -- or nil if it turned the pull down, which is what tells the lever to
-- re-arm rather than wait one out. The duration is the server's rather than something worked out
-- here, since it's what the claim is gated on. What each stand rolled doesn't come back this way: it
-- goes onto the stands' attributes, so every client gets it rather than only the puller.
function IngredientRollingController:RequestRoll(): (number?, number?)
	local success, rolledAt, duration = pcall(function()
		return self.RequestRollFunction:Invoke()
	end)

	if not success then
		warn(rolledAt)
		return nil
	end

	return rolledAt, duration
end

-- Asks the server to buy the ingredient currently sitting on a stand.
function IngredientRollingController:RequestPurchase(standId: string)
	if self._purchasing[standId] then
		return
	end

	self._purchasing[standId] = true
	self.PurchaseIngredientEvent:FireServer(standId)
end

-- Re-checks every base's lever cue and every stand's buy prompt. Cheap, and all of it depends on which
-- base the local player owns and what they're holding, so it runs whenever either changes.
function IngredientRollingController:RefreshInteractions()
	for _, base in self._bases do
		base:RefreshInteraction()
	end
end

-- Holds every lever shut: no prompt, no cue, and a pull already in flight is turned away. The tutorial
-- takes this for the beats before the one that asks for a roll.
function IngredientRollingController:SetRollLocked(locked: boolean)
	if self._rollLocked == locked then
		return
	end

	self._rollLocked = locked
	self:RefreshInteractions()
end

function IngredientRollingController:IsRollLocked(): boolean
	return self._rollLocked
end

-- Watches the local character's tools so the lever goes dark as soon as they pick something up.
function IngredientRollingController:_watchCharacter(character: Model)
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

-- Where a stand parents an ingredient it's still cycling, so it renders blacked out. Moving one out
-- again is what reveals it -- see Stand.PlayRoll.
function IngredientRollingController:GetSilhouetteContainer(): Model
	return self._silhouetteContainer
end

function IngredientRollingController:OnStart()
	self._characterCleaner = self._cleaner:Construct(Trove)

	-- Every cycling ingredient in the place goes in here, under this one Highlight, so a bank of
	-- stands costs one of Roblox's thirty-odd rendered highlights rather than one each -- several
	-- bases cycling six stands apiece would blow that budget, silently, by stopping outlines
	-- game-wide. A Model rather than a Folder because only a Model can be adorned.
	local container = Instance.new("Model")
	container.Name = "RollingSilhouettes"
	container.Parent = workspace

	self._silhouetteContainer = container
	self._cleaner:Add(container)

	local silhouette = Instance.new("Highlight")
	silhouette.OutlineTransparency = 1
	silhouette.FillTransparency = 0
	silhouette.FillColor = Color3.fromRGB(0, 0, 0)
	silhouette.DepthMode = Enum.HighlightDepthMode.Occluded
	silhouette.Adornee = container
	silhouette.Enabled = false
	silhouette.Parent = container

	-- Driven off what's actually in the container rather than by the stands, so a clone dropped by a
	-- cancelled roll releases the slot with nothing having to remember to. Disabled rather than left
	-- empty so an idle container doesn't hold one of those slots.
	local function refreshSilhouette()
		silhouette.Enabled = container:FindFirstChildWhichIsA("Model") ~= nil
	end

	self._cleaner:Connect(container.ChildAdded, refreshSilhouette)
	self._cleaner:Connect(container.ChildRemoved, refreshSilhouette)

	-- Bases are fixed in the place file, so sweep them once. Each one drives its own lever and stands.
	-- A base without the folder is one the server skips too rather than something it guarantees, and
	-- this now runs across every base rather than only the one we know the player owns -- so let it go
	-- without instead of taking the whole controller down with it.
	for _, baseModel in workspace.Base:GetChildren() do
		if not baseModel:FindFirstChild("Rolling") then
			continue
		end

		local base = Base.new(baseModel)
		self._bases[baseModel.Name] = base
		self._cleaner:Add(base)
	end

	-- One loop drives every base, and works out which of them are near enough to be worth drawing on a
	-- timer folded into it -- running that check per base per frame would cost more than the drawing it
	-- exists to avoid. Each base then skips its own work if the sweep put it out of range, so what this
	-- costs tracks the bases around the player rather than the number in the place.
	RunService.RenderStepped:Connect(function(deltaTime: number)
		self._sweepElapsed += deltaTime

		if self._sweepElapsed >= RollingConfig.PROXIMITY_INTERVAL then
			self._sweepElapsed = 0

			-- No character is no viewpoint, so every base reads as out of range and draws nothing.
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")

			for _, base in self._bases do
				base:RefreshProximity(root and root.Position)
			end
		end

		for _, base in self._bases do
			base:Update(deltaTime)
		end
	end)

	-- The server tells us whether each purchase actually went through. Emptying the stand isn't ours to
	-- do here -- the server drops the stand's attribute on a real purchase, which clears it on every
	-- client at once and flies the ingredient to whoever bought it.
	self.OnPurchasedEvent:OnClientEvent(function(success: boolean, standId: string, discovered: boolean?)
		self._purchasing[standId] = nil
		if not success then
			return
		end

		-- A first-ever pull already rings through its discovery notification, so the purchase sound
		-- would only stack on top of it.
		if not discovered then
			SoundController:PlaySound("Purchase")
		end
	end)

	-- BaseId lands after the bases are already built, and changes when the local player is assigned or
	-- loses one -- re-check which base should be carrying prompts.
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:RefreshInteractions()
	end)

	-- Equipping anything takes the lever's cue down, so track what's in their hands.
	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_watchCharacter(character)
	end)
end

return IngredientRollingController
