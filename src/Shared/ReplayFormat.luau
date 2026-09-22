-- The FTUE replay's motion track: one shared definition of what a sample holds, so the recorder, the store and
-- the viewer all read the same shape. A sample is a flat array of numbers rather than a dictionary -- it crosses
-- a remote and a DataStore, both of which cost per key, and the field order below is the only thing either side
-- needs to agree on. Positions are base-relative, so a recording plays back on whichever base the viewer uses.

local ReplayFormat = {}

-- Bumped whenever the field order below moves; a record written under another version is refused rather than misread
ReplayFormat.VERSION = 1

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
	UiFlags = 15,
}

ReplayFormat.SAMPLE_LENGTH = 15

-- Studs and degrees are rounded before they go on the wire; finer than this is below what a replay can show,
-- and a full-precision float costs three times the characters once a DataStore turns it into JSON
ReplayFormat.POSITION_DECIMALS = 2
ReplayFormat.ANGLE_DECIMALS = 1

-- What a cell field holds when nothing is aimed; no real cell reaches it
ReplayFormat.NO_CELL = -32768

-- Well past any real base, and what keeps a forged sample from reaching a DataStore or the viewer's renderer
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
}

-- Which on-screen build hints resolved on the recording client, so "the button never showed" is visible
ReplayFormat.UiFlag = {
	Guide = 1,
	Invalid = 2,
}

-- One sample, read back out of the flat array the recorder sent
export type Sample = {
	Position: Vector3, -- base-relative, studs
	Yaw: number, -- degrees the avatar faces, in the base's frame
	CameraPosition: Vector3, -- base-relative; the camera can sit far from the avatar
	CameraYaw: number,
	CameraPitch: number,
	CellX: number?, -- the grid cell the ghost sat on, nil with nothing aimed
	CellZ: number?,
	Rotation: number,
	State: number,
	Fps: number,
	UiFlags: number,
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

-- Whether a flat sample is shaped the way the viewer will read it. Every track crosses a remote before it is
-- stored, so this is what stops a forged one reaching the DataStore or the viewer's renderer.
function ReplayFormat.IsValidSample(sample: any): boolean
	if type(sample) ~= "table" or #sample ~= ReplayFormat.SAMPLE_LENGTH then
		return false
	end

	for index = 1, ReplayFormat.SAMPLE_LENGTH do
		local value = sample[index]

		-- The second comparison rejects NaN, which would otherwise ride into a CFrame and break the viewer
		if type(value) ~= "number" or value ~= value or math.abs(value) > MAX_MAGNITUDE then
			return false
		end
	end

	local state = sample[ReplayFormat.Field.State]

	return state >= ReplayFormat.State.None and state <= ReplayFormat.State.Other
end

-- Turns one flat sample into the shape the viewer renders from.
function ReplayFormat.ToSample(flat: { number }): Sample
	local Field = ReplayFormat.Field
	local cellX = flat[Field.CellX]
	local cellZ = flat[Field.CellZ]

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
		UiFlags = flat[Field.UiFlags],
	}
end

return ReplayFormat
