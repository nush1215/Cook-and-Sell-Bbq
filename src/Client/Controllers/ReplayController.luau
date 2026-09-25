-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local ReplayFormat = require(Shared.ReplayFormat)
local Structures = require(Shared.Config.Structures)
local GridUtil = require(Shared.GridUtil)

-- Controllers
local BuildController = require(script.Parent.BuildController)
local TutorialController = require(script.Parent.TutorialController)

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

local Moment = ReplayFormat.Moment
local Flag = ReplayFormat.Flag

-- The structure a ghost is rebuilt as when the recording never said which tool was out
local FALLBACK_STRUCTURE_ID = "RustyGrill"

-- The stand-in for the recorded player when the viewer has no character to dress it as
local DUMMY_HEIGHT = 5
local DUMMY_WIDTH = 2
local DUMMY_COLOR = Color3.fromRGB(80, 170, 255)
local DUMMY_TRANSPARENCY = 0.35

-- The avatar's animation thresholds, in studs a second between two samples
local WALK_SPEED = 0.8
local JUMP_SPEED = 4
local FALL_SPEED = 4
-- The walk cycle's own pace, which a recorded speed is measured against
local WALK_ANIMATION_SPEED = 16
local ANIMATION_FADE = 0.2
-- Closer than this to the avatar's head is first person, where the player never saw their own body
local FIRST_PERSON_DISTANCE = 1.5

-- The line out along the recorded camera, which only reads from the orbit view
local AIM_LENGTH = 40
local AIM_THICKNESS = 0.15
local AIM_COLOR = Color3.fromRGB(255, 225, 90)

-- The rebuilt ghost wears the verdict, matching what the player was actually looking at
local GHOST_VALID_COLOR = Color3.fromRGB(0, 255, 0)
local GHOST_INVALID_COLOR = Color3.fromRGB(220, 70, 70)
local GHOST_TRANSPARENCY = 0.55

-- Where the orbit camera sits relative to the avatar, how fast it catches up, and the FOV it looks through
local ORBIT_OFFSET = Vector3.new(0, 26, 34)
local ORBIT_FOLLOW_SPEED = 8
local ORBIT_FOV = 70
-- The widest a camera may look, which is also the most the letterbox may stretch their field of view to
local MAX_FOV = 120

-- The tutorial's guide, which the recorded player could only see from this step on (see Sequence 1)
local GUIDE_NAME = "Grill"
local GUIDE_STEP = "EquipGrill"
-- Mirrors TutorialController's guide dressing, so the rebuilt one looks like the one they were shown
local GUIDE_HITBOX_TRANSPARENCY = 0.5
local GUIDE_HIGHLIGHT_COLOR = Color3.fromRGB(255, 200, 40)
local GUIDE_HIGHLIGHT_FILL = 0.55
local PLACE_HERE_LABEL_NAME = "TutorialPlaceHere"

-- The walked path. Segments are only laid where the player actually moved, so standing still costs nothing
local PATH_THICKNESS = 0.2
local PATH_COLOR = Color3.fromRGB(120, 200, 255)
local PATH_TRANSPARENCY = 0.35
local PATH_MIN_STEP = 1
local PATH_MAX_SEGMENTS = 400

-- Screen-space layers, each above the one before: the viewer's panel has to sit over the recording's own spotlight
local STAND_IN_DISPLAY_ORDER = 120 -- where Satchel's hotbar draws
local SPOTLIGHT_DISPLAY_ORDER = 255 -- where SpotlightUI draws
local OVERLAY_DISPLAY_ORDER = 900
local PANEL_DISPLAY_ORDER = 1000

-- Stroke thicknesses in the Studio UI are authored for this screen height, which Components/UIStroke scales from
local STROKE_BASELINE_HEIGHT = 1080

-- The hotbar stand-in, drawn over Satchel's own slot rectangles
local SLOT_COLOR = Color3.fromRGB(30, 32, 36)
local SLOT_TRANSPARENCY = 0.3
local SLOT_EQUIPPED_COLOR = Color3.fromRGB(0, 162, 255)
local SLOT_EQUIPPED_THICKNESS = 4
local INVENTORY_COLOR = Color3.fromRGB(25, 27, 29)
local INVENTORY_TRANSPARENCY = 0.3

-- The spotlight stand-in. Dim and arrow mirror SpotlightUI's overlay and TutorialController's frame arrow
local SPOTLIGHT_DIM_TRANSPARENCY = 0.4
local SPOTLIGHT_DIM_THICKNESS = 10000
local SPOTLIGHT_CORNER = 12
local SPOTLIGHT_PADDING = 12
local SPOTLIGHT_ARROW_IMAGE = "rbxassetid://121406419675661"
local SPOTLIGHT_ARROW_COLOR = Color3.fromRGB(255, 40, 40)
local SPOTLIGHT_ARROW_SCALE = 1.4
local SPOTLIGHT_ARROW_GAP = 4
local SPOTLIGHT_ARROW_BOB = 10
local SPOTLIGHT_ARROW_BOB_SPEED = 6

-- The pointer overlay, in the recording device's pixels
local CURSOR_IMAGE = "rbxasset://textures/Cursors/KeyboardMouse/ArrowFarCursor.png"
local CURSOR_SIZE = 64
local CURSOR_PRESSED_COLOR = Color3.fromRGB(255, 90, 90)
local FINGER_SIZE = 44
local FINGER_COLOR = Color3.fromRGB(255, 255, 255)
local FINGER_TRANSPARENCY = 0.45
local RIPPLE_DURATION = 0.6
local RIPPLE_START_SIZE = 16
local RIPPLE_END_SIZE = 90
local RIPPLE_COLOR = Color3.fromRGB(255, 225, 90)
local KEY_CHIP_DURATION = 1.2
local KEY_CHIP_MAX = 4
local BANNER_COLOR = Color3.fromRGB(255, 190, 80)
local MENU_DIM_TRANSPARENCY = 0.45
-- A frame gap's banner stays up at least this long, so a short stall is still readable
local GAP_BANNER_MIN = 1

-- How long a toast outlives its duration while it fades, and how many stack at once (see NotificationController)
local TOAST_FADE = 0.5
local MAX_TOASTS = 4

-- Prompt billboards over the spot the recorded prompt was on
local PROMPT_BILLBOARD_SIZE = UDim2.fromOffset(220, 54)
local PROMPT_BILLBOARD_OFFSET = Vector3.new(0, 2.5, 0)

-- Wide enough for the control row, which sums to 602 plus the 28 of padding. Re-sum it when a control changes
local PANEL_WIDTH = 640
local PANEL_HEIGHT = 160
local FEED_WIDTH = 300
local FEED_LINE_HEIGHT = 18
-- The gap kept between the recording, the panel, the feed and the screen edge
local MARGIN = 12
local TRACK_HEIGHT = 20
local SPEEDS = { 0.25, 0.5, 1, 2, 4 }
local DEFAULT_SPEED_INDEX = 3

-- Panel chrome. Built in code like the project's other debug panels rather than authored in Studio, since
-- nothing here is player-facing and it ships with the tooling rather than the game.
local PANEL_BACKGROUND = Color3.fromRGB(20, 22, 28)
local PANEL_STROKE = Color3.fromRGB(58, 63, 75)
local CONTROL_BACKGROUND = Color3.fromRGB(38, 42, 52)
local CONTROL_HOVER = Color3.fromRGB(54, 60, 73)
local CONTROL_ACTIVE = Color3.fromRGB(70, 130, 215)
local TEXT_PRIMARY = Color3.fromRGB(240, 243, 248)
local TEXT_MUTED = Color3.fromRGB(150, 158, 175)
local BAR_COLOR = Color3.fromRGB(8, 9, 12)

-- The timeline, and the shade over the stretch before the reported step began
local TRACK_BACKGROUND = Color3.fromRGB(44, 48, 59)
local TRACK_PRE_STEP = Color3.fromRGB(32, 35, 43)
local TRACK_FILL = Color3.fromRGB(70, 130, 215)
local TRACK_HANDLE = Color3.fromRGB(255, 255, 255)

-- Feed lines and timeline pips, coloured by what happened
local EVENT_PRESS = Color3.fromRGB(120, 190, 255)
local EVENT_TOAST = Color3.fromRGB(235, 110, 110)
local EVENT_STEP = Color3.fromRGB(255, 205, 80)
local EVENT_ALERT = Color3.fromRGB(255, 150, 70)
local EVENT_OTHER = Color3.fromRGB(150, 158, 175)

-- The verdict dot beside the read-out
local STATE_VALID = Color3.fromRGB(80, 210, 110)
local STATE_REFUSED = Color3.fromRGB(230, 95, 85)
local STATE_NONE = Color3.fromRGB(120, 128, 145)

-- A rounded, hoverable control. Every button on the panel is one of these
local function makeButton(parent: Instance, text: string, width: number, order: number): TextButton
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(0, width, 1, 0)
	button.LayoutOrder = order
	button.BackgroundColor3 = CONTROL_BACKGROUND
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Font = Enum.Font.GothamMedium
	button.TextSize = 13
	button.TextColor3 = TEXT_PRIMARY
	button.Text = text
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = button

	-- Hover is only painted on a button that isn't currently the active one, which owns its colour
	button.MouseEnter:Connect(function()
		if button:GetAttribute("Active") ~= true then
			button.BackgroundColor3 = CONTROL_HOVER
		end
	end)
	button.MouseLeave:Connect(function()
		if button:GetAttribute("Active") ~= true then
			button.BackgroundColor3 = CONTROL_BACKGROUND
		end
	end)

	return button
