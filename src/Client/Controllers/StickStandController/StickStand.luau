-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local Sticks = require(Shared.Config.Sticks)
local Ingredients = require(Shared.Config.Ingredients)
local Highlights = require(Shared.Config.Highlights)
local Structures = require(Shared.Config.Structures)
local StickIngredients = require(Shared.StickIngredients)
local RandomUtil = require(Shared.RandomUtil)

-- Controllers
local Controllers = script.Parent.Parent
local SoundController = require(Controllers.SoundController)

-- Modules
local Modules = script.Parent.Parent.Parent.Modules
local EquippedItem = require(Modules.EquippedItem)

-- Assets
local UI = ReplicatedStorage.Assets.UI

--
local LocalPlayer = Players.LocalPlayer

local PROMPT_DISTANCE = 10

-- The drop spring: underdamped so a dropped ingredient falls in with a little bounce before settling.
local DROP_DAMPING = 0.6
local DROP_FREQUENCY = 2.5

-- Seconds before Update takes the pivot back. Timed, since Spr.completed never fires on a spring stopped early
local DROP_SETTLE_TIME = 1

-- Pitched off a fresh roll each time, so filling a skewer doesn't read as one sample repeating
local PLACE_PITCH_MIN = 0.9
local PLACE_PITCH_MAX = 1.1

-- Required lazily to break the cycle: StickStandController requires this class.
local StickStandController

-- A cooked skewer shows the cooked models; a raw one the raw models.
local function sourceModel(ingredient: Ingredients.Ingredient, cooked: boolean): Model
	return if cooked then ingredient.CookedModel else ingredient.Model
end

-- One placed stick stand: renders the stick and its ingredients off the stand's attributes, and owns the prompt and glow.

--
local StickStand = {}
StickStand.__index = StickStand

function StickStand.new(clone: Model)
	local cleaner = Trove.new()

	local stand = clone:FindFirstChild("Stand")
	local attachment = stand and stand:FindFirstChild("StickAttachment")
	local promptAttachment = stand and stand:FindFirstChild("StickPromptAttachment")

	local self = setmetatable({
		_clone = clone,

		-- Stamped by the base before it tags the model, and fixed for the whole life of this class
		_uid = clone:GetAttribute(Structures.UID_ATTRIBUTE),
		_ownerUserId = clone:GetAttribute(Structures.OWNER_ATTRIBUTE),

		_stand = stand,
		_attachment = attachment,
		_promptAttachment = promptAttachment,

		-- The stick and its ingredients; _ingredientIds is the last list rendered, so an append can be told from a rebuild
		_stickId = nil,
		_stickModel = nil,
		_ingredientIds = {},
		_ingredients = {},
		_rendered = false, -- gates the place sound, so a stand that already holds a stick doesn't ring on join
		_cooked = false, -- whether the placed skewer is cooked, so ingredients render from the cooked models

		-- The last Update's pose and whether anything was mid-drop, so a still stand can be skipped
		_lastBase = nil,
		_dropping = false,

		-- The billboard, its title template and the live clones. Dropped by hand -- they don't hang off the stick
		_ui = nil,
		_titleTemplate = nil,
		_titleClones = {},

		_prompt = nil,

		_cleaner = cleaner,
		_promptCleaner = cleaner:Construct(Trove),
	}, StickStand)

	-- The parts come off the place file, so a missing Stand or attachment is a real failure case
	if not attachment then
		warn(`[StickStand] {clone.Name} has no Stand.StickAttachment, it won't render`)
		return self
	end

	if not promptAttachment then
		warn(`[StickStand] {clone.Name} has no Stand.StickPromptAttachment, it won't prompt`)
	end

	cleaner:Connect(clone:GetAttributeChangedSignal("PlacedStickId"), function()
		self:_render()
	end)
	cleaner:Connect(clone:GetAttributeChangedSignal("PlacedIngredients"), function()
		self:_render()
	end)
	cleaner:Connect(clone:GetAttributeChangedSignal("PlacedCooked"), function()
		self:_render()
	end)

	self:_render()
	self:RefreshPrompt()

	return self
end

