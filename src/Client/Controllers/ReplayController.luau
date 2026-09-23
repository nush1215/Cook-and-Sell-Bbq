-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

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

-- The structure a Build Griller recording is of. Its cells are what the ghost is rebuilt on
local GHOST_STRUCTURE_ID = "RustyGrill"

-- The stand-in for the recorded player. A real rig lives in ServerStorage and would have to replicate, and
-- nothing here may touch the live game -- so the dummy is built from parts and exists on this client alone
local DUMMY_HEIGHT = 5
local DUMMY_WIDTH = 2
local DUMMY_COLOR = Color3.fromRGB(80, 170, 255)
local DUMMY_TRANSPARENCY = 0.35

-- The line out of the dummy's head along the camera the recording was taken down
local AIM_LENGTH = 40
local AIM_THICKNESS = 0.15
local AIM_COLOR = Color3.fromRGB(255, 225, 90)

-- The rebuilt ghost wears the verdict, matching what the player was actually looking at
local GHOST_VALID_COLOR = Color3.fromRGB(0, 255, 0)
local GHOST_INVALID_COLOR = Color3.fromRGB(220, 70, 70)
local GHOST_TRANSPARENCY = 0.55

-- Where the orbit camera sits relative to the dummy, and how fast it catches up
local ORBIT_OFFSET = Vector3.new(0, 26, 34)
local ORBIT_FOLLOW_SPEED = 8

-- The tutorial's own guide, rebuilt where it stands so a replay shows what the player was being pointed at.
-- Cloned rather than borrowed: the viewer's own tutorial may have the real one out at the same time
local GUIDES_FOLDER_NAME = "TutorialGuides"
local GUIDE_NAME = "Grill"
local GUIDE_MARKER_COLOR = Color3.fromRGB(255, 200, 40)
local GUIDE_MARKER_TRANSPARENCY = 0.6

-- The walked path. Segments are only laid where the player actually moved, so standing still costs nothing
local PATH_THICKNESS = 0.2
local PATH_COLOR = Color3.fromRGB(120, 200, 255)
local PATH_TRANSPARENCY = 0.35
local PATH_MIN_STEP = 1
local PATH_MAX_SEGMENTS = 400

local PANEL_WIDTH = 600
local PANEL_HEIGHT = 160
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

-- The timeline, and the shade over the stretch before the reported step began
local TRACK_BACKGROUND = Color3.fromRGB(44, 48, 59)
local TRACK_PRE_STEP = Color3.fromRGB(32, 35, 43)
local TRACK_FILL = Color3.fromRGB(70, 130, 215)
local TRACK_HANDLE = Color3.fromRGB(255, 255, 255)

-- Event pips on the timeline. A refused click is the one worth picking out of the rest
local PIP_CLICK = Color3.fromRGB(235, 110, 110)
local PIP_OTHER = Color3.fromRGB(150, 158, 175)

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

-- Minutes and seconds, since a drop runs to a few minutes and raw seconds stop reading at that length.
local function formatTime(seconds: number): string
	return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
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

-- A drop report's timeline, played back on the base the viewer is standing on. Everything it builds is local to
-- this client -- no rig, no replication, nothing another player can see -- so running one can't disturb the game.
local ReplayController = {
	PlayReplayEvent = Network.Event("PlayReplay"),
	StopReplayEvent = Network.Event("StopReplay"),

	_cleaner = Trove.new(),
	_playing = false,
	_time = 0,
	_speedIndex = DEFAULT_SPEED_INDEX,
	-- Starts in their view: the question a replay answers is what they were looking at, and the orbit is the
	-- second opinion rather than the first
	_throughTheirEyes = true,

	_record = nil, -- the loaded recording, nil when nothing is playing
	_structure = nil, -- the Structures entry the ghost is rebuilt from, resolved once at load
	_samples = nil, -- its flat samples turned into ReplayFormat.Sample, once, at load
	_origin = nil, -- the base origin every sample is measured against
	_duration = 0,

	_dummy = nil,
	_aim = nil,
	_ghost = nil,
	_ghostHighlight = nil,
	_scrubFill = nil,
	_scrubHandle = nil,
	_scrubbing = false,
	_screen = nil,

	-- The panel's live pieces, repainted each frame from the playhead
	_stateDot = nil,
	_stateLabel = nil,
	_timeLabel = nil,
	_fpsLabel = nil,
	_uiLabel = nil,
	_playButton = nil,
	_speedButtons = nil,
	_cameraButton = nil,
	-- What the controls were last painted for. SetAttribute is not a plain property write, and repainting six
	-- buttons every frame for a state that changes on a keypress is work for nothing
	_controlsState = nil,
	_previousCameraType = nil,
}

