-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local RollingConfig = require(Shared.Config.Rolling)
local Ingredients = require(Shared.Config.Ingredients)

-- Controllers
local SoundController = require(script.Parent.SoundController)

-- Modules
local Base = require(script.Base)

--
local LocalPlayer = Players.LocalPlayer

-- How long a streamed-in base gets to finish replicating the pieces Base.new indexes (see _addBase).
local ROLLING_TIMEOUT = 10
local CHILD_TIMEOUT = 10

-- Tracks every base's rolling setup, drives their per-frame work, and owns the shared silhouette container the cycles black out under.

--
local IngredientRollingController = {
	RequestRollFunction = Network.Function("RequestRoll"),
	PurchaseIngredientEvent = Network.Event("PurchaseIngredient"),
	OnPurchasedEvent = Network.Event("OnIngredientPurchased"),

	-- Fires once per lever pull the server accepted.
	OnRollPerformed = Signal.new(),

	-- (ingredientId, price) on a currency buy; a Robux one is finished off a receipt and never reaches here
	OnIngredientBought = Signal.new(),

	_bases = {}, -- [model: Model] = Base
	_purchasing = {}, -- [standId] = the ingredient it was showing while a purchase is in flight

	_rollLocked = false, -- while true, no base offers its lever (see SetRollLocked)

	-- Every cycling ingredient in the place, under the one Highlight that blacks them out
	_silhouetteContainer = nil,

	-- Seconds since the last proximity sweep, accumulated by the render loop below
	_sweepElapsed = 0,

	_cleaner = Trove.new(),
	_characterCleaner = nil,
}

-- Asks for a roll, returning the pull's stamp and duration, or nil if refused. What each stand landed on rides the attributes.
function IngredientRollingController:RequestRoll(): (number?, number?)
	local success, rolledAt, duration = pcall(function()
		return self.RequestRollFunction:Invoke()
	end)

	if not success then
		warn(rolledAt)
		return nil
	end

	if rolledAt then
		self.OnRollPerformed:Fire()
	end

	return rolledAt, duration
end

-- Buys the ingredient on a stand. `ingredientId` is only kept so the purchase signal can name it.
function IngredientRollingController:RequestPurchase(standId: string, ingredientId: string)
	if self._purchasing[standId] then
		return
	end

	self._purchasing[standId] = ingredientId
	self.PurchaseIngredientEvent:FireServer(standId)
end

-- Re-checks every base's lever cue and stand prompt. Cheap, and it depends on the base and what's held.
function IngredientRollingController:RefreshInteractions()
	for _, base in self._bases do
		base:RefreshInteraction()
	end
end

-- Holds every lever shut, for the tutorial's beats before the one that asks for a roll.
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

-- Where a cycling ingredient is parented so it renders blacked out; moving it out is the reveal.
function IngredientRollingController:GetSilhouetteContainer(): Model
	return self._silhouetteContainer
end

-- Builds a Base once its pieces have replicated. The waits live here, so Base.new can trust its children.
function IngredientRollingController:_addBase(baseModel: Model)
	if self._bases[baseModel] then
		return
	end

	-- No warn when it never comes: a base without the folder is one the server skips too
	local rollingFolder = baseModel:WaitForChild("Rolling", ROLLING_TIMEOUT)
	if not rollingFolder then
		return
	end

	local lever = rollingFolder:WaitForChild("Lever", CHILD_TIMEOUT)
	local leverHandle = lever and lever:WaitForChild("Handle", CHILD_TIMEOUT)
	local standsFolder = rollingFolder:WaitForChild("Stands", CHILD_TIMEOUT)
	if not leverHandle or not standsFolder then
		warn(`[IngredientRolling] {baseModel.Name}'s rolling setup is incomplete, it won't render`)
		return
	end

	-- Waiting above yields, so the base can have streamed out or been built by a racing thread
	if not baseModel.Parent or self._bases[baseModel] then
		return
	end

	local base = Base.new(baseModel)
	self._bases[baseModel] = base
	self._cleaner:Add(base)
end

-- Drops the Base for a model that's streamed out or been removed.
function IngredientRollingController:_removeBase(baseModel: Model)
	local base = self._bases[baseModel]
	if not base then
		return
	end

	self._cleaner:Remove(base)
	self._bases[baseModel] = nil
end

function IngredientRollingController:OnStart()
	self._characterCleaner = self._cleaner:Construct(Trove)

	-- One Highlight for the lot -- several bases cycling would otherwise blow Roblox's budget game-wide. A Model, since only a Model can be adorned
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

	-- Off the container's contents, so a cancelled roll's clone releases the slot with nothing remembering to
	local function refreshSilhouette()
		silhouette.Enabled = container:FindFirstChildWhichIsA("Model") ~= nil
	end

	self._cleaner:Connect(container.ChildAdded, refreshSilhouette)
	self._cleaner:Connect(container.ChildRemoved, refreshSilhouette)

	-- Watched rather than swept once, and off this thread since the loader runs every OnStart on one
	task.spawn(function()
		local baseFolder = workspace:WaitForChild("Base")

		self._cleaner:Connect(baseFolder.ChildAdded, function(baseModel)
			self:_addBase(baseModel)
		end)
		self._cleaner:Connect(baseFolder.ChildRemoved, function(baseModel)
			self:_removeBase(baseModel)
		end)

		-- _addBase waits on the base's children, so keep the sweep off this thread too
		for _, baseModel in baseFolder:GetChildren() do
			task.spawn(function()
				self:_addBase(baseModel)
			end)
		end
	end)

	-- One loop for every base, with the range sweep on a timer folded in, so cost tracks what's nearby
	RunService.RenderStepped:Connect(function(deltaTime: number)
		self._sweepElapsed += deltaTime

		if self._sweepElapsed >= RollingConfig.PROXIMITY_INTERVAL then
			self._sweepElapsed = 0

			-- No character is no viewpoint, so every base reads as out of range and draws nothing
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

	-- Emptying the stand isn't ours -- the server drops the attribute, which clears it on every client
	self.OnPurchasedEvent:OnClientEvent(function(success: boolean, standId: string, discovered: boolean?)
		local ingredientId = self._purchasing[standId]
		self._purchasing[standId] = nil
		if not success then
			return
		end

		self.OnIngredientBought:Fire(ingredientId, Ingredients.GetIngredientFromId(ingredientId).Price)

		-- A first-ever pull already rings its discovery notification, so this would only stack on it
		if not discovered then
			SoundController:PlaySound("Purchase")
		end
	end)

	-- BaseId lands after the bases are built and moves on assignment, so re-check who carries prompts
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:RefreshInteractions()
	end)

	-- Equipping anything takes the lever's cue down, so track what's in their hands
	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_watchCharacter(character)
	end)
end

return IngredientRollingController
