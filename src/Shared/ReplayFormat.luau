-- The FTUE replay's recording format: one shared definition of a sample and a moment, so the recorder, the store
-- and the viewer all read the same shape. Both are flat arrays rather than dictionaries -- they cross a remote and
-- a DataStore, both of which cost per key, and the orders below are the only thing either side needs to agree on.
-- World positions are base-relative, so a recording plays back on whichever base the viewer uses; screen
-- positions are the recording device's own viewport pixels.

local ReplayFormat = {}

-- Bumped whenever a field order below moves; a record written under another version is refused rather than misread
ReplayFormat.VERSION = 2

ReplayFormat.SAMPLE_RATE = 5

-- Field order within one sample. The recorder builds arrays in exactly this order and the viewer reads them back
ReplayFormat.Field = {
	X = 1,
	Y = 2,
	Z = 3,
	Yaw = 4,
	CameraX = 5,
	CameraY = 6,
	CameraZ = 7,
	CameraYaw = 8,
	CameraPitch = 9,
	CellX = 10,
	CellZ = 11,
	Rotation = 12,
	State = 13,
	Fps = 14,
	Flags = 15,
	Fov = 16,
	PointerX = 17,
	PointerY = 18,
	Pointer2X = 19,
	Pointer2Y = 20,
	Input = 21,
	Ping = 22,
}

ReplayFormat.SAMPLE_LENGTH = 22

-- Studs and degrees are rounded before they go on the wire; finer than this is below what a replay can show,
-- and a full-precision float costs three times the characters once a DataStore turns it into JSON
ReplayFormat.POSITION_DECIMALS = 2
ReplayFormat.ANGLE_DECIMALS = 1

-- What a cell field holds when nothing is aimed; no real cell reaches it
ReplayFormat.NO_CELL = -32768

-- What a pointer field holds with no mouse or finger on the screen
ReplayFormat.NO_POINTER = -1

-- Well past any real base or screen, and what keeps a forged sample from reaching a DataStore or the viewer's renderer
local MAX_MAGNITUDE = 100000

-- Ghost verdicts. These mirror BuildController's REFUSAL_* constants -- a reworded one lands on Other rather
-- than breaking the decode, so an old recording stays readable either way.
ReplayFormat.State = {
	None = 0, -- no structure tool out, so no ghost at all
	Valid = 1,
	NoSpot = 2,
	NoGround = 3,
	OffGround = 4,
	Occupied = 5,
	Self = 6,
	Player = 7,
	Locked = 8,
	Other = 9,
}

-- How each state reads in the viewer's read-out, indexed by the code above
ReplayFormat.StateName = {
	[0] = "no ghost",
	[1] = "valid",
	[2] = "NoSpot",
	[3] = "NoGround",
	[4] = "OffGround",
	[5] = "Occupied",
	[6] = "Self",
	[7] = "Player",
	[8] = "Locked",
	[9] = "Other",
}

-- BuildController's refusal copy, verbatim. Kept here rather than imported, so the build path carries no
-- dependency on the replay; an unlisted string is simply Other.
local STATE_FROM_REFUSAL = {
	["Aim at ground you own"] = ReplayFormat.State.NoSpot,
	["Your stall is still loading"] = ReplayFormat.State.NoGround,
	["It won't fit on ground you own"] = ReplayFormat.State.OffGround,
	["Something's already built there"] = ReplayFormat.State.Occupied,
	["Someone's standing there"] = ReplayFormat.State.Player,
	["You can't place that right now"] = ReplayFormat.State.Locked,
	["Place your Griller first"] = ReplayFormat.State.Locked, -- the tutorial's own category lock (Sequence 1)
}

-- Bits of a sample's Flags field
ReplayFormat.Flag = {
	Guide = 1, -- the desktop build guide was up
	Invalid = 2, -- the "can't build here" badge was up
	MouseButton1 = 4,
	MouseButton2 = 8, -- held while dragging the camera on desktop
	MenuOpen = 16, -- the Roblox Esc menu was open
	Unfocused = 32, -- the game window was in the background
}

-- Moment kinds. A moment is `{ position, kind, ...args }`, position being in samples (see ReplayRecorderController)
ReplayFormat.Moment = {
	Screen = 1, -- w, h, insetLeft, insetTop, insetRight, insetBottom
	Ui = 2, -- path, shown, x, y, w, h
	Text = 3, -- title, description: the tutorial banner
	Held = 4, -- slot, toolName, structureId
	Slot = 5, -- index, name, icon, x, y, w, h: one hotbar slot, name "" once it empties
	Spot = 6, -- x, y, w, h, arrow: the tutorial's spotlight hole, w 0 while it's down
	Prompt = 7, -- event, action, object, x, y, z
	Step = 8, -- tutorial step key
	Toast = 9, -- text, duration
	Tap = 10, -- x, y, hitPath
	Mark = 11, -- mark, detail
}