-- Brings the rendered stick and ingredients in line with the stand's attributes, then refreshes the prompt.
function StickStand:_render()
	if not self._attachment then
		return
	end

	local stickId = self._clone:GetAttribute("PlacedStickId")
	local ingredientsCsv = self._clone:GetAttribute("PlacedIngredients")
	local ingredientIds = if ingredientsCsv and ingredientsCsv ~= "" then string.split(ingredientsCsv, ",") else {}
	local cooked = self._clone:GetAttribute("PlacedCooked") == true

	-- A different stick rebuilds it and re-seats every ingredient on the new one
	if stickId ~= self._stickId then
		self._stickId = stickId
		self:_renderStick(stickId)
		self:_clearIngredients()

		-- Rung off the model _renderStick just seated, so it comes from the stick itself
		if self._stickModel and self._rendered then
			SoundController:PlaySound("Place", self._stickModel:GetPivot())
		end
	end

	-- A raw->cooked swap keeps the same stick but needs the ingredients rebuilt from the cooked models.
	if cooked ~= self._cooked then
		self._cooked = cooked
		self:_clearIngredients()
	end

	self:_reconcileIngredients(ingredientIds)
	self:_updateIngredientUI()
	self:_updatePrompt()
	self:RefreshHighlights()

	self._rendered = true
end

-- Seats the stand's stick on the attachment, as a sibling of the clone so the entrance ScaleTo can't inflate it.
function StickStand:_renderStick(stickId: string?)
	if self._stickModel then
		self._stickModel:Destroy()
		self._stickModel = nil
	end

	-- Dropped by hand, since the billboard sits under the stand clone rather than the stick model
	if self._ui then
		self._ui:Destroy()
		self._ui = nil
	end
	if self._titleTemplate then
		self._titleTemplate:Destroy()
		self._titleTemplate = nil
	end
	table.clear(self._titleClones)

	if not stickId then
		return
	end

	-- Data can hold a stick the config no longer has.
	local stick = Sticks.GetStickFromId(stickId)
	if not stick then
		return
	end

	local model = stick.Model:Clone()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
		end
	end

	model:PivotTo(self._attachment.WorldCFrame)
	model.Parent = self._clone.Parent
	self._stickModel = model

	-- On the Stand part so it rides the stand's animation; the teardown above drops it by hand
	local holder = UI.StickUIAttachment:Clone()
	local billboard = holder.UI

	billboard.StickName.Text = `{stick.Name} Stick`
	billboard.StickName.TextColor3 = stick.TextColor
	local nameStroke = billboard.StickName:FindFirstChildWhichIsA("UIStroke")
	if nameStroke then
		nameStroke.Color = stick.StrokeColor
	end

	-- Pulled out of the grid so it isn't rendered as an empty cell; clones come off it
	self._titleTemplate = billboard.Ingredients.IngredientTitleTemplate
	self._titleTemplate.Parent = nil

	holder.Parent = self._stand
	self._ui = holder
end

-- Tears down every rendered ingredient model.
function StickStand:_clearIngredients()
	for _, entry in self._ingredients do
		Spr.stop(entry.model)
		entry.model:Destroy()
	end

	table.clear(self._ingredients)
	self._ingredientIds = {}
end

-- Fills the billboard's counter and titles, hiding the ingredient section while the stick is empty.
function StickStand:_updateIngredientUI()
	if not self._ui then
		return
	end

	local billboard = self._ui.UI

	local count = #self._ingredientIds
	local stick = Sticks.GetStickFromId(self._stickId)
	local capacity = if stick then stick.Capacity else 0
	billboard.Capacity.Text = `{count}/{capacity}`

	local hasIngredients = count > 0
	billboard.Ingredients.Visible = hasIngredients
	billboard.IngredientsTitle.Visible = hasIngredients

	-- Rebuild the titles from scratch: cheap, and it keeps them in list order.
	for _, clone in self._titleClones do
		clone:Destroy()
	end
	table.clear(self._titleClones)

	for _, id in self._ingredientIds do
		local ingredient = Ingredients.GetIngredientFromId(id)
		if not ingredient then
			continue
		end

		local title = self._titleTemplate:Clone()
		title.Text = ingredient.Name
		title.TextColor3 = ingredient.Color

		local stroke = title:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			stroke.Color = ingredient.Color:Lerp(Color3.new(), 0.65)
		end

		title.Visible = true
		title.Parent = billboard.Ingredients
		table.insert(self._titleClones, title)
	end
end

