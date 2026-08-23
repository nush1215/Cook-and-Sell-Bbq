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

-- Seconds a drop is left to the spring before Update counts it as seated and takes the pivot back. The
-- spring is within a hair of rest by ~0.4s (4 / (damping * 2pi * frequency)); the rest is headroom for
-- the bounce. Timed rather than off Spr.completed: that callback only ever fires on a spring that
-- finishes on its own, and one stopped early (a stick taken back mid-drop) leaves it -- and the model
-- it closes over -- in spr for good.
local DROP_SETTLE_TIME = 1

-- The place sound is pitched off a fresh roll in this band each time, so filling a skewer doesn't read
-- as the same sample repeating.
local PLACE_PITCH_MIN = 0.9
local PLACE_PITCH_MAX = 1.1

-- Required lazily to break the cycle: StickStandController requires this class.
local StickStandController

-- A cooked skewer shows the cooked models; a raw one the raw models.
local function sourceModel(ingredient: Ingredients.Ingredient, cooked: boolean): Model
	return if cooked then ingredient.CookedModel else ingredient.Model
end

--[[
    Class for a single placed stick stand on some base.

    One instance per stand, on every client, so placed sticks and their ingredients show up for
    visitors too. The server writes the stick + ingredient list to the stand's PlacedStickId /
    PlacedIngredients attributes; this renders them onto the stand's StickAttachment and keeps them
    there as the client animates the stand into place. A freshly-added ingredient drops in from above;
    the rest render in place. The place/put/remove prompt only goes up on stands the local player owns,
    which the OwnerUserId attribute the base stamped on it is what says.
]]

--
local StickStand = {}
StickStand.__index = StickStand

function StickStand.new(clone: Model)
	--
	local cleaner = Trove.new()

	local stand = clone:FindFirstChild("Stand")
	local attachment = stand and stand:FindFirstChild("StickAttachment")
	local promptAttachment = stand and stand:FindFirstChild("StickPromptAttachment")

	local self = setmetatable({
		--
		_clone = clone,

		-- Which placed stand this is, and whose it is. Both are stamped on by the base before it tags
		-- the model, so they're set by the time this class is ever built, and a stand only exists while
		-- its owner does -- so ownership is fixed for the whole life of one of these.
		_uid = clone:GetAttribute(Structures.UID_ATTRIBUTE),
		_ownerUserId = clone:GetAttribute(Structures.OWNER_ATTRIBUTE),

		_stand = stand,
		_attachment = attachment,
		_promptAttachment = promptAttachment,

		-- The placed stick model, and the ingredients riding on it. _ingredientIds is the last list we
		-- rendered, so a change that only appends one can be told apart (re-centre + drop it in) from a
		-- bulk change (rebuild in place). Each _ingredients entry: { model, pivotToCenter, index, id,
		-- localPivot, dropping, dropUntil }.
		_stickId = nil,
		_stickModel = nil,
		_ingredientIds = {},
		_ingredients = {},
		_rendered = false, -- gates the place sound, so a stand that already holds a stick doesn't ring on join
		_cooked = false, -- whether the placed skewer is cooked, so ingredients render from the cooked models

		-- Where the attachment was on the last Update, and whether any ingredient was still dropping then --
		-- together they let Update skip a stand that hasn't moved and has nothing in the air.
		_lastBase = nil,
		_dropping = false,

		-- The placed stick's UI holder (StickUIAttachment, parented under the stand clone), the detached
		-- ingredient-title template it clones from, and the live title clones. Dropped by hand in
		-- _renderStick / Destroy since they don't hang off the stick model.
		_ui = nil,
		_titleTemplate = nil,
		_titleClones = {},

		_prompt = nil,

		--
		_cleaner = cleaner,
		_promptCleaner = cleaner:Construct(Trove),
	}, StickStand)

	-- The parts come off the structure's template in the place file, not this repo, so a missing
	-- Stand/attachment is a real failure case rather than something the code guarantees.
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