-- Argument types after position and kind: n a number, p a short string, t a line of player-facing text
local MOMENT_SHAPES = {
	[ReplayFormat.Moment.Screen] = "nnnnnn",
	[ReplayFormat.Moment.Ui] = "pnnnnn",
	[ReplayFormat.Moment.Text] = "tt",
	[ReplayFormat.Moment.Held] = "npp",
	[ReplayFormat.Moment.Slot] = "nppnnnn",
	[ReplayFormat.Moment.Spot] = "nnnnn",
	[ReplayFormat.Moment.Prompt] = "nppnnn",
	[ReplayFormat.Moment.Step] = "p",
	[ReplayFormat.Moment.Toast] = "tn",
	[ReplayFormat.Moment.Tap] = "nnp",
	[ReplayFormat.Moment.Mark] = "np",
}

-- Kinds that set state rather than mark an instant, so a trimmed track keeps the latest of each as its opening state
local STATEFUL_KINDS = {
	[ReplayFormat.Moment.Screen] = true,
	[ReplayFormat.Moment.Ui] = true,
	[ReplayFormat.Moment.Text] = true,
	[ReplayFormat.Moment.Held] = true,
	[ReplayFormat.Moment.Slot] = true,
	[ReplayFormat.Moment.Spot] = true,
	[ReplayFormat.Moment.Prompt] = true,
	[ReplayFormat.Moment.Step] = true,
}

ReplayFormat.PromptEvent = {
	Shown = 1,
	Hidden = 2,
	Triggered = 3,
}

-- What a Mark moment records
ReplayFormat.Mark = {
	Place = 1, -- a build press; detail is the refusal, or "" when the request went out
	Rotate = 2,
	Key = 3, -- detail is the KeyCode name
	Gap = 4, -- a frame long enough to lose time over; detail is its length in seconds
}

-- Frames that trail the pointer every frame. They're recorded shown and hidden only, and the viewer hangs them
-- off the recorded pointer instead, since following the cursor would otherwise cost a moment per sample
ReplayFormat.POINTER_FOLLOWERS = {
	["BuildingUI/PCGuide"] = true,
	["BuildingUI/Invalid"] = true,
}

-- Paths stay short enough to read in the viewer's feed; text is a banner line or a toast
local MAX_PATH_LENGTH = 80
local MAX_TEXT_LENGTH = 200

-- The only markup a recorded line may keep: GuiUtil.Colorize's, which is all the banner and toasts are built from
local ALLOWED_TAGS = { '^<font color="rgb%(%d+,%d+,%d+%)">$', "^</font>$" }

-- One sample, read back out of the flat array the recorder sent
export type Sample = {
	Position: Vector3, -- base-relative, studs
	Yaw: number, -- degrees the avatar faces, in the base's frame
	CameraPosition: Vector3, -- base-relative; the camera can sit far from the avatar
	CameraYaw: number,
	CameraPitch: number,
	CellX: number?, -- the grid cell the ghost sat on, nil while no ghost was showing
	CellZ: number?,
	Rotation: number,
	State: number,
	Fps: number,
	Flags: number,
	Fov: number,
	Pointer: Vector2?, -- viewport pixels, nil with no mouse or finger down
	Pointer2: Vector2?, -- a second finger
	Input: number, -- Enum.PreferredInput value
	Ping: number, -- milliseconds
}

-- The verdict code for a frame: no tool out reads as None, a tool with no refusal as Valid.
function ReplayFormat.StateFromRefusal(placing: boolean, refusal: string?): number
	if not placing then
		return ReplayFormat.State.None
	end

	if not refusal then
		return ReplayFormat.State.Valid
	end

	return STATE_FROM_REFUSAL[refusal] or ReplayFormat.State.Other
end

-- Rounds a number to `decimals` places, which is what keeps a stored track from being mostly digits.
function ReplayFormat.Round(value: number, decimals: number): number
	local scale = 10 ^ decimals
	return math.round(value * scale) / scale
end

-- Whether a value is a number a DataStore and a CFrame can both take. The second comparison rejects NaN.
local function isSafeNumber(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) <= MAX_MAGNITUDE
end