-- Reconciles to the new list: one appended re-centres the run and drops it in, anything else rebuilds in place.
function StickStand:_reconcileIngredients(newIds: { string })
	local oldIds = self._ingredientIds

	local appended = #newIds == #oldIds + 1
	if appended then
		for i = 1, #oldIds do
			if oldIds[i] ~= newIds[i] then
				appended = false
				break
			end
		end
	end

	-- Spacing accumulates by size and the run centres on the stick, so appending one shifts every earlier slot
	local extents = StickIngredients.ComputeExtents(newIds, self._cooked)
	local middleOffset = if self._stickModel then StickIngredients.GetStickMiddleOffset(self._stickModel) else Vector3.zero
	local stickLength = if self._stickModel then StickIngredients.GetStickLength(self._stickModel) else math.huge

	if appended then
		local base = self._attachment.WorldCFrame

		-- Sprung rather than snapped, so it reads as the stack making room
		for _, entry in self._ingredients do
			entry.localPivot = StickIngredients.GetRestLocalCFrame(entry.index, entry.id, extents, middleOffset, stickLength)
				* entry.pivotToCenter:Inverse()
			entry.dropping = true
			entry.dropUntil = os.clock() + DROP_SETTLE_TIME
			Spr.target(entry.model, DROP_DAMPING, DROP_FREQUENCY, { Pivot = base * entry.localPivot })
		end
		self._dropping = true

		self:_spawnIngredient(newIds[#newIds], #newIds, true, extents, middleOffset, stickLength)
		self._ingredientIds = newIds

		-- Positional and gated like the place sound; played locally on every client, so everyone hears it
		if self._rendered then
			SoundController:PlaySound("IngredientPlace", base, {
				PlaybackSpeed = RandomUtil.GetRandomFromMinMax(PLACE_PITCH_MIN, PLACE_PITCH_MAX),
			})
		end

		return
	end

	self:_clearIngredients()
	for index, id in newIds do
		self:_spawnIngredient(id, index, false, extents, middleOffset, stickLength)
	end
	self._ingredientIds = newIds
end

-- Renders ingredient `index`, springing it down when `animate`. Update keeps it seated after.
function StickStand:_spawnIngredient(id: string, index: number, animate: boolean, extents: { number }, middleOffset: Vector3, stickLength: number)
	local ingredient = Ingredients.GetIngredientFromId(id)
	if not ingredient then
		return
	end

	local model = sourceModel(ingredient, self._cooked):Clone()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
		end
	end

	-- Baked once before it moves, so Update rebuilds the slot pose with no per-frame maths or RNG re-roll
	local pivotToCenter = StickIngredients.GetPivotToCenter(model)
	local localPivot = StickIngredients.GetRestLocalCFrame(index, id, extents, middleOffset, stickLength) * pivotToCenter:Inverse()
	local base = self._attachment.WorldCFrame

	local entry = { model = model, pivotToCenter = pivotToCenter, index = index, id = id, localPivot = localPivot, dropping = false }

	if animate then
		model:PivotTo(base * StickIngredients.GetSpawnLocalCFrame(index, id, extents, middleOffset, stickLength) * pivotToCenter:Inverse())
		model.Parent = self._clone.Parent

		entry.dropping = true
		entry.dropUntil = os.clock() + DROP_SETTLE_TIME
		Spr.target(model, DROP_DAMPING, DROP_FREQUENCY, { Pivot = base * localPivot })
		self._dropping = true
	else
		model:PivotTo(base * localPivot)
		model.Parent = self._clone.Parent
	end

	table.insert(self._ingredients, entry)
end

-- The stick model on this stand, or nil. Re-created on every change, so callers must re-resolve it.
function StickStand:GetStickModel(): Model?
	return self._stickModel
end

-- Keeps the stick and ingredients glued to the attachment as the stand springs and the grid reflows.
function StickStand:Update(_deltaTime: number)
	if not self._attachment then
		return
	end

	local base = self._attachment.WorldCFrame

	-- Runs for every stand on every base every frame, and nearly all are still, so a settled stand costs nothing
	if base == self._lastBase and not self._dropping then
		return
	end
	self._lastBase = base

	if self._stickModel then
		self._stickModel:PivotTo(base)
	end

	local now = os.clock()
	local dropping = false

	for _, entry in self._ingredients do
		local restTarget = base * entry.localPivot

		-- Take the pivot back and stop the spring, so it can't nudge a model this now places outright
		if entry.dropping and now >= entry.dropUntil then
			entry.dropping = false
			Spr.stop(entry.model)
		end

		if entry.dropping then
			dropping = true
			Spr.target(entry.model, DROP_DAMPING, DROP_FREQUENCY, { Pivot = restTarget })
		else
			entry.model:PivotTo(restTarget)
		end
	end

	self._dropping = dropping
end

-- Puts the prompt up on the owner's own base only, and keeps its text current.
function StickStand:RefreshPrompt()
	if not self._promptAttachment then
		return
	end

	local owned = self._ownerUserId == LocalPlayer.UserId

	if owned and not self._prompt then
		local prompt = Instance.new("ProximityPrompt")
		prompt.RequiresLineOfSight = false
		prompt.HoldDuration = 0.3
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.MaxActivationDistance = PROMPT_DISTANCE
		prompt.Parent = self._promptAttachment

		self._prompt = prompt
		self._promptCleaner:Add(prompt)
		self._promptCleaner:Connect(prompt.Triggered, function()
			StickStandController = StickStandController or require(script.Parent)
			StickStandController:RequestToggle(self._uid)
		end)
	elseif not owned and self._prompt then
		self._promptCleaner:Clean()
		self._prompt = nil
	end

	self:_updatePrompt()
	self:RefreshHighlights()
end

-- Reads by state and what's held: place a stick, add an ingredient, or take it back. Each branch reads its own tutorial lock, and Enabled is written on every branch.
function StickStand:_updatePrompt()
	if not self._prompt then
		return
	end

	StickStandController = StickStandController or require(script.Parent)

	local stickId = self._clone:GetAttribute("PlacedStickId")
	if not stickId then
		self._prompt.ActionText = "Place Stick"
		self._prompt.Enabled = not StickStandController:IsPlaceLocked()
		return
	end

	local ingredientId = EquippedItem.GetIngredientId()
	if ingredientId then
		local stick = Sticks.GetStickFromId(stickId)
		local capacity = if stick then stick.Capacity else 0

		if #self._ingredientIds >= capacity then
			self._prompt.ActionText = "BBQ Full"
		else
			local ingredient = Ingredients.GetIngredientFromId(ingredientId)
			self._prompt.ActionText = `Add {if ingredient then ingredient.Name else "Ingredient"}`
		end

		self._prompt.Enabled = true
		return
	end

	-- The noun follows what's actually on the stand
	self._prompt.ActionText = if #self._ingredientIds > 0 then "Take BBQ" else "Take Stick"
	self._prompt.Enabled = not StickStandController:IsTakeLocked()
end

-- Breathes whatever can be acted on -- the stand for a held stick, the stick for a held ingredient.
function StickStand:RefreshHighlights()
	StickStandController = StickStandController or require(script.Parent)

	local owned = self._ownerUserId == LocalPlayer.UserId
	local stickId = self._clone:GetAttribute("PlacedStickId")

	-- The glow says a prompt is up, so holding one without the other lights a stand that does nothing
	local canPlaceStick = owned
		and not stickId
		and EquippedItem.GetStickId() ~= nil
		and not StickStandController:IsPlaceLocked()

	self._clone:SetAttribute("HighlightColor", Highlights.PLACE)
	if canPlaceStick then
		self._clone:AddTag(Highlights.TAG)
	else
		self._clone:RemoveTag(Highlights.TAG)
	end

	-- No stick to light. This must run after _render, since the tag goes with the old model
	if not self._stickModel then
		return
	end

	local stick = Sticks.GetStickFromId(stickId)
	local capacity = if stick then stick.Capacity else 0

	-- A cooked skewer is finished and a full one has nowhere to put anything, matching the prompt
	local canAddIngredient = owned
		and not self._cooked
		and #self._ingredientIds < capacity
		and EquippedItem.GetIngredientId() ~= nil

	self._stickModel:SetAttribute("HighlightColor", Highlights.PLACE)
	if canAddIngredient then
		self._stickModel:AddTag(Highlights.TAG)
	else
		self._stickModel:RemoveTag(Highlights.TAG)
	end
end

function StickStand:Destroy()
	self:_clearIngredients()

	-- The model can outlive this class for a frame with our tag on it, so take it off rather than trust timing
	self._clone:RemoveTag(Highlights.TAG)

	-- Dropped by hand, living under the stand clone rather than the stick model
	if self._ui then
		self._ui:Destroy()
		self._ui = nil
	end
	if self._titleTemplate then
		self._titleTemplate:Destroy()
		self._titleTemplate = nil
	end

	if self._stickModel then
		self._stickModel:Destroy()
		self._stickModel = nil
	end

	self._cleaner:Destroy()
	self = nil
end

return StickStand
