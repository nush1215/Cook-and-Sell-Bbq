-- Services
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local ReplayFormat = require(Shared.ReplayFormat)

-- Controllers
local BuildController = require(script.Parent.BuildController)
local InputController = require(script.Parent.InputController)
local InventoryController = require(script.Parent.InventoryController)
local TutorialController = require(script.Parent.TutorialController)
local NotificationController = require(script.Parent.NotificationController)

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

local Moment = ReplayFormat.Moment

-- Set by ReplayManager while it keeps this player's motion track. Its own attribute rather than the FTUE
-- trail's, so the replay can be turned off on its own and the reporting that already works is left alone
local ENABLED_ATTRIBUTE = "LogFTUEReplay"

-- Samples a second, matched to the format's stride so the viewer can seek by multiplying
local SAMPLE_INTERVAL = 1 / ReplayFormat.SAMPLE_RATE

-- Seconds a batch gathers for, so a run of samples is one remote rather than five
local FLUSH_INTERVAL = 1

-- Samples and moments one batch holds before the rest wait or drop; ReplayManager takes no more than this either
local MAX_BATCH = 16
local MAX_MOMENT_BATCH = 48

-- Pixels a shown surface has to move before its new spot is worth a moment; below it is layout jitter
local MOVE_THRESHOLD = 4

-- A frame this many seconds long lost time the track can't show -- a hitch, or the app sent to the background
local GAP_THRESHOLD = 0.5

-- What the recorder's frame shows up as in the MicroProfiler, so its cost can be read straight off a device
local PROFILER_LABEL = "ReplayRecorder"

-- ScreenGuis that are never recorded: billboards hung on the world, debug and admin tooling, and the pieces
-- Roblox or a package draws that the viewer has no copy of. Everything else in PlayerGui is watched
local UNRECORDED_GUIS = {
	ProximityPrompts = true,
	NpcBillboards = true,
	GrillBillboards = true,
	PlotSigns = true,
	RatingSigns = true,
	SauceDispenserSigns = true,
	UpgradeBoard = true,
	HiringBoard = true,
	SpotlightGui = true, -- recorded as Spot moments instead, the hole being the only part worth having
	ConfettiUI = true,
	CurrencyUI = true, -- only "+X" popups, each a fresh GUID-named frame that would rebuild the surface list
	TouchGui = true,
	ReplayUI = true,
	DebugUpgrades = true,
	DebugSessionStats = true,
	Cmdr = true,
	TopbarStandard = true,
	TopbarCentered = true,
	TopbarStandardClipped = true,
	TopbarCenteredClipped = true,
}
-- The server-made worker portraits, which are billboards too
local UNRECORDED_GUI_SUFFIX = "Portraits"

-- Surfaces watched below a gui's first level. The open inventory is a child of the always-on backpack frame
local EXTRA_SURFACES = {
	{ "BackpackGui", "Backpack", "Inventory" },
}

-- The keys whose presses are worth a line in the replay. An allowlist, so nothing typed can be read back out
local RECORDED_KEYS = {
	[Enum.KeyCode.E] = true,
	[Enum.KeyCode.R] = true,
	[Enum.KeyCode.Q] = true,
	[Enum.KeyCode.F] = true,
	[Enum.KeyCode.Tab] = true,
	[Enum.KeyCode.Backquote] = true,
	[Enum.KeyCode.Backspace] = true,
	[Enum.KeyCode.LeftShift] = true,
	[Enum.KeyCode.Space] = true,
	[Enum.KeyCode.Zero] = true,
	[Enum.KeyCode.One] = true,
	[Enum.KeyCode.Two] = true,
	[Enum.KeyCode.Three] = true,
	[Enum.KeyCode.Four] = true,
	[Enum.KeyCode.Five] = true,
	[Enum.KeyCode.Six] = true,
	[Enum.KeyCode.Seven] = true,
	[Enum.KeyCode.Eight] = true,
	[Enum.KeyCode.Nine] = true,
	[Enum.KeyCode.ButtonA] = true,
	[Enum.KeyCode.ButtonB] = true,
	[Enum.KeyCode.ButtonX] = true,
	[Enum.KeyCode.ButtonY] = true,
	[Enum.KeyCode.ButtonL1] = true,
	[Enum.KeyCode.ButtonR1] = true,
	[Enum.KeyCode.ButtonL2] = true,
	[Enum.KeyCode.ButtonR2] = true,
	[Enum.KeyCode.DPadUp] = true,
	[Enum.KeyCode.DPadDown] = true,
	[Enum.KeyCode.DPadLeft] = true,
	[Enum.KeyCode.DPadRight] = true,
	[Enum.KeyCode.ButtonStart] = true,
	[Enum.KeyCode.ButtonSelect] = true,
}