-- Whether a flat sample is shaped the way the viewer will read it. Every track crosses a remote before it is
-- stored, so this is what stops a forged one reaching the DataStore or the viewer's renderer.
function ReplayFormat.IsValidSample(sample: any): boolean
	if type(sample) ~= "table" or #sample ~= ReplayFormat.SAMPLE_LENGTH then
		return false
	end

	for index = 1, ReplayFormat.SAMPLE_LENGTH do
		if not isSafeNumber(sample[index]) then
			return false
		end
	end

	local state = sample[ReplayFormat.Field.State]

	return state >= ReplayFormat.State.None and state <= ReplayFormat.State.Other
end

-- Cuts a client string to `limit` characters and, for player-facing text, strips any markup Colorize didn't make.
-- Nil for anything that isn't valid UTF-8, which would otherwise make the DataStore write throw.
local function cleanString(value: any, limit: number, isText: boolean): string?
	if type(value) ~= "string" or not utf8.len(value) then
		return nil
	end

	-- Cut on a character boundary, so a multi-byte character is never split into invalid UTF-8
	local cut = utf8.offset(value, limit + 1)
	if cut then
		value = string.sub(value, 1, cut - 1)
	end

	if not isText then
		return value
	end

	-- After the cut, so a tag the cut left half-open is caught here too
	return (string.gsub(value, "<[^<>]*>?", function(tag: string)
		for _, pattern in ALLOWED_TAGS do
			if string.match(tag, pattern) then
				return nil
			end
		end

		return ""
	end))
end

-- A client moment rebuilt from its parts, or nil if any part is misshapen. Every moment crosses a remote on its way
-- to a DataStore and then a viewer's screen, so nothing is kept that wasn't checked here.
function ReplayFormat.CleanMoment(raw: any): { any }?
	if type(raw) ~= "table" then
		return nil
	end

	local position, kind = raw[1], raw[2]
	local shape = MOMENT_SHAPES[kind]
	if not shape or not isSafeNumber(position) or #raw ~= 2 + #shape then
		return nil
	end

	local clean = { ReplayFormat.Round(position, 2), kind }

	for index = 1, #shape do
		local expected = string.sub(shape, index, index)
		local value = raw[index + 2]

		if expected == "n" then
			if not isSafeNumber(value) then
				return nil
			end
		else
			value = cleanString(
				value,
				if expected == "t" then MAX_TEXT_LENGTH else MAX_PATH_LENGTH,
				expected == "t"
			)
			if not value then
				return nil
			end
		end

		clean[index + 2] = value
	end

	return clean
end

-- The state a moment sets, as a key a later moment of the same subject replaces. Nil for one-off events.
function ReplayFormat.GetMomentStateKey(moment: { any }): string?
	local kind = moment[2]

	if not STATEFUL_KINDS[kind] then
		return nil
	end

	if kind == ReplayFormat.Moment.Ui or kind == ReplayFormat.Moment.Slot then
		return `{kind}:{moment[3]}`
	end

	if kind == ReplayFormat.Moment.Prompt then
		return `{kind}:{moment[4]}:{moment[5]}`
	end

	return tostring(kind)
end

-- Turns one flat sample into the shape the viewer renders from.
function ReplayFormat.ToSample(flat: { number }): Sample
	local Field = ReplayFormat.Field
	local NO_POINTER = ReplayFormat.NO_POINTER
	local cellX = flat[Field.CellX]
	local cellZ = flat[Field.CellZ]
	local pointerX = flat[Field.PointerX]
	local pointer2X = flat[Field.Pointer2X]

	return {
		Position = Vector3.new(flat[Field.X], flat[Field.Y], flat[Field.Z]),
		Yaw = flat[Field.Yaw],
		CameraPosition = Vector3.new(flat[Field.CameraX], flat[Field.CameraY], flat[Field.CameraZ]),
		CameraYaw = flat[Field.CameraYaw],
		CameraPitch = flat[Field.CameraPitch],
		CellX = if cellX == ReplayFormat.NO_CELL then nil else cellX,
		CellZ = if cellZ == ReplayFormat.NO_CELL then nil else cellZ,
		Rotation = flat[Field.Rotation],
		State = flat[Field.State],
		Fps = flat[Field.Fps],
		Flags = flat[Field.Flags],
		Fov = flat[Field.Fov],
		Pointer = if pointerX == NO_POINTER then nil else Vector2.new(pointerX, flat[Field.PointerY]),
		Pointer2 = if pointer2X == NO_POINTER then nil else Vector2.new(pointer2X, flat[Field.Pointer2Y]),
		Input = flat[Field.Input],
		Ping = flat[Field.Ping],
	}
end

return ReplayFormat