end

-- A plain label. Monospace where a figure would otherwise jitter as its digits change width
local function makeLabel(parent: Instance, width: number, order: number, mono: boolean?): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0, width, 1, 0)
	label.LayoutOrder = order
	label.BackgroundTransparency = 1
	label.Font = if mono then Enum.Font.Code else Enum.Font.Gotham
	label.TextSize = 13
	label.TextColor3 = TEXT_MUTED
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = ""
	label.Parent = parent

	return label
end

-- A borderless frame, the base of every stand-in and overlay piece.
local function makeFrame(parent: Instance, color: Color3, transparency: number, cornerRadius: UDim?): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	frame.BorderSizePixel = 0
	frame.Parent = parent

	if cornerRadius then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = cornerRadius
		corner.Parent = frame
	end

	return frame
end

-- Minutes and seconds, since a drop runs to a few minutes and raw seconds stop reading at that length.
local function formatTime(seconds: number): string
	return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
end

-- A recorded line with its colour tags taken off, for the feed's plain labels.
local function stripMarkup(text: string): string
	return (string.gsub(text, "<[^>]*>", ""))
end

-- A horizontal row that lays its children out left to right.
local function makeRow(parent: Instance, height: number, order: number, padding: number): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, height)
	row.LayoutOrder = order
	row.BackgroundTransparency = 1
	row.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, padding)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row

	return row
end

-- The short way round between two headings. Orientations come back in -180..180, so a track crossing the
-- wrap would otherwise spin the avatar a whole turn the wrong way between two samples.
local function lerpAngle(from: number, to: number, alpha: number): number
	return from + ((to - from + 180) % 360 - 180) * alpha
end