-- Brings the rendered stick + ingredients in line with the stand's attributes, then refreshes the
-- prompt text.
function StickStand:_render()
	if not self._attachment then
		return
	end

	local stickId = self._clone:GetAttribute("PlacedStickId")
	local ingredientsCsv = self._clone:GetAttribute("PlacedIngredients")
	local ingredientIds = if ingredientsCsv and ingredientsCsv ~= "" then string.split(ingredientsCsv, ",") else {}
	local cooked = self._clone:GetAttribute("PlacedCooked") == true

	-- A different stick (placed, removed, swapped) rebuilds the stick and drops all its ingredients so
	-- they re-seat on the new one.
	if stickId ~= self._stickId then
		self._stickId = stickId
		self:_renderStick(stickId)
		self:_clearIngredients()

		-- A stick arriving on the stand is the player setting one down; the take that clears it isn't.
		-- Rung off the model _renderStick just seated, so it comes from the stick itself.
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
	self:_updatePromptText()
	self:RefreshHighlights()

	self._rendered = true
end

-- Clears the current stick model and, if the stand holds one, seats it on the attachment. Parented as
-- a sibling of the clone rather than under it, so the client's entrance ScaleTo on the stand can't
-- blow the stick's size up; Update keeps it glued.
function StickStand:_renderStick(stickId: string?)
	if self._stickModel then
		self._stickModel:Destroy()
		self._stickModel = nil
	end

	-- The billboard sits under the stand clone (not the stick model), so drop it by hand -- its title
	-- clones go with it, and the detached title template needs dropping too.
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

	-- Billboard: the stick's name plus a capacity/ingredient readout _updateIngredientUI fills in.
	-- StickUIAttachment is an Attachment, so it goes on the Stand part (which the stand clone animates,
	-- so it rides along); its authored offset + the billboard's StudsOffset place it. The teardown above
	-- drops it since it doesn't hang off the stick model.
	local holder = UI.StickUIAttachment:Clone()
	local billboard = holder.UI

	billboard.StickName.Text = `{stick.Name} Stick`
	billboard.StickName.TextColor3 = stick.TextColor
	local nameStroke = billboard.StickName:FindFirstChildWhichIsA("UIStroke")
	if nameStroke then
		nameStroke.Color = stick.StrokeColor
	end

	-- Pull the template out of the grid so it isn't rendered as an empty cell; clones come off it.
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

-- Fills the billboard's capacity counter and ingredient titles from the current list, hiding the
-- ingredient section while the stick is empty. No-op when there's no stick (so no billboard).
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

-- Matches the rendered ingredients to the new list. Exactly one appended (a fresh "Put") re-centres
-- the run -- shifting the ones already on the stick and dropping the new one in; anything else (initial
-- load, a removal, a swap) rebuilds in place.
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

	-- The whole list's extents are needed to place any one ingredient (spacing accumulates by size),
	-- and the run centres on the stick's middle, so appending one shifts every earlier slot too.
	local extents = StickIngredients.ComputeExtents(newIds, self._cooked)
	local middleOffset = if self._stickModel then StickIngredients.GetStickMiddleOffset(self._stickModel) else Vector3.zero
	local stickLength = if self._stickModel then StickIngredients.GetStickLength(self._stickModel) else math.huge

	if appended then
		local base = self._attachment.WorldCFrame

		-- The run re-centres, so the ones already on the stick slide to new slots. Spring them (not
		-- snap) so it reads as the stack making room, like a stand sliding across a reflow.
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

		-- Rung off the stick's own pose so it's positional, and gated the same way the stick's place sound
		-- is -- a stand loading a one-ingredient skewer on join takes this branch too, and shouldn't ring.
		-- Every client renders this stand off the replicated list, so playing it locally is what makes it
		-- heard by everyone rather than only the player who put it on.
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