-- Names a tapped button's path keeps below its gui; a deeper one keeps just the last two, which say which button
local MAX_TAP_NAMES = 3

-- The client half of the replay: samples where the player is, where they're looking and what the build ghost
-- says, notes what their screen showed and what they pressed, then hands the run to the server once a second.
-- Nothing is recorded unless the server has asked for it, so with the attribute unset every frame costs nothing.
local ReplayRecorderController = {
	LogReplaySamplesEvent = Network.Event("LogReplaySamples"),

	_run = nil, -- the Trove holding the recording's every connection, only while the server is asking for one

	_pending = {}, -- packed sample arrays waiting on the next flush
	_pendingMoments = {}, -- moment arrays waiting on the next flush
	_sampleCount = 0, -- samples taken this run, which is the clock moments are stamped against
	_sinceSample = 0,
	_sinceFlush = 0,
	_fps = 0,

	-- The polls and the flush waiting their turn. One runs a frame, so a tick's reads never pile onto one frame
	_jobs = {},

	_watched = nil, -- { { Gui, Surfaces = { { Path, Object, Parent? } } } } polled each tick; nil when it needs rebuilding
	_watchedPaths = {}, -- [path] = true for every surface in _watched
	_watchCleaner = nil, -- the watched guis' child listeners, rebuilt with the list
	_sweepPending = false, -- set when the list changed, so vanished surfaces get their hidden moment

	_surfaces = {}, -- [path] = { Shown, X, Y, W, H } as last sent
	_states = {}, -- [key] = the signature of the last moment sent for that piece of state
	_slots = {}, -- [slot index] = true for each hotbar slot last sent as filled
	_touches = {}, -- the fingers down now, oldest first, as their live InputObjects
	_unfocused = false,
}

-- Queues one moment, stamped with where it falls on the sample track. Answers false when the batch is full, so
-- a caller tracking state can hold its change back and offer it again next tick rather than lose it.
function ReplayRecorderController:_addMoment(kind: number, ...: any): boolean
	if #self._pendingMoments >= MAX_MOMENT_BATCH then
		return false
	end

	-- In samples rather than seconds: a skipped sample then can't slide every later moment off the track
	local position = math.max(self._sampleCount - 1 + self._sinceSample / SAMPLE_INTERVAL, 0)
	table.insert(self._pendingMoments, { ReplayFormat.Round(position, 2), kind, ... })

	return true
end

-- Sends a moment only when the state behind `key` differs from the one last sent. Compared in place, so an
-- unchanged state -- nearly every tick -- allocates nothing.
function ReplayRecorderController:_setState(key: string, kind: number, ...: any)
	local last = self._states[key]
	local count = select("#", ...)

	if last and #last == count then
		local changed = false
		for index = 1, count do
			if last[index] ~= (select(index, ...)) then
				changed = true
				break
			end
		end

		if not changed then
			return
		end
	end

	if self:_addMoment(kind, ...) then
		self._states[key] = { ... }
	end
end

