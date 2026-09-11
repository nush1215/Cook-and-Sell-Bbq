-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Sticks = require(Shared.Config.Sticks)
local Ingredients = require(Shared.Config.Ingredients)
local Highlights = require(Shared.Config.Highlights)
local Structures = require(Shared.Config.Structures)
local EmployeeHut = require(Shared.Config.EmployeeHut)

-- Modules
local Modules = script.Parent.Parent.Parent.Modules
local EquippedItem = require(Modules.EquippedItem)

-- Controllers
local PlayerDataController = require(script.Parent.Parent.PlayerDataController)

--
local LocalPlayer = Players.LocalPlayer

-- Required lazily to break the cycle: HutStorageController requires this class.
local HutStorageController

-- One placed hut's prompts, all owner-only: storing what they hold (one, or the whole stack), viewing the store, and the Worker Hut panel. The store itself lives in player data, keyed by this hut's uid, so several huts each fill their own.

--
local HutStorage = {}
HutStorage.__index = HutStorage

function HutStorage.new(clone: Model)
	local cleaner = Trove.new()

	local self = setmetatable({
		_clone = clone,

		-- Stamped by the base before it tags the model, and fixed for the whole life of this class
		_uid = clone:GetAttribute(Structures.UID_ATTRIBUTE),
		_ownerUserId = clone:GetAttribute(Structures.OWNER_ATTRIBUTE),

		-- Non-recursive, matching how Structures measures it: the Hitbox is a direct child of the template
		_hitbox = clone:FindFirstChild(Structures.HITBOX_NAME),

		-- Searched, since the chest sits inside the hut's art rather than directly under the model
		_highlightTarget = clone:FindFirstChild(EmployeeHut.STORAGE_HIGHLIGHT_NAME, true),

		_storeOnePrompt = nil,
		_storeAllPrompt = nil,
		_viewPrompt = nil,

		_cleaner = cleaner,
		_promptCleaner = cleaner:Construct(Trove),
	}, HutStorage)

	if not self._hitbox then
		warn(`[HutStorage] {clone.Name} has no {Structures.HITBOX_NAME}, it can't be stored into`)
	end

	-- Falls back to the whole hut, so a renamed chest costs the precision rather than the cue
	if not self._highlightTarget then
		warn(`[HutStorage] {clone.Name} has no {EmployeeHut.STORAGE_HIGHLIGHT_NAME}, the whole hut lights up instead`)
		self._highlightTarget = clone
	end

	self:RefreshPrompt()

	return self
end

-- Builds one owner prompt on the named attachment under the Hitbox, falling back to the Hitbox itself.
function HutStorage:_createPrompt(attachmentName: string, onTriggered: () -> ()): ProximityPrompt
	local anchor = self._hitbox:FindFirstChild(attachmentName)
	if not anchor then
		warn(`[HutStorage] {self._clone.Name} has no {attachmentName}, its prompt sits on the Hitbox`)
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = EmployeeHut.STORAGE_HOLD_DURATION
	prompt.MaxActivationDistance = EmployeeHut.STORAGE_MAX_DISTANCE
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Parent = anchor or self._hitbox

	self._promptCleaner:Add(prompt)
	self._promptCleaner:Connect(prompt.Triggered, function()
		HutStorageController = HutStorageController or require(script.Parent)
		onTriggered()
	end)

	return prompt
end

-- What the player is holding that this hut would take, as a label, plus how many of it they own. Nil and 0 when they're holding nothing storable.
function HutStorage:_getStorable(): (string?, number)
	-- Checked first: a built BBQ isn't stock, and its tool would otherwise read as the stick underneath it
	if EquippedItem.GetSkewer() then
		return nil, 0
	end

	-- Owned counts read off data rather than the tool, which can lag them by a reconcile
	local ingredientId = EquippedItem.GetIngredientId()
	if ingredientId then
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)
		local name = if ingredient then ingredient.Name else "Ingredient"
		return name, PlayerDataController:GetKey("Ingredients")[ingredientId] or 0
	end

	local stickId = EquippedItem.GetStickId()
	if stickId then
		local stick = Sticks.GetStickFromId(stickId)
		local name = if stick then `{stick.Name} Stick` else "Stick"
		return name, PlayerDataController:GetKey("Sticks")[stickId] or 0
	end

	return nil, 0