-- Renders ingredient `index` onto the stick. When animate is true it spawns above and springs down;
-- otherwise it lands straight at its rest pose. Update keeps it seated after.
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

	-- Bake this model's pivot->centre once, before it moves, and keep it with the index so Update can
	-- rebuild the slot pose against the live attachment each frame -- and _reconcileIngredients can
	-- recompute it when a later add re-centres the run -- with no per-frame maths or RNG re-roll.
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

-- Keeps the stick and its ingredients glued to the attachment, which the client slides around as it
-- springs the stand up into its slot and reflows the grid. A still-dropping ingredient keeps springing
-- toward its target (so it chases the stand mid-fall); settled ones snap straight to it.
function StickStand:Update(_deltaTime: number)
	if not self._attachment then
		return
	end

	local base = self._attachment.WorldCFrame

	-- Nothing has moved and nothing is in the air: everything is still seated where the last pass put it.
	-- This runs for every stand on every base every frame, and nearly all of them are sat still nearly all
	-- of the time, so a settled stand has to cost nothing here.
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

		-- A drop that has had its settle time is seated: take the pivot back from spr, and stop the spring
		-- so it can't keep nudging a model this now places outright.
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

-- Puts the prompt up when the local player owns this base and takes it down when they don't, so only
-- the owner can place/put/remove, and visitors just see the result. Also keeps the text current.
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

	self:_updatePromptText()
	self:RefreshHighlights()
end

-- The prompt reads by state + what the local player holds: place a stick on an empty stand, add the
-- held ingredient to a placed one (or "Skewer Full" at capacity), else take it back off.
--
-- A bare stick is a "Stick" and one carrying ingredients is a "Skewer" -- the same two words every
-- other machine uses, so the noun on the prompt is what tells the player where it goes next: a stick
-- belongs on a stand, a skewer belongs on the grill.
function StickStand:_updatePromptText()
	if not self._prompt then
		return
	end

	local stickId = self._clone:GetAttribute("PlacedStickId")
	if not stickId then
		self._prompt.ActionText = "Place Stick"
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

		return
	end

	-- Taking it back hands over whatever's on the stand, so the noun follows what it actually is.
	self._prompt.ActionText = if #self._ingredientIds > 0 then "Take BBQ" else "Take Stick"
end

-- Breathes whichever part of the stand the player could act on right now: the stand itself while
-- they hold a stick to put on it, or the placed stick while they hold an ingredient it has room for.
-- Reads the same state the prompt text does, so what glows and what the prompt says can't disagree.
function StickStand:RefreshHighlights()
	local owned = self._ownerUserId == LocalPlayer.UserId
	local stickId = self._clone:GetAttribute("PlacedStickId")

	local canPlaceStick = owned and not stickId and EquippedItem.GetStickId() ~= nil

	self._clone:SetAttribute("HighlightColor", Highlights.PLACE)
	if canPlaceStick then
		self._clone:AddTag(Highlights.TAG)
	else
		self._clone:RemoveTag(Highlights.TAG)
	end

	-- Nothing placed, so there's no stick to light up -- _renderStick only builds one for a stand
	-- that holds a stick, and rebuilds it from scratch on every swap (which is why this has to run
	-- after _render, not before: the tag goes with the old model).
	if not self._stickModel then
		return
	end

	local stick = Sticks.GetStickFromId(stickId)
	local capacity = if stick then stick.Capacity else 0

	-- A cooked skewer is finished and a full one has nowhere to put anything, matching the prompt's
	-- "Skewer Full".
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

	-- The base destroys the stand itself, but the removed-tag signal that brings us here can land before
	-- it does -- so the model can outlive this class for a frame with our tag still on it, breathing on
	-- a stand that's on its way out. Take it off rather than leave that to timing.
	self._clone:RemoveTag(Highlights.TAG)

	-- The billboard and its detached template live under the stand clone, not the stick model, so drop
	-- them by hand.
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
