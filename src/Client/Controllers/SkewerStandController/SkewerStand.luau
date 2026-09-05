-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local StickModel = require(Shared.StickModel)
local Highlights = require(Shared.Config.Highlights)

-- Controllers
local Controllers = script.Parent.Parent
local SoundController = require(Controllers.SoundController)

-- Modules
local Modules = script.Parent.Parent.Parent.Modules
local EquippedItem = require(Modules.EquippedItem)

--
local LocalPlayer = Players.LocalPlayer

local PROMPT_DISTANCE = 13

-- Up to this many skewers sit on the stand; they distribute along its long (local-X) axis.
local MAX_SKEWERS = 6

-- The scale a placed skewer is shown at, shared so a customer NPC holds it at the same size
local SKEWER_SCALE = StickModel.DISPLAY_SCALE

-- Applied over the part's orientation, so authoring the part controls facing
local ORIENTATION_OFFSET = CFrame.identity

-- Underdamped, so skewers slide to new slots and drop in with a settle rather than snapping
local SHIFT_DAMPING = 0.6
local SHIFT_FREQUENCY = 2.5

-- Studs above its slot a newly placed skewer drops in from.
local DROP_RISE = 3

-- A small random rotation per skewer so the row doesn't look machine-perfect; yaw varies most
local ROTATION_VARIATION_YAW = math.rad(20)
local ROTATION_VARIATION_TILT = math.rad(6)

-- Required lazily to break the cycle: SkewerStandController requires this class.
local SkewerStandController

-- Whether two records describe the same skewer, so a re-render can tell a slide from a placement.
local function recordsEqual(a, b): boolean
	if
		a.StickId ~= b.StickId
		or (a.Cooked == true) ~= (b.Cooked == true)
		or a.CookState ~= b.CookState
		or a.Sauce ~= b.Sauce
	then
		return false
	end

	if #a.Ingredients ~= #b.Ingredients then
		return false
	end
	for i = 1, #a.Ingredients do
		if a.Ingredients[i] ~= b.Ingredients[i] then
			return false
		end
	end

	return true
end

-- A random rotation for a placed skewer, kept on its entry so it stays put as the row slides.
local function randomSkewerRotation(): CFrame
	return CFrame.Angles(
		(math.random() * 2 - 1) * ROTATION_VARIATION_TILT,
		(math.random() * 2 - 1) * ROTATION_VARIATION_YAW,
		(math.random() * 2 - 1) * ROTATION_VARIATION_TILT
	)
end

-- One sell stand: renders the placed skewers off its attribute, sliding the row as they come and go, and owns the owner's prompts.

--
local SkewerStand = {}
SkewerStand.__index = SkewerStand

function SkewerStand.new(part: BasePart, baseId: string, sellStall: Model)
	local cleaner = Trove.new()

	-- On a PromptAttachment if the place file authored one, else on the part
	local promptAnchor = part:FindFirstChild("PromptAttachment") or part

	local self = setmetatable({
		_part = part,
		_baseId = baseId,
		_promptAnchor = promptAnchor,

		-- The whole stall, so someone carrying a cooked skewer can pick it out from across the base
		_sellStall = sellStall,

		-- One { record, model, prompt } per placed skewer, aligned to the records so a re-render can diff
		_entries = {},
		_count = 0,
		_rendered = false,

		-- The stand's place prompt (owner only; enabled only while holding a cooked skewer)
		_placePrompt = nil,

		_cleaner = cleaner,
		_placeCleaner = cleaner:Construct(Trove),
	}, SkewerStand)

	cleaner:Connect(part:GetAttributeChangedSignal("PlacedSkewers"), function()
		self:_render()
	end)

	self:_render()
	self:RefreshPrompt()

	return self
end

-- Whether the local player owns this base, so only they get prompts.
function SkewerStand:_owned(): boolean
	return self._baseId == LocalPlayer:GetAttribute("BaseId")
end

-- Where skewer `index` of `count` sits: a constant step along the part, so the row re-centres. `rise` is the drop-in lift.
function SkewerStand:_slotCFrame(index: number, count: number, rotation: CFrame, rise: number?): CFrame
	local step = self._part.Size.X / MAX_SKEWERS
	local x = (index - (count + 1) / 2) * step
	return self._part.CFrame * CFrame.new(x, rise or 0, 0) * ORIENTATION_OFFSET * rotation
end

-- Builds a placed skewer's model, scaled down and inert. Nil if the stick id is gone from the config.
function SkewerStand:_buildModel(record): Model?
	local model = StickModel.BuildStickModel(record)
	if not model then
		return nil
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
		end
	end

	model:ScaleTo(SKEWER_SCALE)
	return model
end

-- Puts the owner's take prompt on a placed skewer, riding the model and reporting its current index. Gated here, not per caller.
function SkewerStand:_refreshRemovePrompt(entry, owned: boolean)
	SkewerStandController = SkewerStandController or require(script.Parent)
	local canTake = owned and not SkewerStandController:IsTakeLocked()

	if canTake and entry.model and entry.model.PrimaryPart and not entry.prompt then
		local prompt = Instance.new("ProximityPrompt")
		prompt.RequiresLineOfSight = false
		prompt.HoldDuration = 0.3
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.MaxActivationDistance = PROMPT_DISTANCE
		prompt.ActionText = "Take BBQ"
		prompt.Parent = entry.model.PrimaryPart
		entry.prompt = prompt

		prompt.Triggered:Connect(function()
			local index = table.find(self._entries, entry)
			if index then
				SkewerStandController:RequestRemove(index)
			end
		end)
	elseif not canTake and entry.prompt then
		entry.prompt:Destroy()
		entry.prompt = nil
	end