-- The short way round between two headings. Orientations come back in -180..180, so a track crossing the
-- wrap would otherwise spin the dummy a whole turn the wrong way between two samples.
local function lerpAngle(from: number, to: number, alpha: number): number
	return from + ((to - from + 180) % 360 - 180) * alpha
end

-- An inert marker part. Everything the viewer draws is anchored, uncollidable and unqueryable, so none of it
-- can be walked into, clicked or raycast by anything else on this client.
-- Neon is kept for the two small things that have to be findable on screen; the path, the pads and the guide
-- cover real ground, and glowing they wash the base out rather than reading over it
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

-- The dummy, its aim line and the rebuilt ghost, all parented to the camera so nothing lands in the datamodel
-- another player could see. Returns nothing; the parts are held on the controller.
function ReplayController:_buildScene()
	local holder = Instance.new("Folder")
	holder.Name = "ReplayScene"
	holder.Parent = workspace.CurrentCamera
	self._cleaner:Add(holder)

	self._dummy = makeMarker(
		"ReplayDummy",
		Vector3.new(DUMMY_WIDTH, DUMMY_HEIGHT, DUMMY_WIDTH),
		DUMMY_COLOR,
		DUMMY_TRANSPARENCY,
		holder,
		true
	)
	self._aim =
		makeMarker("ReplayAim", Vector3.new(AIM_THICKNESS, AIM_THICKNESS, AIM_LENGTH), AIM_COLOR, 0, holder, true)

	self:_buildGuideMarker(holder)
	self:_buildPath(holder)

	-- The real model, stripped the way BuildController strips its own ghost, so the footprint is honest
	local ghost = self._structure.Model:Clone()
	ghost.Name = "ReplayGhost"

	for _, descendant in ghost:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Transparency = GHOST_TRANSPARENCY
		elseif descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		end
	end

	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = ghost
	highlight.Parent = ghost

	ghost.Parent = holder
	self._ghost = ghost
	self._ghostHighlight = highlight
end

-- The tutorial's guide, cloned where it is authored, so a replay shows the spot the player was being sent to.
-- Nothing is drawn on a base whose guide was never authored.
function ReplayController:_buildGuideMarker(holder: Instance)
	local base = TutorialController:GetBaseIfPresent()
	local guides = ReplicatedStorage:FindFirstChild(GUIDES_FOLDER_NAME)
	local baseGuides = guides and base and guides:FindFirstChild(base.Name)
	local guide = baseGuides and baseGuides:FindFirstChild(GUIDE_NAME)
	local hitbox = guide and guide:FindFirstChild("Hitbox")

	if not hitbox then
		return
	end

	local marker = makeMarker("ReplayGuide", hitbox.Size, GUIDE_MARKER_COLOR, GUIDE_MARKER_TRANSPARENCY, holder)
	marker.CFrame = hitbox.CFrame
end

-- The walked path as one segment per stretch the player actually covered. Standing still adds nothing, so a
-- session spent in one spot draws a dot rather than four hundred parts stacked on each other.
function ReplayController:_buildPath(holder: Instance)
	local previous = nil
	local drawn = 0

	for _, sample in self._samples do
		local point = self._origin * sample.Position

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