-- An inert marker part. Everything the viewer draws is anchored, uncollidable and unqueryable, so none of it
-- can be walked into, clicked or raycast by anything else on this client.
-- Neon is kept for the small things that have to be findable on screen; the path and the guide cover real
-- ground, and glowing they wash the base out rather than reading over it
local function makeMarker(
	name: string,
	size: Vector3,
	color: Color3,
	transparency: number,
	parent: Instance,
	glow: boolean?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Transparency = transparency
	part.Material = if glow then Enum.Material.Neon else Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = parent

	return part
end

-- Makes a clone inert: no scripts, no tags for a component to bind to, nothing to collide with or query.
local function stripClone(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") then
			descendant:Destroy()
			continue
		end

		for _, tag in descendant:GetTags() do
			descendant:RemoveTag(tag)
		end

		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	for _, tag in root:GetTags() do
		root:RemoveTag(tag)
	end
end

-- A drop report's recording, played back on the base the viewer is standing on and through the player's own
-- screen. Everything it builds is local to this client -- no rig, no replication, nothing another player can
-- see -- so running one can't disturb the game.
local ReplayController = {
	PlayReplayEvent = Network.Event("PlayReplay"),
	StopReplayEvent = Network.Event("StopReplay"),

	_cleaner = Trove.new(),
	-- Everything about the replay running now, nil when none is; one table so stopping is one assignment
	_session = nil,
}

-- A fresh read of the recording's state before its first moment, which is where a backwards seek starts over.
local function newState()
	return {
		Time = -math.huge,
		Index = 1, -- the next moment not yet applied
		Screen = nil,
		Ui = {}, -- [path] = { Shown, X, Y, W, H, Offset? }
		Title = nil,
		Description = nil,
		Held = nil, -- { Slot, Name, StructureId }
		Slots = {}, -- [index] = { Name, Icon, X, Y, W, H }
		Spot = nil, -- { X, Y, W, H, Arrow }
		Prompts = {}, -- [action|object] = { Action, Object, Position }
		Step = nil,
	}
end

-- The two samples either side of `at` and how far between them it sits.
function ReplayController:_sampleAt(at: number)
	local session = self._session
	local samples = session.Samples
	local exact = math.clamp(at * session.Rate, 0, #samples - 1)
	local index = math.floor(exact)

	return samples[index + 1], samples[math.min(index + 2, #samples)], exact - index
end

-- Where the recorded pointer was at `at`, eased between samples, or nil with nothing on the screen.
function ReplayController:_pointerAt(at: number): Vector2?
	local from, to, alpha = self:_sampleAt(at)
	if not from.Pointer then
		return nil
	end

	return if to.Pointer then from.Pointer:Lerp(to.Pointer, alpha) else from.Pointer
end

-- Folds one moment into the running state. One-off moments (toasts, taps, marks) are read from their own lists.
function ReplayController:_applyMoment(state, moment: { any })
	local kind = moment[2]

	if kind == Moment.Screen then
		state.Screen = {
			W = moment[3],
			H = moment[4],
			InsetLeft = moment[5],
			InsetTop = moment[6],
			InsetRight = moment[7],
			InsetBottom = moment[8],
		}
	elseif kind == Moment.Ui then
		local path = moment[3]
		local entry = { Shown = moment[4] == 1, X = moment[5], Y = moment[6], W = moment[7], H = moment[8] }

		-- A follower's recorded spot is only where it happened to be; its offset from the pointer is what holds
		if entry.Shown and ReplayFormat.POINTER_FOLLOWERS[path] then
			local pointer = self:_pointerAt(math.max(moment[1], 0) / self._session.Rate)
			entry.Offset = pointer and Vector2.new(entry.X, entry.Y) - pointer
		end

		state.Ui[path] = entry
	elseif kind == Moment.Text then
		state.Title = moment[3]
		state.Description = moment[4]
	elseif kind == Moment.Held then
		state.Held = { Slot = moment[3], Name = moment[4], StructureId = moment[5] }
	elseif kind == Moment.Slot then
		state.Slots[moment[3]] = if moment[4] == ""
			then nil
			else { Name = moment[4], Icon = moment[5], X = moment[6], Y = moment[7], W = moment[8], H = moment[9] }
	elseif kind == Moment.Spot then
		state.Spot = if moment[5] > 0
			then { X = moment[3], Y = moment[4], W = moment[5], H = moment[6], Arrow = moment[7] == 1 }
			else nil
	elseif kind == Moment.Prompt then
		local key = `{moment[4]}|{moment[5]}`
		state.Prompts[key] = if moment[3] == ReplayFormat.PromptEvent.Hidden
			then nil
			else { Action = moment[4], Object = moment[5], Position = Vector3.new(moment[6], moment[7], moment[8]) }
	elseif kind == Moment.Step then
		state.Step = moment[3]
	end
end

-- Brings the running state to the playhead: forward from where it is, or from the top after a backwards seek.
function ReplayController:_advanceState(at: number)
	local session = self._session

	if at < session.State.Time then
		session.State = newState()
	end

	local state = session.State
	local moments = session.Moments

	while state.Index <= #moments and moments[state.Index][1] / session.Rate <= at do
		self:_applyMoment(state, moments[state.Index])
		state.Index += 1
	end

	state.Time = at
end

-- One readable feed line per moment worth reading, plus the menu, focus and device changes only the samples carry.
function ReplayController:_buildFeedEntries(): { any }
	local session = self._session
	local entries = {}
	local shownPaths = {}
	local spotShown = false
	local screenText = nil

	local function add(at: number, text: string, color: Color3)
		table.insert(entries, { T = math.max(at, 0), Text = text, Color = color, Order = #entries })
	end

	for _, moment in session.Moments do
		local at = moment[1] / session.Rate
		local kind = moment[2]

		if kind == Moment.Ui then
			local path, shown = moment[3], moment[4] == 1

			-- Position-only moments and the pointer-hugging hints would bury everything else
			if (shownPaths[path] or false) ~= shown and not ReplayFormat.POINTER_FOLLOWERS[path] then
				add(at, `{if shown then "opened" else "closed"} {path}`, EVENT_OTHER)
			end
			shownPaths[path] = shown
		elseif kind == Moment.Text then
			add(at, `banner: {stripMarkup(moment[4])}`, EVENT_STEP)
		elseif kind == Moment.Held then
			add(at, if moment[4] ~= "" then `holding {moment[4]}` else "put the tool away", EVENT_OTHER)
		elseif kind == Moment.Spot then
			local shown = moment[5] > 0
			if shown ~= spotShown then
				add(at, if shown then "spotlight on" else "spotlight off", EVENT_OTHER)
			end
			spotShown = shown
		elseif kind == Moment.Prompt and moment[3] ~= ReplayFormat.PromptEvent.Hidden then
			local used = moment[3] == ReplayFormat.PromptEvent.Triggered
			add(
				at,
				`{if used then "used prompt" else "prompt"}: {moment[4]} {moment[5]}`,
				if used then EVENT_PRESS else EVENT_OTHER
			)
		elseif kind == Moment.Step then
			add(at, `step → {moment[3]}`, EVENT_STEP)
		elseif kind == Moment.Toast then
			add(at, `toast: {stripMarkup(moment[3])}`, EVENT_TOAST)
		elseif kind == Moment.Tap then
			add(at, `pressed {moment[5]}`, EVENT_PRESS)
		elseif kind == Moment.Mark then
			local mark, detail = moment[3], moment[4]

			if mark == ReplayFormat.Mark.Place then
				add(at, if detail == "" then "place ✓ sent" else `place ✗ {detail}`, EVENT_PRESS)
			elseif mark == ReplayFormat.Mark.Rotate then
				add(at, "rotate", EVENT_PRESS)
			elseif mark == ReplayFormat.Mark.Key then
				add(at, `key {detail}`, EVENT_PRESS)
			elseif mark == ReplayFormat.Mark.Gap then
				add(at, `frame stalled {detail}s`, EVENT_ALERT)
			end
		elseif kind == Moment.Screen then
			local text = `screen {moment[3]}×{moment[4]}`
			if text ~= screenText then
				add(at, text, EVENT_OTHER)
			end
			screenText = text
		end
	end

	local menuOpen, unfocused, input = false, false, nil
	for index, sample in session.Samples do
		local at = (index - 1) / session.Rate
		local sampleMenu = bit32.band(sample.Flags, Flag.MenuOpen) ~= 0
		local sampleUnfocused = bit32.band(sample.Flags, Flag.Unfocused) ~= 0

		if sampleMenu ~= menuOpen then
			add(at, if sampleMenu then "opened the Roblox menu" else "closed the Roblox menu", EVENT_ALERT)
		end
		if sampleUnfocused ~= unfocused then
			add(at, if sampleUnfocused then "left the game window" else "came back to the game", EVENT_ALERT)
		end
		if input and sample.Input ~= input then
			-- A forged or newer recording can carry a value this build has no input for
			local device = Enum.PreferredInput:FromValue(sample.Input)
			add(at, `switched to {if device then device.Name else sample.Input}`, EVENT_ALERT)
		end

		menuOpen, unfocused, input = sampleMenu, sampleUnfocused, sample.Input
	end

	add(session.Duration, "left the game", EVENT_ALERT)

	-- Samples and moments were walked separately; Order keeps two lines at the same instant as they were added
	table.sort(entries, function(a, b)
		if a.T == b.T then
			return a.Order < b.Order
		end
		return a.T < b.T
	end)

	return entries
end

-- A full-screen gui holding a frame the size of their screen, scaled down into the letterbox. Every screen-space
-- piece of the recording is drawn into one, in the recording device's own pixels. Takes an existing gui to adopt.
function ReplayController:_addLayer(name: string, displayOrder: number, gui: ScreenGui?)
	local layerGui = gui
	if not layerGui then
		-- Sibling, so a stand-in's ZIndex only orders it among its neighbours; an adopted mirror keeps its own
		layerGui = Instance.new("ScreenGui")
		layerGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	end
	layerGui.Name = name
	layerGui.ResetOnSpawn = false
	layerGui.IgnoreGuiInset = true
	layerGui.ScreenInsets = Enum.ScreenInsets.None
	layerGui.DisplayOrder = displayOrder
	layerGui.Enabled = true
	self._cleaner:Add(layerGui)

	-- Clips, so a HUD slid off their screen or a dim meant to cover it stops at the letterbox
	local area = Instance.new("Frame")
	area.Name = "ReplayArea"
	area.BackgroundTransparency = 1
	area.ClipsDescendants = true
	area.Parent = layerGui

	local device = Instance.new("Frame")
	device.Name = "ReplayDevice"
	device.BackgroundTransparency = 1
	device.Parent = area

	local scale = Instance.new("UIScale")
	scale.Parent = device

	layerGui.Parent = PlayerGui

	local layer = { Gui = layerGui, Area = area, Device = device, Scale = scale }
	table.insert(self._session.Layers, layer)

	return layer
end

-- Clones every Studio gui the recording saw from StarterGui's authored copy, made inert and laid into a layer
-- whose first-level frames the recording drives. Code-built guis have no authored copy and get stand-ins instead.
function ReplayController:_buildMirrors()
	local session = self._session
	local screenHeight = nil
	local names = {}

	for _, moment in session.Moments do
		if moment[2] == Moment.Ui then
			names[string.match(moment[3], "^[^/]+")] = true
		elseif moment[2] == Moment.Screen and not screenHeight then
			screenHeight = moment[4]
		end
	end

	-- Their first screen, which the Studio strokes were scaled to; state isn't advanced yet, so it's read here
	screenHeight = screenHeight or workspace.CurrentCamera.ViewportSize.Y

	for name in names do
		local source = StarterGui:FindFirstChild(name)
		if not (source and source:IsA("ScreenGui")) then
			continue
		end

		local clone = source:Clone()
		stripClone(clone)

		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("GuiButton") or descendant:IsA("TextBox") then
				descendant.Interactable = false
			elseif descendant:IsA("UIStroke") and descendant.StrokeSizingMode ~= Enum.StrokeSizingMode.ScaledSize then
				-- The thickness their screen drew it at. Tagged so UIController's re-tag can't rescale it to this one
				descendant.Thickness = math.ceil(screenHeight * descendant.Thickness / STROKE_BASELINE_HEIGHT)
				descendant:AddTag("IgnoreUIStroke")
			end
		end

		local children = clone:GetChildren()
		local layer = self:_addLayer(`ReplayMirror_{name}`, source.DisplayOrder, clone)
		local surfaces = {}

		for _, child in children do
			child.Parent = layer.Device

			-- Placed from the recording, so a layout at the top would only fight the recorded spots
			if child:IsA("UIGridStyleLayout") then
				child:Destroy()
			elseif child:IsA("GuiObject") and not surfaces[child.Name] then
				child.Visible = false

				-- The recorded size already includes this scale, so the frame is sized to land on it once scaled
				local uiScale = child:FindFirstChildOfClass("UIScale")
				surfaces[child.Name] = { Object = child, Scale = math.max(uiScale and uiScale.Scale or 1, 0.01) }
			end
		end

		session.Mirrors[name] = { Layer = layer, Surfaces = surfaces }
	end

	-- The two authored guis the recording puts content into, not just shows
	local tutorial = session.Mirrors.TutorialUI
	session.Banner = tutorial and tutorial.Surfaces.Holder and tutorial.Surfaces.Holder.Object

	local notification = session.Mirrors.NotificationUI
	local templates = notification and notification.Layer.Device:FindFirstChild("Templates")
	session.ToastTemplate = templates and templates:FindFirstChild("NormalNotificationTemplate")
	session.ToastContainer = notification and notification.Layer.Device:FindFirstChild("NotificationContainer")
end

-- The stand-ins for what Satchel and SpotlightUI build in code, plus the pointer overlay on top of everything.
function ReplayController:_buildStandIns()
	local session = self._session

	local hotbar = self:_addLayer("ReplayStandIns", STAND_IN_DISPLAY_ORDER)
	session.Inventory = makeFrame(hotbar.Device, INVENTORY_COLOR, INVENTORY_TRANSPARENCY, UDim.new(0.02, 0))
	session.SlotHolder = hotbar.Device
	session.SlotFrames = {}

	local spotlight = self:_addLayer("ReplaySpotlight", SPOTLIGHT_DISPLAY_ORDER)
	local hole = makeFrame(spotlight.Device, Color3.new(0, 0, 0), 1, UDim.new(0, SPOTLIGHT_CORNER))
	local dim = Instance.new("UIStroke")
	dim.Color = Color3.new(0, 0, 0)
	dim.Thickness = SPOTLIGHT_DIM_THICKNESS
	dim.Transparency = SPOTLIGHT_DIM_TRANSPARENCY
	dim.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	dim.Parent = hole
	session.SpotHole = hole

	local arrow = Instance.new("ImageLabel")
	arrow.Image = SPOTLIGHT_ARROW_IMAGE
	arrow.ImageColor3 = SPOTLIGHT_ARROW_COLOR
	arrow.BackgroundTransparency = 1
	arrow.ScaleType = Enum.ScaleType.Fit
	arrow.AnchorPoint = Vector2.new(0.5, 1)
	arrow.ZIndex = 2
	arrow.Parent = spotlight.Device
	session.SpotArrow = arrow

	local overlay = self:_addLayer("ReplayOverlay", OVERLAY_DISPLAY_ORDER)
	session.Overlay = overlay.Device

	local menuDim = makeFrame(overlay.Device, Color3.new(0, 0, 0), MENU_DIM_TRANSPARENCY)
	menuDim.Size = UDim2.fromScale(1, 1)
	session.MenuDim = menuDim

	local banner = Instance.new("TextLabel")
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, 90)
	banner.Size = UDim2.fromOffset(700, 60)
	banner.BackgroundColor3 = PANEL_BACKGROUND
	banner.BackgroundTransparency = 0.2
	banner.Font = Enum.Font.GothamBold
	banner.TextSize = 30
	banner.TextColor3 = BANNER_COLOR
	banner.ZIndex = 5
	banner.Parent = overlay.Device
	session.AlertBanner = banner

	local bannerCorner = Instance.new("UICorner")
	bannerCorner.CornerRadius = UDim.new(0, 10)
	bannerCorner.Parent = banner

	local cursor = Instance.new("ImageLabel")
	cursor.Image = CURSOR_IMAGE
	cursor.BackgroundTransparency = 1
	cursor.AnchorPoint = Vector2.new(0.5, 0.5)
	cursor.Size = UDim2.fromOffset(CURSOR_SIZE, CURSOR_SIZE)
	cursor.ZIndex = 10
	cursor.Parent = overlay.Device
	session.Cursor = cursor

	session.Fingers = {}
	for index = 1, 2 do
		local finger = makeFrame(overlay.Device, FINGER_COLOR, FINGER_TRANSPARENCY, UDim.new(1, 0))
		finger.AnchorPoint = Vector2.new(0.5, 0.5)
		finger.Size = UDim2.fromOffset(FINGER_SIZE, FINGER_SIZE)
		finger.ZIndex = 10

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Transparency = 0.5
		stroke.Thickness = 2
		stroke.Parent = finger

		session.Fingers[index] = finger
	end

	local keys = Instance.new("Frame")
	keys.BackgroundTransparency = 1
	keys.Size = UDim2.new(1, -40, 0, 44)
	keys.Position = UDim2.fromOffset(20, 20)
	keys.ZIndex = 5
	keys.Parent = overlay.Device
	session.KeyRow = keys

	local keyLayout = Instance.new("UIListLayout")
	keyLayout.FillDirection = Enum.FillDirection.Horizontal
	keyLayout.Padding = UDim.new(0, 8)
	keyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	keyLayout.Parent = keys

	session.Ripples = {} -- [tap index] = the ring drawn for it while it's fresh
	session.ToastFrames = {} -- [text] = the mirrored toast showing it
	session.PromptBillboards = {} -- [action|object] = { Anchor }, the invisible part its billboard hangs off
end

-- The avatar: a local clone of the viewer's own character, posed and animated from the track. Falls back to a
-- neon block when there's no character to dress it as.
function ReplayController:_buildAvatar(holder: Instance)
	local session = self._session
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if not humanoid then
		session.Dummy = makeMarker(
			"ReplayDummy",
			Vector3.new(DUMMY_WIDTH, DUMMY_HEIGHT, DUMMY_WIDTH),
			DUMMY_COLOR,
			DUMMY_TRANSPARENCY,
			holder,
			true
		)
		return
	end

	-- Characters refuse to clone unless asked, so it's allowed for the one call and put back
	local archivable = character.Archivable
	character.Archivable = true
	local clone = character:Clone()
	character.Archivable = archivable

	-- Read off the live Animate before the clone's copy is stripped with the other scripts
	local animate = character:FindFirstChild("Animate")
	local function loadTrack(animator: Animator, folderName: string, animationName: string): AnimationTrack?
		local folder = animate and animate:FindFirstChild(folderName)
		local source = folder and folder:FindFirstChild(animationName)
		if not source then
			return nil
		end

		local animation = Instance.new("Animation")
		animation.AnimationId = source.AnimationId
		return animator:LoadAnimation(animation)
	end

	-- Whatever the viewer is carrying goes too: a held item is a model welded on, and the recorded player held none
	stripClone(clone)
	for _, descendant in clone:GetDescendants() do
		if
			descendant:IsA("Tool")
			or descendant:IsA("Model")
			or descendant:IsA("ForceField")
			or descendant:IsA("BillboardGui")
		then
			descendant:Destroy()
		end
	end

	clone.Name = "ReplayAvatar"
	local root = clone:FindFirstChild("HumanoidRootPart")
	root.Anchored = true

	local cloneHumanoid = clone:FindFirstChildOfClass("Humanoid")
	cloneHumanoid.EvaluateStateMachine = false
	cloneHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	clone.Parent = holder

	local animator = cloneHumanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = cloneHumanoid

	session.Avatar = clone
	session.AvatarRoot = root
	session.AvatarHead = clone:FindFirstChild("Head")
	session.AvatarParts = {}
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") then
			table.insert(session.AvatarParts, descendant)
		end
	end

	session.Tracks = {
		Idle = loadTrack(animator, "idle", "Animation1"),
		Walk = loadTrack(animator, "walk", "WalkAnim"),
		Jump = loadTrack(animator, "jump", "JumpAnim"),
		Fall = loadTrack(animator, "fall", "FallAnim"),
	}

	for name, track in session.Tracks do
		track.Looped = name == "Idle" or name == "Walk"
	end
end

-- The avatar, the aim line, the walked path and the tutorial guide, all parented to the camera so nothing lands
-- in the datamodel another player could see. Ghosts are built on first need, one per structure.
function ReplayController:_buildScene()
	local session = self._session

	local holder = Instance.new("Folder")
	holder.Name = "ReplayScene"
	holder.Parent = workspace.CurrentCamera
	self._cleaner:Add(holder)
	session.SceneHolder = holder

	self:_buildAvatar(holder)

	session.Aim =
		makeMarker("ReplayAim", Vector3.new(AIM_THICKNESS, AIM_THICKNESS, AIM_LENGTH), AIM_COLOR, 0, holder, true)

	self:_buildGuide(holder)
	self:_buildPath(holder)
end

-- The tutorial's guide, cloned from the real one and dressed the way the tutorial dresses it. Left off a base whose
-- guide was never authored.
function ReplayController:_buildGuide(holder: Instance)
	local base = TutorialController:GetBaseIfPresent()
	local source = base and TutorialController:GetGuideModel(base.Name, GUIDE_NAME)
	if not source then
		return
	end

	local guide = source:Clone()
	stripClone(guide)

	-- The viewer's own copy may be out with its label held down, so it's replaced with a fresh one
	for _, descendant in guide:GetDescendants() do
		if descendant:IsA("BillboardGui") then
			descendant:Destroy()
		end
	end

	local hitbox = guide:FindFirstChild("Hitbox")
	if hitbox then
		hitbox.Transparency = GUIDE_HITBOX_TRANSPARENCY

		local selectionBox = hitbox:FindFirstChildOfClass("SelectionBox")
		if selectionBox then
			selectionBox.Visible = true
		end
	end

	local label = ReplicatedStorage.Assets.UI:FindFirstChild(PLACE_HERE_LABEL_NAME)
	if label then
		label:Clone().Parent = guide
	end

	local highlight = Instance.new("Highlight")
	highlight.FillColor = GUIDE_HIGHLIGHT_COLOR
	highlight.FillTransparency = GUIDE_HIGHLIGHT_FILL
	highlight.OutlineTransparency = 1
	highlight.Parent = guide

	guide.Parent = holder
	self._cleaner:Add(guide)
	self._session.Guide = guide
	self._session.GuideParent = holder
end

-- The walked path as one segment per stretch the player actually covered. Standing still adds nothing, so a
-- session spent in one spot draws a dot rather than four hundred parts stacked on each other.
function ReplayController:_buildPath(holder: Instance)
	local session = self._session
	local previous = nil
	local drawn = 0

	for _, sample in session.Samples do
		local point = session.Origin * sample.Position

		if not previous then
			previous = point
			continue
		end

		local offset = point - previous
		if offset.Magnitude < PATH_MIN_STEP or drawn >= PATH_MAX_SEGMENTS then
			continue
		end

		local segment = makeMarker(
			"ReplayPath",
			Vector3.new(PATH_THICKNESS, PATH_THICKNESS, offset.Magnitude),
			PATH_COLOR,
			PATH_TRANSPARENCY,
			holder
		)
		segment.CFrame = CFrame.lookAt(previous + offset / 2, point)

		previous = point
		drawn += 1
	end
end

-- The ghost for `structureId`, built the first time it's needed and kept. Nil for an id this build doesn't have.
function ReplayController:_getGhost(structureId: string)
	local session = self._session
	local ghost = session.Ghosts[structureId]
	if ghost then
		return ghost
	end

	local structure = Structures.GetStructureFromId(structureId)
	if not structure then
		return nil
	end

	-- The real model, stripped the way BuildController strips its own ghost, so the footprint is honest
	local model = structure.Model:Clone()
	model.Name = "ReplayGhost"
	stripClone(model)

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.Transparency = GHOST_TRANSPARENCY
		end
	end

	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = model
	highlight.Parent = model

	model.Parent = session.SceneHolder

	ghost = { Structure = structure, Model = model, Highlight = highlight }
	session.Ghosts[structureId] = ghost

	return ghost
end

-- Lays the letterbox out: their screen's shape, as large as fits once the panel and the feed have their margins.
-- Centred on the viewer's screen, since a camera can only look through its middle.
function ReplayController:_layout()
	local session = self._session
	local viewport = workspace.CurrentCamera.ViewportSize
	local screen = session.State.Screen or { W = viewport.X, H = viewport.Y }

	-- Checked every frame, so a rotated phone, a resized window or the feed toggling all land on the next one
	local layoutKey = `{viewport.X}|{viewport.Y}|{screen.W}|{screen.H}|{session.FeedShown}`
	if layoutKey == session.LayoutKey then
		return
	end
	session.LayoutKey = layoutKey

	local marginX = MARGIN + (if session.FeedShown then FEED_WIDTH + MARGIN else 0)
	local marginY = PANEL_HEIGHT + MARGIN * 2
	local scale = math.max(math.min((viewport.X - marginX * 2) / screen.W, (viewport.Y - marginY * 2) / screen.H), 0.05)
	local size = Vector2.new(screen.W, screen.H) * scale
	local position = (viewport - size) / 2

	session.AreaPosition = position
	session.AreaSize = size

	for _, layer in session.Layers do
		layer.Area.Position = UDim2.fromOffset(position.X, position.Y)
		layer.Area.Size = UDim2.fromOffset(size.X, size.Y)
		layer.Device.Size = UDim2.fromOffset(screen.W, screen.H)
		layer.Scale.Scale = scale
	end

	-- The bars around the recording, top, bottom, left, right
	local bars = session.Bars
	bars[1].Position = UDim2.fromOffset(0, 0)
	bars[1].Size = UDim2.new(1, 0, 0, position.Y)
	bars[2].Position = UDim2.fromOffset(0, position.Y + size.Y)
	bars[2].Size = UDim2.new(1, 0, 1, -(position.Y + size.Y))
	bars[3].Position = UDim2.fromOffset(0, position.Y)
	bars[3].Size = UDim2.fromOffset(position.X, size.Y)
	bars[4].Position = UDim2.fromOffset(position.X + size.X, position.Y)
	bars[4].Size = UDim2.new(1, -(position.X + size.X), 0, size.Y)

	session.Panel.Position = UDim2.fromOffset((viewport.X - PANEL_WIDTH) / 2, position.Y + size.Y + MARGIN)

	session.Feed.Visible = session.FeedShown
	session.Feed.Position = UDim2.fromOffset(position.X + size.X + MARGIN, position.Y)
	session.Feed.Size = UDim2.fromOffset(FEED_WIDTH, size.Y)
end

-- Moves the avatar, the aim line, the ghost, the guide and the prompts to where the playhead is.
function ReplayController:_renderWorld(from, to, alpha: number, cameraCFrame: CFrame)
	local session = self._session
	local state = session.State
	local origin = session.Origin

	local position = from.Position:Lerp(to.Position, alpha)
	local yaw = lerpAngle(from.Yaw, to.Yaw, alpha)
	local rootCFrame = origin * CFrame.new(position) * CFrame.Angles(0, math.rad(yaw), 0)

	if session.Avatar then
		session.AvatarRoot.CFrame = rootCFrame

		-- Per pair of samples rather than per frame, since the lerp between them is a straight line anyway
		local velocity = (to.Position - from.Position) * session.Rate
		local horizontal = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		local tracks = session.Tracks
		local track = if velocity.Y > JUMP_SPEED
			then tracks.Jump
			elseif velocity.Y < -FALL_SPEED then tracks.Fall
			elseif horizontal > WALK_SPEED then tracks.Walk
			else tracks.Idle

		if track ~= session.AvatarTrack then
			if session.AvatarTrack then
				session.AvatarTrack:Stop(ANIMATION_FADE)
			end
			if track then
				track:Play(ANIMATION_FADE)
			end
			session.AvatarTrack = track
		end

		if track then
			local pace = if track == tracks.Walk then horizontal / WALK_ANIMATION_SPEED else 1
			track:AdjustSpeed(if session.Playing then pace * SPEEDS[session.SpeedIndex] else 0)
		end

		-- In first person the player never saw their own body, so neither should the replay
		local hidden = session.TheirView
			and session.AvatarHead
			and (cameraCFrame.Position - session.AvatarHead.Position).Magnitude < FIRST_PERSON_DISTANCE
		local modifier = if hidden then 1 else 0
		if session.AvatarModifier ~= modifier then
			session.AvatarModifier = modifier
			for _, part in session.AvatarParts do
				part.LocalTransparencyModifier = modifier
			end
		end
	else
		session.Dummy.CFrame = rootCFrame * CFrame.new(0, DUMMY_HEIGHT / 2 - 3, 0)
	end

	session.Aim.CFrame = cameraCFrame * CFrame.new(0, 0, -AIM_LENGTH / 2)
	session.Aim.Transparency = if session.TheirView then 1 else 0

	-- The ghost of whatever structure they held; no cell means no ghost was showing that frame
	local held = state.Held
	local structureId = if held and held.StructureId ~= "" then held.StructureId else FALLBACK_STRUCTURE_ID
	local shownGhost = from.CellX and from.CellZ and self:_getGhost(structureId)

	for _, ghost in session.Ghosts do
		local shown = ghost == shownGhost
		ghost.Highlight.Enabled = shown

		if not shown then
			ghost.Model:PivotTo(CFrame.new(0, -500, 0))
		end
	end

	if shownGhost then
		local footprintX, footprintZ = Structures.GetFootprint(shownGhost.Structure, from.Rotation)
		local surface =
			GridUtil.CellToSurfaceCFrame(origin, from.CellX, from.CellZ, footprintX, footprintZ, Structures.CELL_SIZE)

		shownGhost.Model:PivotTo(Structures.GetPlacementPivot(shownGhost.Model, surface, from.Rotation))
		shownGhost.Highlight.OutlineColor = if from.State == ReplayFormat.State.Valid
			then GHOST_VALID_COLOR
			else GHOST_INVALID_COLOR
	end

	local guideParent = if state.Step == GUIDE_STEP then session.GuideParent else nil
	if session.Guide and session.Guide.Parent ~= guideParent then
		session.Guide.Parent = guideParent
	end

	-- Prompt billboards, one per prompt the player could see at the playhead
	local billboards = session.PromptBillboards
	for key, entry in billboards do
		if not state.Prompts[key] then
			entry.Anchor:Destroy()
			billboards[key] = nil
		end
	end

	for key, prompt in state.Prompts do
		if billboards[key] then
			continue
		end

		local anchor = makeMarker("ReplayPrompt", Vector3.one * 0.2, AIM_COLOR, 1, session.SceneHolder)
		anchor.CFrame = origin * CFrame.new(prompt.Position)

		local billboard = Instance.new("BillboardGui")
		billboard.Size = PROMPT_BILLBOARD_SIZE
		billboard.StudsOffset = PROMPT_BILLBOARD_OFFSET
		billboard.AlwaysOnTop = true
		billboard.Adornee = anchor
		billboard.Parent = anchor

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = PANEL_BACKGROUND
		label.BackgroundTransparency = 0.25
		label.Font = Enum.Font.GothamBold
		label.TextSize = 16
		label.TextColor3 = TEXT_PRIMARY
		label.Text = `{prompt.Action}\n{prompt.Object}`
		label.Parent = billboard

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = label

		billboards[key] = { Anchor = anchor }
	end
end

-- Their screen at the playhead: the mirrored guis, the banner and toasts, and the hotbar and spotlight stand-ins.
function ReplayController:_renderScreen(pointer: Vector2?, at: number)
	local session = self._session
	local state = session.State

	for name, mirror in session.Mirrors do
		for childName, surface in mirror.Surfaces do
			local path = `{name}/{childName}`
			local entry = state.Ui[path]
			local object = surface.Object
			local shown = entry ~= nil and entry.Shown

			object.Visible = shown
			if not shown then
				continue
			end

			local x, y = entry.X, entry.Y
			if entry.Offset and pointer then
				x, y = pointer.X + entry.Offset.X, pointer.Y + entry.Offset.Y
			end

			local anchor = object.AnchorPoint
			object.Position = UDim2.fromOffset(x + entry.W * anchor.X, y + entry.H * anchor.Y)
			object.Size = UDim2.fromOffset(entry.W / surface.Scale, entry.H / surface.Scale)
		end
	end

	local banner = session.Banner
	if banner and state.Title then
		banner.Title.Text = state.Title
		banner.Description.RichText = true
		banner.Description.Text = state.Description
	end

	self:_renderToasts(at)

	-- The hotbar, while Satchel's backpack frame was up
	local backpack = state.Ui["BackpackGui/Backpack"]
	local backpackShown = backpack ~= nil and backpack.Shown
	local inventory = state.Ui["BackpackGui/Backpack/Inventory"]

	session.Inventory.Visible = backpackShown and inventory ~= nil and inventory.Shown
	if session.Inventory.Visible then
		session.Inventory.Position = UDim2.fromOffset(inventory.X, inventory.Y)
		session.Inventory.Size = UDim2.fromOffset(inventory.W, inventory.H)
	end

	local heldSlot = state.Held and state.Held.Slot or 0
	for index, frame in session.SlotFrames do
		if not state.Slots[index] then
			frame:Destroy()
			session.SlotFrames[index] = nil
		end
	end

	for index, slot in state.Slots do
		local frame = session.SlotFrames[index]
		if not frame then
			frame = self:_makeSlotFrame()
			session.SlotFrames[index] = frame
		end

		frame.Visible = backpackShown and slot.W > 0
		frame.Position = UDim2.fromOffset(slot.X, slot.Y)
		frame.Size = UDim2.fromOffset(slot.W, slot.H)
		frame.Icon.Image = slot.Icon
		frame.ToolName.Text = slot.Name
		frame.UIStroke.Enabled = index == heldSlot
	end

	-- The spotlight hole and the arrow bobbing over the slot inside it
	local spot = state.Spot
	session.SpotHole.Visible = spot ~= nil
	session.SpotArrow.Visible = spot ~= nil and spot.Arrow
	if spot then
		session.SpotHole.Position = UDim2.fromOffset(spot.X, spot.Y)
		session.SpotHole.Size = UDim2.fromOffset(spot.W, spot.H)

		local size = math.min(spot.W, spot.H) - SPOTLIGHT_PADDING * 2
		local bob = (math.sin(os.clock() * SPOTLIGHT_ARROW_BOB_SPEED) + 1) / 2 * SPOTLIGHT_ARROW_BOB
		session.SpotArrow.Size = UDim2.fromOffset(size * SPOTLIGHT_ARROW_SCALE, size * SPOTLIGHT_ARROW_SCALE)
		session.SpotArrow.Position = UDim2.fromOffset(spot.X + spot.W / 2, spot.Y - SPOTLIGHT_ARROW_GAP - bob)
	end
end

-- One hotbar slot stand-in: Satchel's dark tile, icon, name and the equipped border.
function ReplayController:_makeSlotFrame(): Frame
	local frame = makeFrame(self._session.SlotHolder, SLOT_COLOR, SLOT_TRANSPARENCY, UDim.new(0, 8))
	frame.ZIndex = 2

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(0.85, 0.85)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = 3
	icon.Parent = frame

	local name = Instance.new("TextLabel")
	name.Name = "ToolName"
	name.BackgroundTransparency = 1
	name.Position = UDim2.fromScale(0.05, 0.6)
	name.Size = UDim2.fromScale(0.9, 0.35)
	name.Font = Enum.Font.GothamBold
	name.TextScaled = true
	name.TextColor3 = TEXT_PRIMARY
	name.TextStrokeTransparency = 0.4
	name.ZIndex = 4
	name.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = SLOT_EQUIPPED_COLOR
	stroke.Thickness = SLOT_EQUIPPED_THICKNESS
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame

	return frame
end

-- The toasts up at the playhead, stacked the way NotificationController stacks them: a repeat while one is up
-- counts on it and extends it rather than adding a second.
function ReplayController:_renderToasts(at: number)
	local session = self._session
	local template, container = session.ToastTemplate, session.ToastContainer
	if not (template and container) then
		return
	end

	local entries = {}
	for _, toast in session.Toasts do
		if toast.T > at then
			break
		end

		local entry = entries[toast.Text]
		if entry and toast.T < entry.Expires + TOAST_FADE then
			entry.Count += 1
		else
			entry = { Text = toast.Text, Count = 1 }
			entries[toast.Text] = entry
		end

		entry.Expires = toast.T + toast.Duration
		entry.Order = toast.T
	end

	local active = {}
	for _, entry in entries do
		if entry.Expires + TOAST_FADE > at then
			table.insert(active, entry)
		end
	end
	table.sort(active, function(a, b)
		return a.Order < b.Order
	end)

	local shown = {}
	for index = math.max(#active - MAX_TOASTS + 1, 1), #active do
		shown[active[index].Text] = active[index]
	end

	for text, frame in session.ToastFrames do
		if not shown[text] then
			frame:Destroy()
			session.ToastFrames[text] = nil
		end
	end

	for text, entry in shown do
		local frame = session.ToastFrames[text]
		if not frame then
			frame = template:Clone()
			frame.Visible = true
			frame.Parent = container
			session.ToastFrames[text] = frame
		end

		frame.LayoutOrder = math.round(entry.Order * 100)
		frame.Title.Text = if entry.Count > 1 then `{text} [{entry.Count}]` else text
	end
end

-- The pointer, fresh taps, recent keys and the menu, focus and stall banners, over everything on their screen.
function ReplayController:_renderOverlay(from, pointer: Vector2?, at: number)
	local session = self._session
	local touch = from.Input == Enum.PreferredInput.Touch.Value

	session.Cursor.Visible = pointer ~= nil and not touch
	if pointer then
		session.Cursor.Position = UDim2.fromOffset(pointer.X, pointer.Y)
		session.Cursor.ImageColor3 = if bit32.band(from.Flags, Flag.MouseButton1) ~= 0
			then CURSOR_PRESSED_COLOR
			else Color3.new(1, 1, 1)
	end

	-- Fingers show where they were held, which is how a thumbstick or a camera drag reads on a phone
	local _, to, alpha = self:_sampleAt(at)
	for index, finger in session.Fingers do
		local point = if index == 1 then pointer
			elseif from.Pointer2 and to.Pointer2 then from.Pointer2:Lerp(to.Pointer2, alpha)
			else from.Pointer2

		finger.Visible = touch and point ~= nil
		if point then
			finger.Position = UDim2.fromOffset(point.X, point.Y)
		end
	end

	for index, tap in session.Taps do
		local age = at - tap.T
		local ripple = session.Ripples[index]

		if age < 0 or age > RIPPLE_DURATION then
			if ripple then
				ripple:Destroy()
				session.Ripples[index] = nil
			end
			continue
		end

		if not ripple then
			ripple = makeFrame(session.Overlay, RIPPLE_COLOR, 1, UDim.new(1, 0))
			ripple.AnchorPoint = Vector2.new(0.5, 0.5)
			ripple.Position = UDim2.fromOffset(tap.X, tap.Y)
			ripple.ZIndex = 9

			local stroke = Instance.new("UIStroke")
			stroke.Color = RIPPLE_COLOR
			stroke.Thickness = 4
			stroke.Parent = ripple

			session.Ripples[index] = ripple
		end

		local progress = age / RIPPLE_DURATION
		local size = RIPPLE_START_SIZE + (RIPPLE_END_SIZE - RIPPLE_START_SIZE) * progress
		ripple.Size = UDim2.fromOffset(size, size)
		ripple.UIStroke.Transparency = progress
	end

	-- Rebuilt only when the set of keys on show changes, which is a press, not a frame
	local recent = {}
	for _, key in session.Keys do
		if key.T <= at and at - key.T < KEY_CHIP_DURATION then
			table.insert(recent, key)
		end
	end
	while #recent > KEY_CHIP_MAX do
		table.remove(recent, 1)
	end

	local keySignature = ""
	for _, key in recent do
		keySignature ..= `{key.T}{key.Name}|`
	end

	if keySignature ~= session.KeySignature then
		session.KeySignature = keySignature

		for _, child in session.KeyRow:GetChildren() do
			if child:IsA("TextLabel") then
				child:Destroy()
			end
		end

		for order, key in recent do
			local chip = Instance.new("TextLabel")
			chip.AutomaticSize = Enum.AutomaticSize.X
			chip.Size = UDim2.fromOffset(44, 44)
			chip.LayoutOrder = order
			chip.BackgroundColor3 = PANEL_BACKGROUND
			chip.BackgroundTransparency = 0.15
			chip.Font = Enum.Font.GothamBold
			chip.TextSize = 22
			chip.TextColor3 = TEXT_PRIMARY
			chip.Text = ` {key.Name} `
			chip.ZIndex = 5
			chip.Parent = session.KeyRow

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 8)
			corner.Parent = chip
		end
	end

	local menuOpen = bit32.band(from.Flags, Flag.MenuOpen) ~= 0
	local unfocused = bit32.band(from.Flags, Flag.Unfocused) ~= 0
	local stalled = nil
	for _, gap in session.Gaps do
		if gap.T <= at and at - gap.T < math.max(gap.Length, GAP_BANNER_MIN) then
			stalled = gap
		end
	end

	session.MenuDim.Visible = menuOpen
	session.AlertBanner.Visible = menuOpen or unfocused or stalled ~= nil
	session.AlertBanner.Text = if menuOpen
		then "Roblox menu open"
		elseif unfocused then "Game window in the background"
		elseif stalled then `Frame stalled for {stalled.Length}s`
		else ""
end

-- Moves everything to where the playhead is and writes the read-out.
function ReplayController:_render()
	local session = self._session
	local at = session.Time
	local from, to, alpha = self:_sampleAt(at)

	self:_advanceState(at)
	self:_layout()

	-- Interpolated like the body: samples land five a second, and a camera that snapped between them would
	-- be unwatchable through their eyes
	local cameraCFrame = session.Origin
		* CFrame.new(from.CameraPosition:Lerp(to.CameraPosition, alpha))
		* CFrame.Angles(0, math.rad(lerpAngle(from.CameraYaw, to.CameraYaw, alpha)), 0)
		* CFrame.Angles(math.rad(from.CameraPitch + (to.CameraPitch - from.CameraPitch) * alpha), 0, 0)

	self:_renderWorld(from, to, alpha, cameraCFrame)

	for _, layer in session.Layers do
		layer.Gui.Enabled = session.TheirView
	end
	for _, bar in session.Bars do
		bar.Visible = session.TheirView
	end

	if session.TheirView then
		local camera = workspace.CurrentCamera
		camera.CFrame = cameraCFrame

		-- Their vertical field of view spread over the letterbox's height rather than the whole screen
		local fov = from.Fov + (to.Fov - from.Fov) * alpha
		local stretch = camera.ViewportSize.Y / session.AreaSize.Y
		camera.FieldOfView = math.min(math.deg(2 * math.atan(math.tan(math.rad(fov) / 2) * stretch)), MAX_FOV)

		local pointer = self:_pointerAt(at)
		self:_renderScreen(pointer, at)
		self:_renderOverlay(from, pointer, at)
	end

	self:_renderPanel(from)
end

-- Writes the panel's read-out, timeline and feed highlight for the playhead.
function ReplayController:_renderPanel(from)
	local session = self._session
	local at = session.Time

	session.StateLabel.Text = ReplayFormat.StateName[from.State]
	session.StateDot.BackgroundColor3 = if from.State == ReplayFormat.State.Valid
		then STATE_VALID
		elseif from.State == ReplayFormat.State.None then STATE_NONE
		else STATE_REFUSED

	session.TimeLabel.Text = `{formatTime(at)} / {formatTime(session.Duration)}`
	session.FpsLabel.Text = `{from.Fps} fps`
	session.PingLabel.Text = `{from.Ping} ms`
	session.StepLabel.Text = session.State.Step or ""

	local fraction = if session.Duration > 0 then math.clamp(at / session.Duration, 0, 1) else 0
	session.ScrubFill.Size = UDim2.fromScale(fraction, 1)
	session.ScrubHandle.Position = UDim2.new(fraction, -1, 0, -3)

	-- The newest line at or before the playhead, repainted only when it changes
	local current = 0
	for index, entry in session.FeedEntries do
		if entry.T > at then
			break
		end
		current = index
	end

	if current ~= session.FeedCurrent then
		local previous = session.FeedLines[session.FeedCurrent]
		if previous then
			previous.BackgroundTransparency = 1
		end

		local line = session.FeedLines[current]
		if line then
			line.BackgroundTransparency = 0

			-- Kept in the middle of the list, so what just happened and what's next both show
			local feedHeight = session.Feed.AbsoluteSize.Y
			session.FeedList.CanvasPosition = Vector2.new(0, math.max(current * FEED_LINE_HEIGHT - feedHeight / 2, 0))
		end

		session.FeedCurrent = current
	end

	self:_refreshControls()
end

-- The viewer's own screen: bars around the recording, the panel under it and the feed beside it.
function ReplayController:_buildPanel()
	local session = self._session

	local screen = Instance.new("ScreenGui")
	screen.Name = "ReplayUI"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = PANEL_DISPLAY_ORDER
	-- Sibling, or the panel's ZIndex over the bars would lift it over its own buttons and labels too
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = PlayerGui
	self._cleaner:Add(screen)

	session.Bars = {}
	for index = 1, 4 do
		session.Bars[index] = makeFrame(screen, BAR_COLOR, 0)
	end

	local panel = makeFrame(screen, PANEL_BACKGROUND, 0.05, UDim.new(0, 10))
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
	panel.ZIndex = 2
	session.Panel = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = PANEL_STROKE
	panelStroke.Thickness = 1
	panelStroke.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 12)
	padding.PaddingBottom = UDim.new(0, 12)
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 14)
	padding.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = panel

	self:_buildHeader(panel)
	self:_buildTrack(panel)
	self:_buildControls(panel)
	self:_buildFeed(screen)
end

-- Who the recording is of, and the live read-out of what the game was telling them.
function ReplayController:_buildHeader(panel: Frame)
	local session = self._session
	local record = session.Record
	local row = makeRow(panel, 18, 1, 10)

	local who = makeLabel(row, 250, 1)
	who.TextColor3 = TEXT_PRIMARY
	who.Text = `{record.Username} ({record.UserId})`

	local meta = makeLabel(row, 190, 2)
	meta.Text = `{record.Platform or "Unknown"} · Variant {record.Variant}`

	local close = makeButton(row, "✕", 26, 3)
	close.TextSize = 14
	close.LayoutOrder = 99
	self._cleaner:Connect(close.MouseButton1Click, function()
		self:StopReplay()
	end)

	-- Right-aligned by filling the gap, so the close button sits in the corner whatever the name's length
	local spacer = Instance.new("Frame")
	spacer.BackgroundTransparency = 1
	spacer.Size = UDim2.new(1, -(250 + 190 + 26 + 30), 1, 0)
	spacer.LayoutOrder = 50
	spacer.Parent = row

	local status = makeRow(panel, 18, 2, 8)

	local dot = makeFrame(status, STATE_NONE, 0, UDim.new(1, 0))
	dot.Size = UDim2.fromOffset(8, 8)
	dot.LayoutOrder = 1
	session.StateDot = dot

	session.StateLabel = makeLabel(status, 130, 2)
	session.StateLabel.TextColor3 = TEXT_PRIMARY

	session.TimeLabel = makeLabel(status, 90, 3, true)
	session.FpsLabel = makeLabel(status, 60, 4, true)
	session.PingLabel = makeLabel(status, 70, 5, true)
	session.StepLabel = makeLabel(status, 150, 6)
end

-- The timeline: the run, shaded before the reported step, pipped with its moments, and draggable.
function ReplayController:_buildTrack(panel: Frame)
	local session = self._session

	local track = Instance.new("TextButton")
	track.Size = UDim2.new(1, 0, 0, TRACK_HEIGHT)
	track.LayoutOrder = 3
	track.BackgroundColor3 = TRACK_BACKGROUND
	track.BorderSizePixel = 0
	track.AutoButtonColor = false
	track.Text = ""
	track.Parent = panel

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = track

	-- The stretch before the reported step began, darkened so the step being investigated stands out
	local stepAt = nil
	for _, moment in session.Moments do
		if moment[2] == Moment.Step and moment[3] == GUIDE_STEP then
			stepAt = moment[1] / session.Rate
			break
		end
	end

	if stepAt and session.Duration > 0 and stepAt > 0 then
		local pre = makeFrame(track, TRACK_PRE_STEP, 0)
		pre.Size = UDim2.fromScale(math.clamp(stepAt / session.Duration, 0, 1), 1)
		pre.ZIndex = 2
	end

	local fill = makeFrame(track, TRACK_FILL, 0.35)
	fill.Size = UDim2.fromScale(0, 1)
	fill.ZIndex = 3
	session.ScrubFill = fill

	if session.Duration > 0 then
		for _, entry in session.FeedEntries do
			local pip = makeFrame(track, entry.Color, 0)
			pip.Size = UDim2.new(0, 2, 1, 0)
			pip.Position = UDim2.fromScale(math.clamp(entry.T / session.Duration, 0, 1), 0)
			pip.ZIndex = 4
		end
	end

	local handle = makeFrame(track, TRACK_HANDLE, 0)
	handle.Size = UDim2.new(0, 3, 1, 6)
	handle.Position = UDim2.new(0, 0, 0, -3)
	handle.ZIndex = 5
	session.ScrubHandle = handle

	-- Dragged rather than only clicked: finding the one moment that matters means sweeping, not guessing
	local function seekTo(x: number)
		local fraction = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		session.Time = fraction * session.Duration
		self:_render()
	end

	self._cleaner:Connect(track.InputBegan, function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		session.Scrubbing = true
		seekTo(input.Position.X)
	end)

	self._cleaner:Connect(UserInputService.InputChanged, function(input: InputObject)
		if not session.Scrubbing then
			return
		end

		if
			input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch
		then
			seekTo(input.Position.X)
		end
	end)

	self._cleaner:Connect(UserInputService.InputEnded, function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			session.Scrubbing = false
		end
	end)
end

-- Transport, speed and the camera toggle, plus the key hints for the same actions.
function ReplayController:_buildControls(panel: Frame)
	local session = self._session
	local row = makeRow(panel, 26, 4, 6)

	local toStart = makeButton(row, "|◀", 30, 1)
	local back = makeButton(row, "◀◀", 34, 2)
	local play = makeButton(row, "❚❚", 40, 3)
	local forward = makeButton(row, "▶▶", 34, 4)
	local toEnd = makeButton(row, "▶|", 30, 5)
	session.PlayButton = play

	self._cleaner:Connect(toStart.MouseButton1Click, function()
		session.Time = 0
		self:_render()
	end)
	self._cleaner:Connect(back.MouseButton1Click, function()
		self:_step(-1)
	end)
	self._cleaner:Connect(play.MouseButton1Click, function()
		self:_togglePlaying()
	end)
	self._cleaner:Connect(forward.MouseButton1Click, function()
		self:_step(1)
	end)
	self._cleaner:Connect(toEnd.MouseButton1Click, function()
		session.Time = session.Duration
		session.Playing = false
		self:_render()
	end)

	local gap = Instance.new("Frame")
	gap.BackgroundTransparency = 1
	gap.Size = UDim2.fromOffset(12, 1)
	gap.LayoutOrder = 6
	gap.Parent = row

	session.SpeedButtons = {}
	for index, speed in SPEEDS do
		local button = makeButton(row, if speed < 1 then `{speed}x` else `{math.floor(speed)}x`, 34, 6 + index)

		self._cleaner:Connect(button.MouseButton1Click, function()
			session.SpeedIndex = index
			self:_render()
		end)

		session.SpeedButtons[index] = button
	end

	local cameraGap = Instance.new("Frame")
	cameraGap.BackgroundTransparency = 1
	cameraGap.Size = UDim2.fromOffset(12, 1)
	cameraGap.LayoutOrder = 20
	cameraGap.Parent = row

	session.CameraButton = makeButton(row, "Their view", 92, 21)
	self._cleaner:Connect(session.CameraButton.MouseButton1Click, function()
		self:_toggleView()
	end)

	session.FeedButton = makeButton(row, "Moments", 76, 22)
	self._cleaner:Connect(session.FeedButton.MouseButton1Click, function()
		session.FeedShown = not session.FeedShown
		self:_render()
	end)

	local hint = makeLabel(panel, PANEL_WIDTH, 5)
	hint.Size = UDim2.new(1, 0, 0, 14)
	hint.TextSize = 11
	hint.Text = "space · ← → step 1s · [ ] speed · E camera · F moments · drag the bar to scrub"
end

-- The moment feed: one line per thing the player did or was shown, the current one lit, any clicked to seek.
function ReplayController:_buildFeed(screen: ScreenGui)
	local session = self._session

	local feed = makeFrame(screen, PANEL_BACKGROUND, 0.05, UDim.new(0, 10))
	feed.ZIndex = 2
	session.Feed = feed

	local stroke = Instance.new("UIStroke")
	stroke.Color = PANEL_STROKE
	stroke.Thickness = 1
	stroke.Parent = feed

	local title = makeLabel(feed, FEED_WIDTH, 0)
	title.Position = UDim2.fromOffset(12, 6)
	title.Size = UDim2.new(1, -24, 0, 18)
	title.TextColor3 = TEXT_PRIMARY
	title.Font = Enum.Font.GothamMedium
	title.Text = `Moments ({#session.FeedEntries})`
	title.ZIndex = 3

	local list = Instance.new("ScrollingFrame")
	list.Position = UDim2.fromOffset(6, 30)
	list.Size = UDim2.new(1, -12, 1, -36)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.ZIndex = 3
	list.Parent = feed
	session.FeedList = list

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	session.FeedLines = {}
	for index, entry in session.FeedEntries do
		local line = Instance.new("TextButton")
		line.Size = UDim2.new(1, -6, 0, FEED_LINE_HEIGHT)
		line.LayoutOrder = index
		line.BackgroundColor3 = CONTROL_BACKGROUND
		line.BackgroundTransparency = 1
		line.BorderSizePixel = 0
		line.AutoButtonColor = false
		line.Font = Enum.Font.Code
		line.TextSize = 12
		line.TextColor3 = entry.Color
		line.TextXAlignment = Enum.TextXAlignment.Left
		line.TextTruncate = Enum.TextTruncate.AtEnd
		line.Text = ` {formatTime(entry.T)}  {entry.Text}`
		line.ZIndex = 4
		line.Parent = list

		self._cleaner:Connect(line.MouseButton1Click, function()
			session.Time = math.min(entry.T, session.Duration)
			session.Playing = false
			self:_render()
		end)

		session.FeedLines[index] = line
	end
end

-- Moves the playhead by `delta` seconds, clamped, and repaints.
function ReplayController:_step(delta: number)
	local session = self._session
	session.Time = math.clamp(session.Time + delta, 0, session.Duration)
	self:_render()
end

-- Starts or stops playback, rewinding first if it is already parked at the end.
function ReplayController:_togglePlaying()
	local session = self._session
	if not session.Playing and session.Time >= session.Duration then
		session.Time = 0
	end

	session.Playing = not session.Playing
	self:_render()
end

-- Swaps between their view and the orbit, handing the orbit back a plain field of view.
function ReplayController:_toggleView()
	local session = self._session
	session.TheirView = not session.TheirView

	if not session.TheirView then
		workspace.CurrentCamera.FieldOfView = ORBIT_FOV
	end

	self:_render()
end

-- Repaints the controls to match the state the playhead is in. Cheap enough to run every frame.
function ReplayController:_refreshControls()
	local session = self._session
	local state = `{session.Playing}|{session.SpeedIndex}|{session.TheirView}|{session.FeedShown}`
	if state == session.ControlsState then
		return
	end
	session.ControlsState = state

	session.PlayButton.Text = if session.Playing then "❚❚" else "▶"

	for index, button in session.SpeedButtons do
		local active = index == session.SpeedIndex
		button:SetAttribute("Active", active)
		button.BackgroundColor3 = if active then CONTROL_ACTIVE else CONTROL_BACKGROUND
	end

	local theirs = session.TheirView
	session.CameraButton.Text = if theirs then "Their view" else "Orbit"
	session.CameraButton:SetAttribute("Active", theirs)
	session.CameraButton.BackgroundColor3 = if theirs then CONTROL_ACTIVE else CONTROL_BACKGROUND

	session.FeedButton:SetAttribute("Active", session.FeedShown)
	session.FeedButton.BackgroundColor3 = if session.FeedShown then CONTROL_ACTIVE else CONTROL_BACKGROUND
end

-- Clears the screen for the run: every other ScreenGui goes down, and the tutorial stops drawing its beams
-- and glows. Whoever is watching is usually mid-tutorial themselves, since that is what gives them a clean
-- base -- and their own banner and cues would otherwise sit on top of the recording. Restored on stop.
function ReplayController:_takeScreen()
	local hidden = {}

	for _, gui in PlayerGui:GetChildren() do
		if gui:IsA("ScreenGui") and gui.Enabled then
			gui.Enabled = false
			table.insert(hidden, gui)
		end
	end

	-- Its cues live in the world and redraw themselves every frame, so they're held down rather than disabled
	TutorialController:SetHidden(true)

	self._cleaner:Add(function()
		TutorialController:SetHidden(false)

		for _, gui in hidden do
			-- One taken down while the replay ran is left alone; whatever owns it will raise it again
			if gui.Parent then
				gui.Enabled = true
			end
		end
	end)
end

-- Takes the camera for the run, hides the viewer's own body from it, and remembers how to hand both back.
function ReplayController:_takeCamera()
	local camera = workspace.CurrentCamera
	local cameraType = camera.CameraType
	local fieldOfView = camera.FieldOfView

	-- UIController springs the field of view on a panel opening, and a spring still running would fight this one
	Spr.stop(camera, "FieldOfView")
	camera.CameraType = Enum.CameraType.Scriptable

	-- Held every frame: the camera scripts write their own fade over it while zoomed in
	self._cleaner:Connect(RunService.RenderStepped, function()
		local character = LocalPlayer.Character
		if not character then
			return
		end

		for _, descendant in character:GetDescendants() do
			if descendant:IsA("BasePart") or descendant:IsA("Decal") then
				descendant.LocalTransparencyModifier = 1
			end
		end
	end)

	self._cleaner:Add(function()
		camera.CameraType = cameraType
		camera.FieldOfView = fieldOfView
		camera.CameraSubject = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")

		local character = LocalPlayer.Character
		if character then
			for _, descendant in character:GetDescendants() do
				if descendant:IsA("BasePart") or descendant:IsA("Decal") then
					descendant.LocalTransparencyModifier = 0
				end
			end
		end
	end)
end

function ReplayController:_bindKeys()
	self._cleaner:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		local session = self._session
		if processed or not session then
			return
		end

		-- Through the same calls the buttons use, so a key and a click can't drift apart
		if input.KeyCode == Enum.KeyCode.Space then
			self:_togglePlaying()
		elseif input.KeyCode == Enum.KeyCode.Left then
			self:_step(-1)
		elseif input.KeyCode == Enum.KeyCode.Right then
			self:_step(1)
		elseif input.KeyCode == Enum.KeyCode.LeftBracket then
			session.SpeedIndex = math.max(1, session.SpeedIndex - 1)
			self:_render()
		elseif input.KeyCode == Enum.KeyCode.RightBracket then
			session.SpeedIndex = math.min(#SPEEDS, session.SpeedIndex + 1)
			self:_render()
		elseif input.KeyCode == Enum.KeyCode.E then
			self:_toggleView()
		elseif input.KeyCode == Enum.KeyCode.F then
			session.FeedShown = not session.FeedShown
			self:_render()
		end
	end)
end

-- Plays a loaded recording. The origin comes from the viewer's own base, so whoever runs this watches it rebuilt
-- on the ground in front of them. Answers false and a reason when there's nothing to play it against.
function ReplayController:PlayReplay(record): (boolean, string)
	self:StopReplay()

	local origin = BuildController:GetGroundOrigin()
	if not origin then
		return false, "your own base hasn't loaded, so there's no ground to rebuild the recording on"
	end

	if #record.Samples == 0 then
		return false, "that recording holds no motion samples"
	end

	local samples = table.create(#record.Samples)
	for index, flat in record.Samples do
		samples[index] = ReplayFormat.ToSample(flat)
	end

	-- Stored in arrival order; sorted by position with arrival breaking ties, so two changes to one thing at the
	-- same instant still land in the order they happened
	local moments = table.clone(record.Moments)
	local arrival = {}
	for index, moment in moments do
		arrival[moment] = index
	end
	table.sort(moments, function(a, b)
		if a[1] == b[1] then
			return arrival[a] < arrival[b]
		end
		return a[1] < b[1]
	end)

	self._session = {
		Record = record,
		Samples = samples,
		Moments = moments,
		Rate = record.SampleRate,
		Origin = origin,
		Duration = (#samples - 1) / record.SampleRate,
		Time = 0,
		Playing = true,
		SpeedIndex = DEFAULT_SPEED_INDEX,
		-- Starts in their view: the question a replay answers is what they were looking at, and the orbit is the
		-- second opinion rather than the first
		TheirView = true,
		FeedShown = true,
		Scrubbing = false,
		State = newState(),
		Layers = {},
		Mirrors = {},
		Ghosts = {},
		FeedCurrent = 0,
		-- The one-off moments, pulled out once so a frame reads a short list rather than every moment
		Toasts = {},
		Taps = {},
		Keys = {},
		Gaps = {},
	}

	local session = self._session
	for _, moment in moments do
		local at = math.max(moment[1], 0) / session.Rate
		local kind = moment[2]

		if kind == Moment.Toast then
			table.insert(session.Toasts, { T = at, Text = moment[3], Duration = moment[4] })
		elseif kind == Moment.Tap then
			table.insert(session.Taps, { T = at, X = moment[3], Y = moment[4] })
		elseif kind == Moment.Mark and moment[3] == ReplayFormat.Mark.Key then
			table.insert(session.Keys, { T = at, Name = moment[4] })
		elseif kind == Moment.Mark and moment[3] == ReplayFormat.Mark.Gap then
			table.insert(session.Gaps, { T = at, Length = tonumber(moment[4]) or 0 })
		end
	end

	session.FeedEntries = self:_buildFeedEntries()

	self:_takeScreen()
	self:_buildScene()
	self:_buildMirrors()
	self:_buildStandIns()
	self:_buildPanel()
	self:_takeCamera()
	self:_bindKeys()
	self:_layout()

	self._cleaner:Connect(RunService.RenderStepped, function(deltaTime: number)
		if session.Playing then
			session.Time += deltaTime * SPEEDS[session.SpeedIndex]

			-- Held at the end rather than looped, so the last thing they did stays on screen
			if session.Time >= session.Duration then
				session.Time = session.Duration
				session.Playing = false
			end
		end

		self:_render()

		if not session.TheirView then
			local camera = workspace.CurrentCamera
			local focus = session.AvatarRoot or session.Dummy
			local target = CFrame.lookAt(focus.Position + ORBIT_OFFSET, focus.Position)
			camera.CFrame = camera.CFrame:Lerp(target, 1 - math.exp(-ORBIT_FOLLOW_SPEED * deltaTime))
		end
	end)

	return true, `playing {#samples} samples and {#moments} moments over {string.format("%.0f", session.Duration)}s`
end

-- Tears the whole viewer down and hands the camera and the screen back. Safe to call when nothing is playing.
function ReplayController:StopReplay()
	self._cleaner:Clean()
	self._session = nil
end

function ReplayController:OnStart()
	self.PlayReplayEvent:OnClientEvent(function(record)
		-- The command that sent this can't see the answer, a server-to-client fire having no reply, so a
		-- refusal is warned here where whoever typed it is already looking
		local played, message = self:PlayReplay(record)

		if not played then
			warn(`[Replay] {message}`)
		end
	end)

	self.StopReplayEvent:OnClientEvent(function()
		self:StopReplay()
	end)
end

return ReplayController
