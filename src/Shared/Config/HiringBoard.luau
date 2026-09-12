-- The worker board in the world: four candidates, rolled from a window seed so every server shows the same
-- four, rotating on a shared clock. Nothing about a candidate is stored until someone hires them.

-- Shared
local MathUtil = require(script.Parent.Parent.MathUtil)

-- Config
local Employees = require(script.Parent.Employees)
local Rating = require(script.Parent.Rating)

--
export type Tier = {
	Id: string, -- also the key into Shared.Colors this tier takes its label colour from
	Weight: number, -- drawn against the other tiers' weights, so these needn't sum to anything
	MinStars: number, -- the band a worker of this tier rolls its star rating inside
	MaxStars: number,
}

export type Worker = {
	Role: string, -- one of Employees.ROLES
	Tier: string, -- which band the stars came out of, for the label colour
	Stars: number, -- 0-5 as the player reads it; the record stores it back down as 0-1 Skill
	Body: string, -- one of Employees.BODIES
	Name: string,
	Hair: string?, -- asset ids, straight onto the rig's HumanoidDescription -- see Employees.Cosmetics
	Hat: string?,
	Head: string?,
	Skin: string?, -- a hex from Employees.SKIN_TONES
	Price: number,
}

--
local HiringBoard = {}

-- The stall itself. Global rather than per-base -- one board everyone reads, beside the StickStall
HiringBoard.STALL_FOLDER = "Stalls"
HiringBoard.STALL_NAME = "WorkerStall"

-- The folder of entry parts, each named for its slot, and the board the prompt and countdown hang off
HiringBoard.ENTRIES_FOLDER = "Entries"
HiringBoard.BOARD_NAME = "Board"

-- Attachments on the board. The prompt's is authored; the other two are where the camera sits while the
-- board is open and where the entry being read poses in front of it
HiringBoard.PROMPT_ATTACHMENT = "EmployeePromptAttachment"
HiringBoard.CAMERA_ATTACHMENT = "CameraAttachment"
HiringBoard.FEATURE_ATTACHMENT = "FeatureAttachment"

-- Where the countdown is drawn, under the board's own attachment
HiringBoard.TIMER_ATTACHMENT = "UIAttachment"
HiringBoard.TIMER_BILLBOARD = "BillboardGui"
HiringBoard.TIMER_LABEL = "Timer"

-- Held rather than tapped, so brushing past the board doesn't throw the panel up
HiringBoard.PROMPT_ACTION_TEXT = "View Workers"
HiringBoard.PROMPT_HOLD_DURATION = 0.1
HiringBoard.PROMPT_MAX_DISTANCE = 13

-- The per-entry panel under Assets.UI, and the screen panel holding the arrows
HiringBoard.INFO_UI = "WorkerInfo"
HiringBoard.SCREEN_UI = "HireEmployeeUI"

-- How many candidates a window offers, and so how many entry parts the stall is authored with
HiringBoard.ENTRY_COUNT = 4

-- Seconds per window. The seed, and so the four workers, is shared across every server
HiringBoard.ROTATE_INTERVAL = 30 * 60

-- Stride between window seeds, matching the shops': headroom so a future re-roll can't land on the next
-- natural window and spoil it before it opens
HiringBoard.SEED_STRIDE = 1_000

-- What the client reads for the countdown, and what the baked portraits are published under
HiringBoard.TIME_LEFT_ATTRIBUTE = "WorkerBoardTimeLeft"
HiringBoard.PREVIEW_FOLDER = "WorkerPreviews"

-- Stamped on each baked rig so a portrait from the window before is never drawn against this window's roll
HiringBoard.SEED_ATTRIBUTE = "WorkerBoardSeed"

-- What the countdown reads. "New Workers", not "Restocking": the shops restock, people don't
HiringBoard.TIMER_PREFIX = "New Workers in "
HiringBoard.TIMER_COLOR = "#55ff00"

-- The star bands, drawn against each other by weight. Ordered rather than keyed, since the draw walks it
-- and a dictionary's order would differ between servers -- see docs/balance.md. Common opens on
-- Employees.MIN_STARS, so the worst worker the board offers is the one every WORST value is written against
HiringBoard.TIERS = {
	{ Id = "Common", Weight = 45, MinStars = Employees.MIN_STARS, MaxStars = 1.5 },
	{ Id = "Uncommon", Weight = 27, MinStars = 1.5, MaxStars = 2.5 },
	{ Id = "Rare", Weight = 16, MinStars = 2.5, MaxStars = 3.5 },
	{ Id = "Epic", Weight = 9, MinStars = 3.5, MaxStars = 4.5 },
	{ Id = "Legendary", Weight = 1, MinStars = 4.5, MaxStars = 5 },
}

table.freeze(HiringBoard.TIERS)

-- The two ends of the ladder: what the worst worker the board can offer costs, and what a five star does.
-- Anchored rather than grown off a base, so moving either end moves every price between them with it
HiringBoard.MIN_PRICE = 1_000
HiringBoard.MAX_PRICE = 125_000

-- Cubed, so the gap between a four and a five star is the thing worth saving several windows for. A one
-- star is $1,500; a five is the whole $125,000, against the hut repair's $25,000
HiringBoard.PRICE_EXPONENT = 3

-- Rounded to this, so a price reads as a price rather than as a formula's output
HiringBoard.PRICE_ROUNDING = 100

-- What a worker of `stars` costs. The curve, not a table, so retuning it moves every star rating at once.
function HiringBoard.GetPrice(stars: number): number
	-- Measured up from the floor the same way Employees.InterpolateBySkill is, so the whole curve is spent
	-- on ratings the board can actually roll rather than on a 0-star nobody is ever offered
	local floor = Employees.MIN_STARS
	local reach = math.clamp((stars - floor) / (Rating.MAX_STARS - floor), 0, 1)
	local raw = MathUtil.Lerp(HiringBoard.MIN_PRICE, HiringBoard.MAX_PRICE, reach ^ HiringBoard.PRICE_EXPONENT)

	return math.round(raw / HiringBoard.PRICE_ROUNDING) * HiringBoard.PRICE_ROUNDING
end

-- The tier with this id, for the label colour. Falls back to the first, so a retune can't return nil.
function HiringBoard.GetTierFromId(tierId: string): Tier
	for _, tier in HiringBoard.TIERS do
		if tier.Id == tierId then
			return tier
		end
	end

	return HiringBoard.TIERS[1]
end

-- The tier a star rating falls in, an edge between two bands going to the lower and likelier one. Falls back to the top, so a retune can't return nil.
function HiringBoard.GetTierFromStars(stars: number): Tier
	for _, tier in HiringBoard.TIERS do
		if stars <= tier.MaxStars then
			return tier
		end
	end

	return HiringBoard.TIERS[#HiringBoard.TIERS]
end

-- The countdown as the board reads it, e.g. "New Workers in 5m 3s". Minutes always shown, so the last stretch reads "0m 9s".
function HiringBoard.FormatTimeLeft(timeLeft: number): string
	local minutes = math.floor(timeLeft / 60)
	local seconds = math.floor(timeLeft % 60)

	return `{HiringBoard.TIMER_PREFIX}<font color="{HiringBoard.TIMER_COLOR}">{minutes}m {seconds}s</font>`
end

-- A star rating inside `tier`'s band, drawn off `rng`. Quantised the same way Rating.ToStars is, so the
-- board and the hired worker's own sign never disagree in the second decimal.
function HiringBoard.RollStars(tier: Tier, rng: Random): number
	return MathUtil.RoundUpTo2Dec(rng:NextNumber(tier.MinStars, tier.MaxStars))
end

return HiringBoard