-- Records one surface's state, sending a Ui moment when it appears, goes or moves. `inset` turns gui space into
-- the viewport pixels every recorded position is in.
function ReplayRecorderController:_pollSurface(
	path: string,
	visible: boolean,
	object: GuiObject,
	inset: Vector2,
	viewport: Vector2
)
	local shown = visible
	local x, y, w, h = 0, 0, 0, 0

	-- Positions are only read for something showing, which is what keeps a tick to a hundred reads
	if visible then
		local position = object.AbsolutePosition
		local size = object.AbsoluteSize
		x, y = math.round(position.X + inset.X), math.round(position.Y + inset.Y)
		w, h = math.round(size.X), math.round(size.Y)

		-- Slid off the edge counts as hidden, which is how the HUD tucks itself away
		shown = x <= viewport.X and y <= viewport.Y and x + w >= 0 and y + h >= 0
	end

	local last = self._surfaces[path]

	if not last then
		-- Anything never shown needs no moment: the viewer starts every surface hidden
		if not shown then
			self._surfaces[path] = { Shown = false, X = 0, Y = 0, W = 0, H = 0 }
			return
		end
	elseif last.Shown == shown then
		if not shown or ReplayFormat.POINTER_FOLLOWERS[path] then
			return
		end

		local moved = math.max(math.abs(x - last.X), math.abs(y - last.Y), math.abs(w - last.W), math.abs(h - last.H))
		if moved <= MOVE_THRESHOLD then
			return
		end
	end

	if self:_addMoment(Moment.Ui, path, if shown then 1 else 0, x, y, w, h) then
		self._surfaces[path] = { Shown = shown, X = x, Y = y, W = w, H = h }
	end
end