end

-- Reconciles against PlacedSkewers: a single place or remove slides the row, anything else snaps.
function SkewerStand:_render()
	local encoded = self._part:GetAttribute("PlacedSkewers")
	local records = if encoded then HttpService:JSONDecode(encoded) else {}
	local n = #records
	self._count = n

	local entries = self._entries
	local oldCount = #entries
	local owned = self:_owned()

	local firstRender = not self._rendered
	self._rendered = true

	local function prefixMatches(count: number): boolean
		for i = 1, count do
			if not recordsEqual(entries[i].record, records[i]) then
				return false
			end
		end
		return true
	end

	-- The single index removed to reach `records`, or nil if it isn't a clean one-skewer removal
	local function removalIndex(): number?
		for k = 1, oldCount do
			local match = true
			local j = 1
			for i = 1, oldCount do
				if i ~= k then
					if not recordsEqual(entries[i].record, records[j]) then
						match = false
						break
					end
					j += 1
				end
			end
			if match then
				return k
			end
		end
		return nil
	end

	local mode
	local removeAt
	if firstRender then
		mode = "bulk"
	elseif n == oldCount + 1 and prefixMatches(oldCount) then
		mode = "append"
	elseif n == oldCount - 1 then
		removeAt = removalIndex()
		mode = if removeAt then "remove" else "bulk"
	else
		mode = "bulk"
	end

	if mode == "bulk" then
		-- Snap: drop everything and reseat from scratch, no animation
		for _, entry in entries do
			if entry.model then
				Spr.stop(entry.model)
				entry.model:Destroy()
			end
		end
		table.clear(entries)

		for index, record in records do
			local rotation = randomSkewerRotation()
			local model = self:_buildModel(record)
			if model then
				model:PivotTo(self:_slotCFrame(index, n, rotation))
				model.Parent = self._part
			end
			local entry = { record = record, model = model, prompt = nil, rotation = rotation }
			entries[index] = entry
			self:_refreshRemovePrompt(entry, owned)
		end

		self:_refreshPlaceEligibility()
		return
	end

	if mode == "remove" then
		-- The removed skewer leaves; its prompt is a child of the model, so it goes too
		local removed = entries[removeAt]
		if removed.model then
			Spr.stop(removed.model)
			removed.model:Destroy()
		end
		table.remove(entries, removeAt)
	end

	-- The skewers that stay slide as the row re-centres, each keeping its rotation so it doesn't spin
	for i = 1, #entries do
		local entry = entries[i]
		entry.record = records[i]
		if entry.model then
			Spr.target(entry.model, SHIFT_DAMPING, SHIFT_FREQUENCY, { Pivot = self:_slotCFrame(i, n, entry.rotation) })
		end
	end

	if mode == "append" then
		-- The new skewer drops into its slot from just above
		local record = records[n]
		local rotation = randomSkewerRotation()
		local model = self:_buildModel(record)
		if model then
			model:PivotTo(self:_slotCFrame(n, n, rotation, DROP_RISE))
			model.Parent = self._part
			Spr.target(model, SHIFT_DAMPING, SHIFT_FREQUENCY, { Pivot = self:_slotCFrame(n, n, rotation) })

			-- Off the skewer, so a place at the end of a full row sounds like it came from that end
			SoundController:PlaySound("Place", model:GetPivot())
		end
		local entry = { record = record, model = model, prompt = nil, rotation = rotation }
		entries[n] = entry
		self:_refreshRemovePrompt(entry, owned)
	end

	self:_refreshPlaceEligibility()
end

-- Re-evaluates ownership: the owner gets the place prompt and a take prompt per skewer, a visitor neither.
function SkewerStand:RefreshPrompt()
	local owned = self:_owned()

	if owned and not self._placePrompt then
		local prompt = Instance.new("ProximityPrompt")
		prompt.RequiresLineOfSight = false
		prompt.HoldDuration = 0.3
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.MaxActivationDistance = PROMPT_DISTANCE
		prompt.ActionText = "Place BBQ"
		prompt.Parent = self._promptAnchor

		self._placePrompt = prompt
		self._placeCleaner:Add(prompt)
		self._placeCleaner:Connect(prompt.Triggered, function()
			SkewerStandController = SkewerStandController or require(script.Parent)
			SkewerStandController:RequestPlace()
		end)
	elseif not owned and self._placePrompt then
		self._placeCleaner:Clean()
		self._placePrompt = nil
	end

	self:_refreshPlaceEligibility()

	for _, entry in self._entries do
		self:_refreshRemovePrompt(entry, owned)
	end
end

-- Puts the same answer on the prompt and the glow. Any skewer with room qualifies, however it cooked.
function SkewerStand:_refreshPlaceEligibility()
	local skewer = EquippedItem.GetSkewer()
	local hasRoom = self:_owned() and skewer ~= nil and self._count < MAX_SKEWERS

	self._sellStall:SetAttribute("HighlightColor", Highlights.CLAIM)
	if hasRoom then
		self._sellStall:AddTag(Highlights.TAG)
	else
		self._sellStall:RemoveTag(Highlights.TAG)
	end

	if self._placePrompt then
		self._placePrompt.Enabled = hasRoom
	end
end

function SkewerStand:Destroy()
	-- The stall is the base's, so leaving the tag on would keep it breathing with nothing driving it
	self._sellStall:RemoveTag(Highlights.TAG)

	for _, entry in self._entries do
		if entry.model then
			Spr.stop(entry.model)
			entry.model:Destroy()
		end
	end
	table.clear(self._entries)

	self._cleaner:Destroy()
	self = nil
end

return SkewerStand