end

-- Puts the prompts up on the owner's own huts only, and keeps which of them show, and their verbs, current.
function HutStorage:RefreshPrompt()
	if not self._hitbox then
		return
	end

	local owned = self._ownerUserId == LocalPlayer.UserId

	-- Built once and then only written to: rebuilding them under a player stood at one would drop their prompt
	if owned and not self._storeOnePrompt then
		self._storeOnePrompt = self:_createPrompt(EmployeeHut.STORE_ONE_ATTACHMENT, function()
			HutStorageController:RequestStore(self._uid)
		end)

		local storeAllPrompt = self:_createPrompt(EmployeeHut.STORE_ALL_ATTACHMENT, function()
			HutStorageController:RequestStore(self._uid, true)
		end)
		storeAllPrompt.HoldDuration = EmployeeHut.STORE_ALL_HOLD_DURATION
		storeAllPrompt.KeyboardKeyCode = EmployeeHut.STORE_ALL_KEY
		storeAllPrompt.GamepadKeyCode = EmployeeHut.STORE_ALL_GAMEPAD_KEY
		self._storeAllPrompt = storeAllPrompt

		local viewPrompt = self:_createPrompt(EmployeeHut.VIEW_STORAGE_ATTACHMENT, function()
			HutStorageController:RequestOpenStorage(self._uid)
		end)
		viewPrompt.ActionText = EmployeeHut.VIEW_STORAGE_ACTION_TEXT
		self._viewPrompt = viewPrompt

		-- Always up for the owner, unlike storage, since opening the panel needs nothing in hand
		local workerPrompt = self:_createPrompt(EmployeeHut.WORKER_ATTACHMENT, function()
			HutStorageController:RequestOpenWorkerHut()
		end)
		workerPrompt.ActionText = EmployeeHut.WORKER_PROMPT_ACTION_TEXT
		workerPrompt.HoldDuration = EmployeeHut.WORKER_PROMPT_HOLD_DURATION
		workerPrompt.MaxActivationDistance = EmployeeHut.WORKER_PROMPT_MAX_DISTANCE
	elseif not owned and self._storeOnePrompt then
		self._promptCleaner:Clean()
		self._storeOnePrompt = nil
		self._storeAllPrompt = nil
		self._viewPrompt = nil
	end

	local storable, count = nil, 0
	if owned then
		storable, count = self:_getStorable()
	end

	if self._storeOnePrompt then
		-- Relabelled before Enabled flips, so a prompt coming up draws the new verb rather than the last one
		if storable then
			self._storeOnePrompt.ActionText = `Store {storable}`
			self._storeAllPrompt.ActionText = `Store all {storable}`
		end

		self._storeOnePrompt.Enabled = storable ~= nil
		self._storeAllPrompt.Enabled = storable ~= nil and count >= EmployeeHut.STORE_ALL_MIN_AMOUNT

		-- Swapped with the store prompt rather than shown beside it, which is what lets the two share E
		self._viewPrompt.Enabled = storable == nil
	end

	-- Lit only while they're carrying something it would take, so a glow always means a prompt that acts
	self._highlightTarget:SetAttribute("HighlightColor", Highlights.PLACE)
	if storable then
		self._highlightTarget:AddTag(Highlights.TAG)
	else
		self._highlightTarget:RemoveTag(Highlights.TAG)
	end
end

function HutStorage:Destroy()
	-- The model can outlive this class for a frame with our tag on it, so take it off rather than trust timing
	self._highlightTarget:RemoveTag(Highlights.TAG)

	self._cleaner:Destroy()
end

return HutStorage