-- The two samples either side of the playhead and how far between them it sits.
function ReplayController:_sampleAt(at: number)
	local rate = self._record.SampleRate
	local exact = math.clamp(at * rate, 0, #self._samples - 1)
	local index = math.floor(exact)

	return self._samples[index + 1], self._samples[math.min(index + 2, #self._samples)], exact - index
end

-- Moves the dummy, the aim line and the ghost to where the playhead is, and writes the read-out.
function ReplayController:_render()
	local from, to, alpha = self:_sampleAt(self._time)
	local origin = self._origin

	local position = from.Position:Lerp(to.Position, alpha)
	local yaw = lerpAngle(from.Yaw, to.Yaw, alpha)
	self._dummy.CFrame = origin
		* CFrame.new(position + Vector3.new(0, DUMMY_HEIGHT / 2, 0))
		* CFrame.Angles(0, math.rad(yaw), 0)

	-- Drawn from the recorded camera rather than the dummy's head: the two can be far apart, and where the
	-- camera pointed is the thing worth seeing
	-- Interpolated like the body: samples land five a second, and a camera that snapped between them would
	-- be unwatchable through their eyes
	local cameraCFrame = origin
		* CFrame.new(from.CameraPosition:Lerp(to.CameraPosition, alpha))
		* CFrame.Angles(0, math.rad(lerpAngle(from.CameraYaw, to.CameraYaw, alpha)), 0)
		* CFrame.Angles(math.rad(from.CameraPitch + (to.CameraPitch - from.CameraPitch) * alpha), 0, 0)

	self._aim.CFrame = cameraCFrame * CFrame.new(0, 0, -AIM_LENGTH / 2)

	local valid = from.State == ReplayFormat.State.Valid
	self._ghostHighlight.OutlineColor = if valid then GHOST_VALID_COLOR else GHOST_INVALID_COLOR

	-- No cell means nothing was aimed that frame, so the ghost is taken off screen rather than left lying
	if from.CellX and from.CellZ then
		local footprintX, footprintZ = Structures.GetFootprint(self._structure, from.Rotation)
		local surface =
			GridUtil.CellToSurfaceCFrame(origin, from.CellX, from.CellZ, footprintX, footprintZ, Structures.CELL_SIZE)

		self._ghost:PivotTo(Structures.GetPlacementPivot(self._ghost, surface, from.Rotation))
		self._ghostHighlight.Enabled = true
	else
		self._ghost:PivotTo(CFrame.new(0, -500, 0))
		self._ghostHighlight.Enabled = false
	end

	if self._throughTheirEyes then
		workspace.CurrentCamera.CFrame = cameraCFrame
	end

	local guideShown = bit32.band(from.UiFlags, ReplayFormat.UiFlag.Guide) ~= 0

	self._stateLabel.Text = ReplayFormat.StateName[from.State]
	self._stateDot.BackgroundColor3 = if from.State == ReplayFormat.State.Valid
		then STATE_VALID
		elseif from.State == ReplayFormat.State.None then STATE_NONE
		else STATE_REFUSED

	self._timeLabel.Text = `{formatTime(self._time)} / {formatTime(self._duration)}`
	self._fpsLabel.Text = `{from.Fps} fps`

	-- The one flag worth calling out: a build hint that never resolved means they were never told what to press
	self._uiLabel.Text = if guideShown then "guide shown" else "NO GUIDE"
	self._uiLabel.TextColor3 = if guideShown then TEXT_MUTED else STATE_REFUSED

	local fraction = if self._duration > 0 then math.clamp(self._time / self._duration, 0, 1) else 0
	self._scrubFill.Size = UDim2.fromScale(fraction, 1)
	self._scrubHandle.Position = UDim2.new(fraction, -1, 0, -3)

	self:_refreshControls()
end

-- The viewer's panel: who it is, a timeline that can be dragged, transport, speed and the camera toggle.
function ReplayController:_buildPanel()
	local screen = Instance.new("ScreenGui")
	screen.Name = "ReplayUI"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 10
	screen.Parent = PlayerGui
	self._cleaner:Add(screen)
	self._screen = screen

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
	panel.Position = UDim2.new(0.5, -PANEL_WIDTH / 2, 1, -PANEL_HEIGHT - 24)
	panel.BackgroundColor3 = PANEL_BACKGROUND
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = screen

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel

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
end

-- Who the recording is of, and the live read-out of what the game was telling them.
function ReplayController:_buildHeader(panel: Frame)
	local row = makeRow(panel, 18, 1, 10)

	local who = makeLabel(row, 250, 1)
	who.TextColor3 = TEXT_PRIMARY
	who.Text = `{self._record.Username} ({self._record.UserId})`

	local meta = makeLabel(row, 190, 2)
	meta.Text = `{self._record.Platform or "Unknown"} · Variant {self._record.Variant}`

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

	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(8, 8)
	dot.LayoutOrder = 1
	dot.BackgroundColor3 = STATE_NONE
	dot.BorderSizePixel = 0
	dot.Parent = status

	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot

	self._stateDot = dot
	self._stateLabel = makeLabel(status, 150, 2)
	self._stateLabel.TextColor3 = TEXT_PRIMARY

	self._timeLabel = makeLabel(status, 90, 3, true)
	self._fpsLabel = makeLabel(status, 70, 4, true)
	self._uiLabel = makeLabel(status, 90, 5)
end

-- The timeline: the run, shaded before the reported step, pipped with the report's own events, and draggable.
function ReplayController:_buildTrack(panel: Frame)
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

	-- The stretch before Build Griller began, darkened so the step being investigated stands out from the run up to it
	local stepAt = self._record.StepEnteredAt
	if stepAt and self._duration > 0 and stepAt > 0 then
		local pre = Instance.new("Frame")
		pre.Size = UDim2.fromScale(math.clamp(stepAt / self._duration, 0, 1), 1)
		pre.BackgroundColor3 = TRACK_PRE_STEP
		pre.BorderSizePixel = 0
		pre.ZIndex = 2
		pre.Parent = track
	end

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = TRACK_FILL
	fill.BackgroundTransparency = 0.35
	fill.BorderSizePixel = 0
	fill.ZIndex = 3
	fill.Parent = track
	self._scrubFill = fill

	for _, entry in self._record.Events or {} do
		if self._duration <= 0 then
			break
		end

		local pip = Instance.new("Frame")
		pip.Size = UDim2.new(0, 2, 1, 0)
		pip.Position = UDim2.fromScale(math.clamp(entry.T / self._duration, 0, 1), 0)
		pip.BackgroundColor3 = if entry.Kind == "click" then PIP_CLICK else PIP_OTHER
		pip.BorderSizePixel = 0
		pip.ZIndex = 4
		pip.Parent = track
	end

	local handle = Instance.new("Frame")
	handle.Size = UDim2.new(0, 3, 1, 6)
	handle.Position = UDim2.new(0, 0, 0, -3)
	handle.BackgroundColor3 = TRACK_HANDLE
	handle.BorderSizePixel = 0
	handle.ZIndex = 5
	handle.Parent = track
	self._scrubHandle = handle

	-- Dragged rather than only clicked: finding the one moment that matters means sweeping, not guessing
	local function seekTo(x: number)
		local fraction = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		self._time = fraction * self._duration
		self:_render()
	end

	self._cleaner:Connect(track.InputBegan, function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		self._scrubbing = true
		seekTo(input.Position.X)
	end)

	self._cleaner:Connect(UserInputService.InputChanged, function(input: InputObject)
		if not self._scrubbing then
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
			self._scrubbing = false
		end
	end)
end

-- Transport, speed and the camera toggle, plus the key hints for the same actions.
function ReplayController:_buildControls(panel: Frame)
	local row = makeRow(panel, 26, 4, 6)

	local toStart = makeButton(row, "|◀", 30, 1)
	local back = makeButton(row, "◀◀", 34, 2)
	local play = makeButton(row, "❚❚", 40, 3)
	local forward = makeButton(row, "▶▶", 34, 4)
	local toEnd = makeButton(row, "▶|", 30, 5)
	self._playButton = play

	self._cleaner:Connect(toStart.MouseButton1Click, function()
		self._time = 0
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
		self._time = self._duration
		self._playing = false
		self:_render()
	end)

	local gap = Instance.new("Frame")
	gap.BackgroundTransparency = 1
	gap.Size = UDim2.fromOffset(12, 1)
	gap.LayoutOrder = 6
	gap.Parent = row

	self._speedButtons = {}
	for index, speed in SPEEDS do
		local button = makeButton(row, if speed < 1 then `{speed}x` else `{math.floor(speed)}x`, 34, 6 + index)

		self._cleaner:Connect(button.MouseButton1Click, function()
			self._speedIndex = index
			self:_render()
		end)

		self._speedButtons[index] = button
	end

	local cameraGap = Instance.new("Frame")
	cameraGap.BackgroundTransparency = 1
	cameraGap.Size = UDim2.fromOffset(12, 1)
	cameraGap.LayoutOrder = 20
	cameraGap.Parent = row

	self._cameraButton = makeButton(row, "Their view", 92, 21)
	self._cleaner:Connect(self._cameraButton.MouseButton1Click, function()
		self._throughTheirEyes = not self._throughTheirEyes
		self:_render()
	end)

	local hint = makeLabel(panel, PANEL_WIDTH, 5)
	hint.Size = UDim2.new(1, 0, 0, 14)
	hint.TextSize = 11
	hint.Text = "space · ← → step 1s · [ ] speed · E camera · drag the bar to scrub"
end

-- Moves the playhead by `delta` seconds, clamped, and repaints.
function ReplayController:_step(delta: number)
	self._time = math.clamp(self._time + delta, 0, self._duration)
	self:_render()
end

-- Starts or stops playback, rewinding first if it is already parked at the end.
function ReplayController:_togglePlaying()
	if not self._playing and self._time >= self._duration then
		self._time = 0
	end

	self._playing = not self._playing
	self:_render()
end

-- Repaints the controls to match the state the playhead is in. Cheap enough to run every frame.
function ReplayController:_refreshControls()
	local state = `{self._playing}|{self._speedIndex}|{self._throughTheirEyes}`
	if state == self._controlsState then
		return
	end
	self._controlsState = state

	self._playButton.Text = if self._playing then "❚❚" else "▶"

	for index, button in self._speedButtons do
		local active = index == self._speedIndex
		button:SetAttribute("Active", active)
		button.BackgroundColor3 = if active then CONTROL_ACTIVE else CONTROL_BACKGROUND
	end

	local theirs = self._throughTheirEyes
	self._cameraButton.Text = if theirs then "Their view" else "Orbit"
	self._cameraButton:SetAttribute("Active", theirs)
	self._cameraButton.BackgroundColor3 = if theirs then CONTROL_ACTIVE else CONTROL_BACKGROUND
end

-- Clears the screen for the run: every other ScreenGui goes down, and the tutorial stops drawing its beams
-- and glows. Whoever is watching is usually mid-tutorial themselves, since that is what gives them a clean
-- base -- and their own banner and cues would otherwise sit on top of the recording. Restored on stop.
function ReplayController:_takeScreen(own: ScreenGui)
	local hidden = {}

	for _, gui in PlayerGui:GetChildren() do
		if gui ~= own and gui:IsA("ScreenGui") and gui.Enabled then
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

-- Takes the camera for the run and remembers how to hand it back.
function ReplayController:_takeCamera()
	local camera = workspace.CurrentCamera
	self._previousCameraType = camera.CameraType
	camera.CameraType = Enum.CameraType.Scriptable

	self._cleaner:Add(function()
		camera.CameraType = self._previousCameraType or Enum.CameraType.Custom
		camera.CameraSubject = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	end)
end

function ReplayController:_bindKeys()
	self._cleaner:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed or not self._record then
			return
		end

		-- Through the same calls the buttons use, so a key and a click can't drift apart
		if input.KeyCode == Enum.KeyCode.Space then
			self:_togglePlaying()
			return
		elseif input.KeyCode == Enum.KeyCode.Left then
			self:_step(-1)
			return
		elseif input.KeyCode == Enum.KeyCode.Right then
			self:_step(1)
			return
		elseif input.KeyCode == Enum.KeyCode.LeftBracket then
			self._speedIndex = math.max(1, self._speedIndex - 1)
		elseif input.KeyCode == Enum.KeyCode.RightBracket then
			self._speedIndex = math.min(#SPEEDS, self._speedIndex + 1)
		elseif input.KeyCode == Enum.KeyCode.E then
			self._throughTheirEyes = not self._throughTheirEyes
		else
			return
		end

		self:_render()
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

	local structure = Structures.GetStructureFromId(GHOST_STRUCTURE_ID)
	if not structure then
		return false, `this build has no {GHOST_STRUCTURE_ID} to rebuild the ghost from`
	end

	local samples = table.create(#record.Samples)
	for index, flat in record.Samples do
		samples[index] = ReplayFormat.ToSample(flat)
	end

	self._record = record
	self._samples = samples
	self._structure = structure
	self._origin = origin
	self._duration = (#samples - 1) / record.SampleRate
	self._time = 0
	self._playing = true
	self._speedIndex = DEFAULT_SPEED_INDEX
	self._throughTheirEyes = true

	self:_buildScene()
	self:_buildPanel()
	self:_takeScreen(self._screen)
	self:_takeCamera()
	self:_bindKeys()

	self._cleaner:Connect(RunService.RenderStepped, function(deltaTime: number)
		if self._playing then
			self._time += deltaTime * SPEEDS[self._speedIndex]

			-- Held at the end rather than looped, so the last thing they did stays on screen
			if self._time >= self._duration then
				self._time = self._duration
				self._playing = false
			end
		end

		self:_render()

		if not self._throughTheirEyes then
			local camera = workspace.CurrentCamera
			local target = CFrame.lookAt(self._dummy.Position + ORBIT_OFFSET, self._dummy.Position)
			camera.CFrame = camera.CFrame:Lerp(target, 1 - math.exp(-ORBIT_FOLLOW_SPEED * deltaTime))
		end
	end)

	return true, `playing {#samples} samples over {string.format("%.0f", self._duration)}s`
end

-- Tears the whole viewer down and hands the camera back. Safe to call when nothing is playing.
function ReplayController:StopReplay()
	self._cleaner:Clean()

	self._record = nil
	self._samples = nil
	self._structure = nil
	self._origin = nil
	self._playing = false
	self._time = 0
	self._dummy = nil
	self._aim = nil
	self._ghost = nil
	self._ghostHighlight = nil
	self._scrubFill = nil
	self._scrubHandle = nil
	self._scrubbing = false
	self._screen = nil
	self._stateDot = nil
	self._stateLabel = nil
	self._timeLabel = nil
	self._fpsLabel = nil
	self._uiLabel = nil
	self._playButton = nil
	self._speedButtons = nil
	self._cameraButton = nil
	self._controlsState = nil
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