-- Rebuilds the list of surfaces a tick polls and listens for the next change to it. Runs only when a watched gui
-- gains or loses a frame, so an ordinary tick never walks PlayerGui or builds a path string.
function ReplayRecorderController:_collectSurfaces()
	local cleaner = self._watchCleaner
	cleaner:Clean()
	table.clear(self._watchedPaths)

	local function markChanged()
		self._watched = nil
	end

	local watched = {}

	for _, gui in PlayerGui:GetChildren() do
		if
			not gui:IsA("ScreenGui")
			or UNRECORDED_GUIS[gui.Name]
			or string.sub(gui.Name, -#UNRECORDED_GUI_SUFFIX) == UNRECORDED_GUI_SUFFIX
		then
			continue
		end

		cleaner:Connect(gui.ChildAdded, markChanged)
		cleaner:Connect(gui.ChildRemoved, markChanged)

		local surfaces = {}

		for _, child in gui:GetChildren() do
			local path = `{gui.Name}/{child.Name}`

			-- Two siblings sharing a name would flicker as one path, so the first wins
			if child:IsA("GuiObject") and not self._watchedPaths[path] then
				self._watchedPaths[path] = true
				table.insert(surfaces, { Path = path, Object = child })
			end
		end

		for _, names in EXTRA_SURFACES do
			local parent = names[1] == gui.Name and gui:FindFirstChild(names[2])
			local object = parent and parent:FindFirstChild(names[3])

			if object then
				local path = table.concat(names, "/")
				self._watchedPaths[path] = true
				table.insert(surfaces, { Path = path, Object = object, Parent = parent })
			end
		end

		table.insert(watched, { Gui = gui, Surfaces = surfaces })
	end

	self._watched = watched
	self._sweepPending = true
end

-- Polls every watched surface, then, if the list just changed, sends anything that vanished as hidden.
function ReplayRecorderController:_pollSurfaces()
	if not self._watched then
		self:_collectSurfaces()
	end

	local inset = GuiService:GetGuiInset()
	local viewport = workspace.CurrentCamera.ViewportSize

	for _, entry in self._watched do
		-- Read once per gui: a disabled one hides every frame in it without a read each
		local enabled = entry.Gui.Enabled

		for _, surface in entry.Surfaces do
			local visible = enabled and (not surface.Parent or surface.Parent.Visible) and surface.Object.Visible
			self:_pollSurface(surface.Path, visible, surface.Object, inset, viewport)
		end
	end

	-- A frame destroyed, or a gui rebuilt on respawn, never reports hidden on its own
	if not self._sweepPending then
		return
	end
	self._sweepPending = false

	for path, last in self._surfaces do
		if self._watchedPaths[path] then
			continue
		end

		if not last.Shown or self:_addMoment(Moment.Ui, path, 0, 0, 0, 0, 0) then
			self._surfaces[path] = nil
		else
			-- The batch was full; tried again next tick
			self._sweepPending = true
		end
	end
end

-- The screen, the tutorial banner, the tool in hand and the spotlight, each sent when it changes.
function ReplayRecorderController:_pollScene()
	local viewport = workspace.CurrentCamera.ViewportSize
	local inset, bottomRight = GuiService:GetGuiInset()
	self:_setState(
		"Screen",
		Moment.Screen,
		math.round(viewport.X),
		math.round(viewport.Y),
		math.round(inset.X),
		math.round(inset.Y),
		math.round(bottomRight.X),
		math.round(bottomRight.Y)
	)

	local title, description = TutorialController:GetBannerText()
	if title then
		self:_setState("Text", Moment.Text, title, description)
	end

	local character = LocalPlayer.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	local slot = tool and InventoryController:GetSlotFrame(tool)
	local nameText = tool and tool:GetAttribute("NameText")
	self:_setState(
		"Held",
		Moment.Held,
		slot and tonumber(slot.Name) or 0,
		if type(nameText) == "string" then nameText elseif tool then tool.Name else "",
		tool and tool:GetAttribute("StructureId") or ""
	)

	local hole, arrow = TutorialController:GetSpotlightFocus()
	if hole then
		local position = hole.AbsolutePosition + inset
		self:_setState(
			"Spot",
			Moment.Spot,
			math.round(position.X),
			math.round(position.Y),
			math.round(hole.AbsoluteSize.X),
			math.round(hole.AbsoluteSize.Y),
			if arrow then 1 else 0
		)
	else
		self:_setState("Spot", Moment.Spot, 0, 0, 0, 0, 0)
	end
end

-- Sends each hotbar slot's tool, icon and spot as it changes, and empties the ones whose tool is gone. Run with
-- the flush rather than every sample, since a slot changes on a pickup, not on a frame.
function ReplayRecorderController:_pollHotbar()
	local inset = GuiService:GetGuiInset()
	local filled = {}

	for _, container in { LocalPlayer:FindFirstChildOfClass("Backpack"), LocalPlayer.Character } do
		for _, tool in container:GetChildren() do
			local slot = tool:IsA("Tool") and InventoryController:GetSlotFrame(tool)
			local index = slot and tonumber(slot.Name)
			if not index then
				continue
			end

			filled[index] = true

			local nameText = tool:GetAttribute("NameText")
			local position = slot.AbsolutePosition + inset
			self:_setState(
				`Slot{index}`,
				Moment.Slot,
				index,
				if type(nameText) == "string" then nameText else tool.Name,
				tool.TextureId,
				math.round(position.X),
				math.round(position.Y),
				math.round(slot.AbsoluteSize.X),
				math.round(slot.AbsoluteSize.Y)
			)
		end
	end

	for index in self._slots do
		if not filled[index] then
			self:_setState(`Slot{index}`, Moment.Slot, index, "", "", 0, 0, 0, 0)
		end
	end

	self._slots = filled
end

-- Takes one sample, or nothing at all before the base's floors have streamed in and given it an origin to
-- measure against. Everything is base-relative, so the recording plays back on whichever base the viewer uses.
function ReplayRecorderController:_sample()
	local origin = BuildController:GetGroundOrigin()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (origin and root) then
		return
	end

	local camera = workspace.CurrentCamera
	local placement = BuildController:GetPlacementSnapshot()

	-- Turned into the base's frame, which is also the frame the cells and the viewer's rebuild are in
	local localRoot = origin:ToObjectSpace(root.CFrame)
	local localCamera = origin:ToObjectSpace(camera.CFrame)
	local _, rootYaw = localRoot:ToOrientation()
	local cameraPitch, cameraYaw = localCamera:ToOrientation()

	local Flag = ReplayFormat.Flag
	local flags = 0
	if placement.GuideShown then
		flags += Flag.Guide
	end
	if placement.InvalidShown then
		flags += Flag.Invalid
	end
	if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
		flags += Flag.MouseButton1
	end
	if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
		flags += Flag.MouseButton2
	end
	if GuiService.MenuIsOpen then
		flags += Flag.MenuOpen
	end
	if self._unfocused then
		flags += Flag.Unfocused
	end

	-- A finger lifted while the app was in the background never reports its end, so it's swept here
	for index = #self._touches, 1, -1 do
		local state = self._touches[index].UserInputState
		if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			table.remove(self._touches, index)
		end
	end

	-- Fingers first; the mouse only on a mouse, since a phone reports its last tap there long after lifting
	local NO_POINTER = ReplayFormat.NO_POINTER
	local preferredInput = InputController:GetPreferredInput()
	local pointer, pointer2 = nil, nil
	local first, second = self._touches[1], self._touches[2]
	if first then
		local inset = GuiService:GetGuiInset()
		pointer = Vector2.new(first.Position.X, first.Position.Y) + inset
		pointer2 = second and Vector2.new(second.Position.X, second.Position.Y) + inset
	elseif preferredInput == Enum.PreferredInput.KeyboardAndMouse then
		pointer = UserInputService:GetMouseLocation()
	end

	-- Built in ReplayFormat.Field order, rounded here rather than at the store so the wire carries it once
	local round = ReplayFormat.Round
	local positionDecimals = ReplayFormat.POSITION_DECIMALS
	local angleDecimals = ReplayFormat.ANGLE_DECIMALS

	table.insert(self._pending, {
		round(localRoot.X, positionDecimals),
		round(localRoot.Y, positionDecimals),
		round(localRoot.Z, positionDecimals),
		round(math.deg(rootYaw), angleDecimals),
		round(localCamera.X, positionDecimals),
		round(localCamera.Y, positionDecimals),
		round(localCamera.Z, positionDecimals),
		round(math.deg(cameraYaw), angleDecimals),
		round(math.deg(cameraPitch), angleDecimals),
		placement.CellX or ReplayFormat.NO_CELL,
		placement.CellZ or ReplayFormat.NO_CELL,
		placement.Rotation,
		ReplayFormat.StateFromRefusal(placement.Placing, placement.Refusal),
		math.round(self._fps),
		flags,
		round(camera.FieldOfView, angleDecimals),
		if pointer then math.round(pointer.X) else NO_POINTER,
		if pointer then math.round(pointer.Y) else NO_POINTER,
		if pointer2 then math.round(pointer2.X) else NO_POINTER,
		if pointer2 then math.round(pointer2.Y) else NO_POINTER,
		preferredInput.Value,
		math.round(LocalPlayer:GetNetworkPing() * 1000),
	})

	self._sampleCount += 1
end

-- Queues a poll or the flush for a coming frame, once however often it's asked for before it runs.
function ReplayRecorderController:_queueJob(job: (any) -> ())
	if not table.find(self._jobs, job) then
		table.insert(self._jobs, job)
	end
end

-- Sends everything gathered since the last flush, checking the hotbar first.
function ReplayRecorderController:_flush()
	self:_pollHotbar()

	if #self._pending == 0 and #self._pendingMoments == 0 then
		return
	end

	local samples, moments = self._pending, self._pendingMoments
	self._pending = {}
	self._pendingMoments = {}
	self.LogReplaySamplesEvent:FireServer(samples, moments)
end

-- One frame of the recording loop, which only runs at all while the server is asking for a recording.
function ReplayRecorderController:_step(deltaTime: number)
	debug.profilebegin(PROFILER_LABEL)

	self._fps = if deltaTime > 0 then 1 / deltaTime else self._fps

	if deltaTime > GAP_THRESHOLD then
		self:_addMoment(Moment.Mark, ReplayFormat.Mark.Gap, string.format("%.1f", deltaTime))
	end

	local sampled = false
	self._sinceSample += deltaTime
	if self._sinceSample >= SAMPLE_INTERVAL then
		-- Carried over rather than zeroed. A device whose frames are longer than the interval would otherwise
		-- sample slower than it claims to, and the viewer reads the track at a fixed stride -- so the replay
		-- would play back faster than the session really ran, on exactly the devices worth watching.
		-- Clamped, or a loading hitch pays itself back as a burst over the frames after it
		self._sinceSample = math.min(self._sinceSample - SAMPLE_INTERVAL, SAMPLE_INTERVAL)

		-- Taken now rather than queued, since its timing is what the whole track's stride rests on
		if #self._pending < MAX_BATCH then
			self:_sample()
		end

		self:_queueJob(self._pollSurfaces)
		self:_queueJob(self._pollScene)
		sampled = true
	end

	self._sinceFlush += deltaTime
	if self._sinceFlush >= FLUSH_INTERVAL then
		self._sinceFlush = 0
		self:_queueJob(self._flush)
	end

	-- One job a frame, none on a sampling frame, so a tick's work is spread over the frames after it. A frame
	-- already a whole tick long has no spike left to spare, and holding the queue there would starve the polls
	local long = deltaTime >= SAMPLE_INTERVAL
	if long or not sampled then
		repeat
			local job = table.remove(self._jobs, 1)
			if job then
				job(self)
			end
		until not (job and long)
	end

	debug.profileend()
end

-- A press's moment: where it landed and the button under it, or the world when it hit none.
function ReplayRecorderController:_recordTap(input: InputObject, gameProcessed: boolean)
	local inset = GuiService:GetGuiInset()
	local hitPath = "world"

	-- Only a press the gui took can be on a button, so a click into the world skips the hit test entirely
	local hits = if gameProcessed then PlayerGui:GetGuiObjectsAtPosition(input.Position.X, input.Position.Y) else {}

	for _, object in hits do
		if not object:IsA("GuiButton") then
			continue
		end

		local segments = string.split(object:GetFullName(), ".")
		local guiIndex = table.find(segments, "PlayerGui") + 1
		local names = { table.unpack(segments, guiIndex + 1) }

		if #names > MAX_TAP_NAMES then
			names = { "…", names[#names - 1], names[#names] }
		end

		hitPath = `{segments[guiIndex]}/{table.concat(names, "/")}`
		break
	end

	self:_addMoment(
		Moment.Tap,
		math.round(input.Position.X + inset.X),
		math.round(input.Position.Y + inset.Y),
		hitPath
	)
end

-- A prompt's moment, placed base-relative so the viewer can hang it over the same spot on its own base.
function ReplayRecorderController:_recordPrompt(prompt: ProximityPrompt, event: number)
	local origin = BuildController:GetGroundOrigin()
	local parent = prompt.Parent

	-- A prompt hides as it's destroyed, by which point it may already have no parent
	local worldPosition = if not parent
		then nil
		elseif parent:IsA("Attachment") then parent.WorldPosition
		elseif parent:IsA("BasePart") then parent.Position
		elseif parent:IsA("Model") then parent:GetPivot().Position
		else nil

	-- Without a base to measure against there's nowhere to put it, and that's before the tutorial asks for anything
	if not (origin and worldPosition) then
		return
	end

	local position = origin:PointToObjectSpace(worldPosition)
	local round = ReplayFormat.Round
	local decimals = ReplayFormat.POSITION_DECIMALS

	self:_addMoment(
		Moment.Prompt,
		event,
		prompt.ActionText,
		prompt.ObjectText,
		round(position.X, decimals),
		round(position.Y, decimals),
		round(position.Z, decimals)
	)
end

-- Opens a recording run: fresh state, and every listener it needs, all held on one Trove.
function ReplayRecorderController:_startRecording()
	local run = Trove.new()
	self._run = run

	self._sampleCount = 0
	self._sinceSample = 0
	self._sinceFlush = 0
	self._unfocused = false
	self._watched = nil
	self._watchCleaner = run:Extend()

	-- Heartbeat rather than RenderStepped: nothing here draws, so none of it should hold up the frame being drawn
	run:Connect(RunService.Heartbeat, function(deltaTime: number)
		self:_step(deltaTime)
	end)

	-- A gui added or removed changes the surface list, which is rebuilt on the next poll rather than every tick
	local function markChanged()
		self._watched = nil
	end
	run:Connect(PlayerGui.ChildAdded, markChanged)
	run:Connect(PlayerGui.ChildRemoved, markChanged)

	run:Connect(UserInputService.InputBegan, function(input: InputObject, gameProcessed: boolean)
		if input.UserInputType == Enum.UserInputType.Touch then
			table.insert(self._touches, input)
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			self:_recordTap(input, gameProcessed)
		elseif RECORDED_KEYS[input.KeyCode] and not gameProcessed then
			self:_addMoment(Moment.Mark, ReplayFormat.Mark.Key, input.KeyCode.Name)
		end
	end)

	run:Connect(UserInputService.InputEnded, function(input: InputObject)
		local index = table.find(self._touches, input)
		if index then
			table.remove(self._touches, index)
		end
	end)

	run:Connect(UserInputService.WindowFocusReleased, function()
		self._unfocused = true
	end)
	run:Connect(UserInputService.WindowFocused, function()
		self._unfocused = false
	end)

	run:Connect(ProximityPromptService.PromptShown, function(prompt: ProximityPrompt)
		self:_recordPrompt(prompt, ReplayFormat.PromptEvent.Shown)
	end)
	run:Connect(ProximityPromptService.PromptHidden, function(prompt: ProximityPrompt)
		self:_recordPrompt(prompt, ReplayFormat.PromptEvent.Hidden)
	end)
	run:Connect(ProximityPromptService.PromptTriggered, function(prompt: ProximityPrompt)
		self:_recordPrompt(prompt, ReplayFormat.PromptEvent.Triggered)
	end)

	run:Connect(BuildController.OnPlaceAttempted, function(refusal: string?)
		self:_addMoment(Moment.Mark, ReplayFormat.Mark.Place, refusal or "")
	end)
	run:Connect(BuildController.OnGhostRotated, function()
		self:_addMoment(Moment.Mark, ReplayFormat.Mark.Rotate, "")
	end)

	run:Connect(TutorialController.OnStepLogged, function(key: string)
		self:_addMoment(Moment.Step, key)
	end)

	run:Connect(NotificationController.OnNotified, function(text: string, duration: number)
		self:_addMoment(Moment.Toast, text, duration)
	end)
end

-- Starts or stops recording to match the attribute. Held off entirely while nothing is being recorded, so a
-- player the server never asked about pays no per-frame cost at all.
function ReplayRecorderController:_refresh()
	local wanted = LocalPlayer:GetAttribute(ENABLED_ATTRIBUTE) == true

	if wanted == (self._run ~= nil) then
		return
	end

	if wanted then
		self:_startRecording()
		return
	end

	self._run:Destroy()
	self._run = nil
	self._watchCleaner = nil
	self._watched = nil

	-- Anything gathered before the server closed the track has nowhere to go
	table.clear(self._jobs)
	table.clear(self._watchedPaths)
	table.clear(self._pending)
	table.clear(self._pendingMoments)
	table.clear(self._surfaces)
	table.clear(self._states)
	table.clear(self._slots)
	table.clear(self._touches)
end

function ReplayRecorderController:OnStart()
	LocalPlayer:GetAttributeChangedSignal(ENABLED_ATTRIBUTE):Connect(function()
		self:_refresh()
	end)

	-- The attribute can already be set, the server having opened the track before this ran
	self:_refresh()
end

return ReplayRecorderController
