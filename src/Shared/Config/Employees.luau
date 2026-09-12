-- The hut's employees: what each role works, and how its star rating turns into behaviour. See docs/balance.md.

-- Shared
local MathUtil = require(script.Parent.Parent.MathUtil)
local StickModel = require(script.Parent.Parent.StickModel)

-- Config
local Rating = require(script.Parent.Rating)

-- The guide's "Stars" colour, the same gold as every other highlight in the game
local STAR_COLOR = "#ffd400"

--
export type Employee = {
	Role: string, -- one of Employees.ROLES; an employee only ever works the one station
	-- 0-1 rather than stars, so Rating.ToStars owns the scale and retuning it moves every employee at once
	Skill: number,
	Body: string, -- one of Employees.BODIES, and the template's name under Assets.Employees
	Name: string,
	-- What it's wearing, by asset id, keyed by the HumanoidDescription field each one is written to
	Cosmetics: { Hair: string?, Hat: string?, Head: string?, Skin: string? },
	Carrying: StickModel.StickRecord?, -- the skewer in its hands between stations, nil while empty-handed
	Slot: number?, -- the hut slot it's equipped in; nil while unequipped, and only an equipped one gets a rig
	HiredAt: number,
}

--
local Employees = {}

-- What an employee can be. One each, never a spread -- a cooker never assembles, so its star means one thing
Employees.ROLES = {
	COOKER = "Cooker",
	BBQ_MAKER = "BbqMaker",
	SELLER = "Seller",
}

table.freeze(Employees.ROLES)

-- The same three in a fixed order. ROLES is a dictionary, and a dictionary's iteration order differs between
-- servers -- anything drawing a role from a shared seed has to walk this instead
Employees.ROLE_ORDER = { Employees.ROLES.COOKER, Employees.ROLES.BBQ_MAKER, Employees.ROLES.SELLER }

table.freeze(Employees.ROLE_ORDER)

-- The rig templates, and the model names under ServerStorage.Assets.Employees. Named rather than resolved:
-- this config is required on the client too, which can't see ServerStorage at all
Employees.BODIES = { "Male", "Female" }

table.freeze(Employees.BODIES)

-- The tag a spawned rig wears, and the attribute its state is published under -- readable in the explorer
-- while debugging, and what a client controller will hang billboards off later
Employees.TAG = "Employee"
Employees.STATE_ATTRIBUTE = "EmployeeState"
Employees.UID_ATTRIBUTE = "EmployeeUid"
Employees.ROLE_ATTRIBUTE = "EmployeeRole"

-- The ScreenGui in the owner's PlayerGui their baked portraits land in, each named by uid. PlayerGui, so only the owner is sent them
Employees.PORTRAIT_FOLDER = "EmployeePortraits"

-- The ScreenGui a role's guide is drawn in, opened off the Info buttons on the hut and the hiring board
Employees.GUIDE_UI_NAME = "GuideUI"

-- Why they're in that state, where a state can be entered for more than one reason. Picks a `{State}{Variant}`
-- label and a `{Category}{Variant}` line, so the sign and the bubble are always saying the same thing
Employees.VARIANT_ATTRIBUTE = "EmployeeStateVariant"

-- When the state they're in finishes, absolute on workspace:GetServerTimeNow() so the billboard counts it
-- down without a server tick. Nil on a state that takes as long as the walk takes
Employees.DEADLINE_ATTRIBUTE = "EmployeeDeadline"

-- Stamped on a customer rig by the seller working it, so two sellers don't race each other to the answer.
-- Cleared by NpcRig.Release alongside the customer systems' own, or a pooled rig carries a stale claim
Employees.SERVED_BY_ATTRIBUTE = "EmployeeServedBy"

-- The part on each base's Core folder a seller stands on, beside the customers' own spawn and stand parts
Employees.SELLER_POST_PART = "SellerEmployeeStandPart"

-- The billboard over their head, and the labels inside it
Employees.BILLBOARD_UI = "EmployeeUIAttachment"
Employees.BILLBOARD_NAME = "StateUI"
Employees.BILLBOARD_HOLDER = "Holder"
Employees.BILLBOARD_STATE = "State"
Employees.BILLBOARD_TIMER = "Timer"

-- Who they are, sat above what they're doing: the role's icon and the name they were hired under
Employees.BILLBOARD_INFO = "EmployeeInfo"
Employees.BILLBOARD_ROLE_ICON = "EmployeePositionIcon"
Employees.BILLBOARD_STAFF_NAME = "EmployeeName"

-- One icon per role, so a glance across a base says who does what without reading a word of it
Employees.ROLE_ICONS = {
	[Employees.ROLES.COOKER] = "rbxassetid://135936976259049",
	[Employees.ROLES.BBQ_MAKER] = "rbxassetid://114432309608958",
	[Employees.ROLES.SELLER] = "rbxassetid://131832261183656",
}

table.freeze(Employees.ROLE_ICONS)

-- What a role is called to a player. Never the id: "BbqMaker" is a key, not a job
Employees.ROLE_NAMES = {
	[Employees.ROLES.COOKER] = "Chef",
	[Employees.ROLES.BBQ_MAKER] = "BBQ Maker",
	[Employees.ROLES.SELLER] = "Seller",
}

table.freeze(Employees.ROLE_NAMES)

-- One line on what each one does, for the board they're hired from. Written for the youngest player who'll
-- read it, and using the in-game name for everything it sends them to look at
Employees.ROLE_DESCRIPTIONS = {
	[Employees.ROLES.COOKER] = "Cooks your BBQ on a Grill, then puts it out to sell",
	[Employees.ROLES.BBQ_MAKER] = "Gets Sticks and ingredients from the Hut and makes BBQ for you",
	[Employees.ROLES.SELLER] = "Talks to Customers for you and pushes for a better price",
}

table.freeze(Employees.ROLE_DESCRIPTIONS)

-- What more Stars get each role, for the guide's Benefit line. The guide's steps are authored in the GuideUI itself
Employees.ROLE_BENEFITS = {
	[Employees.ROLES.COOKER] = `More <font color="{STAR_COLOR}">Stars</font> = works faster, cooks better BBQ and runs more Grills at once`,
	[Employees.ROLES.BBQ_MAKER] = `More <font color="{STAR_COLOR}">Stars</font> = works faster and carries more stuff`,
	[Employees.ROLES.SELLER] = `More <font color="{STAR_COLOR}">Stars</font> = works faster and gets you more money`,
}

table.freeze(Employees.ROLE_BENEFITS)

-- How often they might pipe up, and the chance they actually do when the moment comes. Rolled rather
-- than fixed, so a row of them doesn't chatter in unison. Their lines live in Config.NpcDialogue
Employees.SPEAK_INTERVAL_MIN = 8
Employees.SPEAK_INTERVAL_MAX = 20
Employees.SPEAK_CHANCE = 45

-- The dialogue category for a state, matched to the `Employee{State}` entries in Config.NpcDialogue
Employees.DIALOGUE_PREFIX = "Employee"

-- How far the billboard springs up per chat bubble under it, so a line doesn't cover what they're doing.
-- Springs rather than snaps, and settles back as each bubble expires
Employees.BUBBLE_CLEARANCE = 2.5
Employees.BUBBLE_RAISE_DAMPING = 0.7
Employees.BUBBLE_RAISE_FREQUENCY = 3

-- The trailing dots on the state line, so a job with no countdown still reads as something in progress
Employees.STATE_MAX_DOTS = 3
Employees.STATE_DOT_INTERVAL = 0.4

-- How a countdown reads. Hundredths, since most of these are only a few seconds long
Employees.TIMER_FORMAT = "%.2fs"

-- What each state says over their head, by role, so two roles can use one state id and read differently.
-- Written for the youngest player who'll see it: what they're doing, in words, never a state id
Employees.STATE_LABELS = {
	Cooker = {
		Idle = "Looking for BBQ",
		ToStand = "Going to Get BBQ",
		Await = "Waiting for You to Finish",
		Collect = "Picking Up BBQ",
		ToGrill = "Taking BBQ to the Grill",
		ToTend = "Helping at the Grill",
		ToTendBack = "Going Back to the Grill",
		Place = "Putting BBQ on the Grill",
		Tend = "Waiting for BBQ",
		TendReady = "Picking Up BBQ",
		Pull = "Taking BBQ Off the Grill",
		ToSell = "Taking BBQ to Sell",
		Deliver = "Putting BBQ Out to Sell",
		DeliverFull = "Waiting for Space to Sell",
	},

	Seller = {
		Post = "Waiting for Customers",
		PostEmpty = "No BBQ to Sell",
		Haggle = "Talking to a Customer",
	},

	BbqMaker = {
		-- Idle is worth naming: why it isn't working is the one thing the player can do something about
		Hover = "Looking for a Stick Stand",
		HoverWaiting = "Letting You Build",
		HoverEmpty = "The Hut is Empty",
		HoverNoSticks = "Needs More Sticks",
		HoverNoIngredients = "Needs More Ingredients",
		ToStore = "Going to the Hut",
		Fetch = "Getting BBQ Stuff",
		ToBench = "Carrying BBQ Stuff",
		Build = "Making BBQ",
	},
}

table.freeze(Employees.STATE_LABELS)

-- How often the roster steps. Every state is a poll, so this is the reaction time of the whole system
Employees.TICK_INTERVAL = 0.25

-- Seconds before an idle employee spots work it hasn't noticed yet. Also what keeps a full roster from
-- re-reading the base four times a second. A poor one is genuinely slow off the mark
Employees.NOTICE_WORST = 4
Employees.NOTICE_BEST = 0.25
Employees.NOTICE_GAMMA = 1

-- Stars needed to read a stand that's still being loaded and go stand ready at it. Under this they only
-- react once the stick is finished, which is the difference between staff who anticipate and staff who don't
Employees.ANTICIPATE_STARS = 2.5

-- Their own rather than the customers', since an employee crosses a whole base where a customer walks to one stall
Employees.ARRIVE_DISTANCE = 4
Employees.WALK_TIMEOUT = 12
Employees.FADE_DURATION = 0.4

-- How far clear of a station's edge it stands to work it, so it works a grill from beside rather than on top of it
Employees.STATION_CLEARANCE = 3

-- Tighter than ARRIVE_DISTANCE, which is coarse enough that an employee already beside a grill would count
-- as having arrived and never square up to it
Employees.TEND_ARRIVE_DISTANCE = 1.5

-- How close counts as standing on a post. Looser than the grill face: MoveTo settles a stud or two short,
-- and a tighter figure leaves them pacing on the spot trying to close a gap they never will
Employees.POST_ARRIVE_DISTANCE = 2.5

-- Studs between sellers along the counter. Wider than POST_ARRIVE_DISTANCE, or two that each stopped short
-- on the near side of their own slot would still be stood in the same place
Employees.POST_SPACING = 6

-- How long an idle employee pauses between strolls, so it wanders the plots rather than pacing without stopping
Employees.WANDER_PAUSE_MIN = 2
Employees.WANDER_PAUSE_MAX = 6

-- The size a carried skewer is held at. One, not the customers' shrunken display size -- staff hold it as a player does
Employees.CARRY_SKEWER_SCALE = 1

-- Behaviour is read off the star rating and never stored: a WORST value at MIN_STARS, a BEST at 5, and a
-- gamma bending the curve between. Above 1 holds the low end down, so the top of the ladder is the thing
-- worth rolling for

-- The lowest rating an employee can be hired at, so every WORST above describes the worst worker a player
-- can actually get rather than a 0-star nobody is ever handed
Employees.MIN_STARS = 0.25

-- How far off its aim a cooker pulls, as a multiple of the perfect window's half-width in wall seconds. Wide
-- at the bottom on purpose: the spread is what makes a poor chef's pull a gamble rather than a fixed penalty
Employees.COOK_ERROR_WORST = 2.75
Employees.COOK_ERROR_BEST = 0.08
Employees.COOK_ERROR_GAMMA = 1.4

-- Where it pulls. Under 1 it's a fraction of the perfect window, 0 being the moment the bar turns green;
-- over 1 it's that far again past the window, 2 landing exactly where a full bar starts reading Overcooked.
-- Best is a hair off zero, since a finished cook only loses value from here -- a five star pulls on green.
-- Worst sits deep in Cooked, so a poor chef's ordinary day is a nicely-cooked skewer and its bad one is burnt
Employees.COOK_AIM_WORST = 1.45
Employees.COOK_AIM_BEST = 0.05
Employees.COOK_AIM_GAMMA = 1.5

-- Lerped onto the rig's Humanoid. Deliberately narrow -- speed is flavour, the pull is the ladder
Employees.WALK_SPEED_WORST = 12
Employees.WALK_SPEED_BEST = 18
Employees.WALK_SPEED_GAMMA = 1

-- Seconds spent taking something off a station: a stick off a stand, a skewer off a grill. The best is a
-- tick, which is as near instant as the roster can step, and this runs twice over one skewer
Employees.PICKUP_OVERHEAD_WORST = 6
Employees.PICKUP_OVERHEAD_BEST = 0.25
Employees.PICKUP_OVERHEAD_GAMMA = 1

-- Seconds spent putting something down: onto a grill, out on the sell stand. Under the pickup, since setting
-- a skewer down is the easier half of the job
Employees.PLACE_OVERHEAD_WORST = 5
Employees.PLACE_OVERHEAD_BEST = 0.25
Employees.PLACE_OVERHEAD_GAMMA = 1

-- Star marks where a cooker picks up another grill; the count is how many it has cleared. Gaps widen, since
-- capacity is raw throughput and has to stay contained
Employees.GRILL_MARKS = { 0, 3.5, 4.5 }

table.freeze(Employees.GRILL_MARKS)

-- Seconds of slack an errand must leave before every pull it's judged against: MoveTo settling short, a
-- tick's jitter and the aim's own error. Short of it the cooker stays with what it has rather than gamble a cook
Employees.GRILL_ERRAND_MARGIN = 3

-- How much better than break-even the odds must look before a seller turns an offer down for more. This is
-- what keeps a seller from ever being worse than none: the worst it can be is too cautious, which is the
-- same as accepting. It can't push into a losing bet
Employees.SELL_MARGIN_WORST = 0.6
Employees.SELL_MARGIN_BEST = 0
Employees.SELL_MARGIN_GAMMA = 1.2

-- Star marks where a seller will push one more round, capped by SellNpc.MAX_COUNTER_ROUNDS. Under the first
-- it never haggles at all, which is the one star taking whatever it's handed
-- What letting a customer walk costs, as a share of the offer on the table. The skewers go back on the stand
-- and the next customer rolls the same numbers, so nothing is lost but the wait for them -- and a seller's
-- own refusals don't price down later offers, so this is the whole of what it weighs a push against
Employees.SELL_WALK_COST = 0.1

Employees.SELL_PUSH_MARKS = { 2, 3.25, 4.5 }

table.freeze(Employees.SELL_PUSH_MARKS)

-- Seconds spent weighing an offer before answering. Well inside SellNpc.OFFER_TIMEOUT, so even a slow one
-- never lets an offer lapse -- a lapsed sale would be worse than no seller at all
Employees.SELL_DECIDE_WORST = 4
Employees.SELL_DECIDE_BEST = 0.3
Employees.SELL_DECIDE_GAMMA = 1

-- Star marks where a maker carries another ingredient per trip. This is its ladder: a one star fetches one
-- at a time and walks back for every one, which is the star you can watch rather than read
Employees.MAKER_CARRY_MARKS = { 0, 1.2, 2.4, 3.6, 4.8 }

table.freeze(Employees.MAKER_CARRY_MARKS)

-- The slice of the store's stock, richest first, a maker will draw from. At 1 it takes anything, which is the
-- floor on purpose: picking the *cheapest* would make the star worth as much as the gap between the best and
-- worst thing stocked, where picking at random only ever averages what the player put in
Employees.MAKER_PICK_TOP_WORST = 1
Employees.MAKER_PICK_TOP_BEST = 0.05
Employees.MAKER_PICK_TOP_GAMMA = 1.2

-- Seconds a maker spends threading one item onto a stand. Its own rather than PLACE_OVERHEAD, since a
-- stick goes on item by item and the worst of that has to stay short enough to watch
Employees.MAKER_BUILD_WORST = 3
Employees.MAKER_BUILD_BEST = 0.25
Employees.MAKER_BUILD_GAMMA = 1

-- Seconds a stand stays the player's after they touch it, so a skewer being built by hand is left alone
Employees.PLAYER_BUILD_COOLDOWN = 30

-- How far past the hut's own edge a maker drifts while waiting for work. Measured from the wall rather than
-- the middle, so it circles the store instead of walking through it, and stays put rather than roaming the
-- plots the way a cooker between jobs does
Employees.HOVER_RADIUS = 6

-- How a carried load sits over the head. Every piece keeps the size it's authored at, exactly as the player's
-- own carried item does -- scaling them all to one figure is what made a grape and a gold stick both read wrong

-- How far the next piece sits up, as a share of the one under it. Below 1 so a load overlaps into a pile
-- rather than a tower, and proportional so it reads the same whatever size the ingredient is authored at
Employees.CARRY_STACK_STEP = 0.55
-- Laid across the pile rather than standing up it: sticks are authored along the axis the stack grows
Employees.CARRY_STICK_ROTATION = CFrame.Angles(0, 0, math.rad(90))
-- Studs above the rig's middle the pile sits at, before its own height is added on top. Matched to the
-- height a player carries theirs at, since it's the same idea: balanced over the head, not held in a hand
Employees.CARRY_HOLD_HEIGHT = 2.7

-- The wardrobe. Grouped by the HumanoidDescription field each id is written to rather than by what it looks
-- like -- a fair few classic hairs are catalogued as hats, and one applied as hair is silently dropped.
-- Stored by id on the employee, so a worker hired today keeps its look for good
Employees.Cosmetics = {
	-- Per body, since a look is either hair or a hat and never both: a bonnet over a fringe reads as a bug
	Hair = {
		Male = { "6413085241", "16630147", "376548738", "376524487", "63690008", "323476364", "12270248" },
		Female = { "293316608", "398673423", "13745548", "14815761", "376527350", "398673196" },
	},
	Hats = { "99337647058661", "12803334695", "12803311281" },
	-- Head assets, so they're written to the description's Head field. Not Face, which takes a classic face
	-- Decal, and not FaceAccessory -- the engine refuses a description naming one asset in two fields
	Heads = { "73416990248532", "85610697166846", "134854047518378", "71717161940850" },
}

table.freeze(Employees.Cosmetics)

-- Skin tones, drawn evenly, so the mix across a board is however this list is weighted by hand. Stored on the
-- employee as the hex itself rather than as an index into it, so adding to it or reordering it can never
-- repaint somebody already hired
Employees.SKIN_TONES = {
	"6B4230",
	"8A5A3C",
	"A9714C",
	"B87F52",
	"C68642",
	"D19A5E",
	"D9A066",
	"E0AC69",
	"E8B98D",
	"EDB98A",
	"F1C27D",
	"F3CB9C",
	"F5CFA0",
	"FBD9B0",
	"FFDBAC",
}

table.freeze(Employees.SKIN_TONES)

-- How often a rolled look wears a hat instead of hair, out of 100
Employees.HAT_CHANCE = 35

-- Names, split by the body they suit: the rigs are authored as one or the other, and a name that doesn't
-- match reads as a bug rather than as variety. The unisex block folds into both, so those turn up on either
local MALE_NAMES = {
	"Marcus",
	"Bo",
	"Nico",
	"Wes",
	"Otis",
	"Aaron",
	"Tom",
	"Harrison",
	"Leo",
	"Max",
	"Jack",
	"Finn",
	"Milo",
	"Theo",
	"Eli",
	"Ray",
	"Gus",
	"Hank",
	"Vince",
	"Dante",
	"Omar",
	"Rico",
	"Cesar",
	"Diego",
	"Mateo",
	"Pablo",
	"Hugo",
	"Andre",
	"Felix",
	"Bruno",
	"Ivan",
	"Yuri",
	"Kenji",
	"Hiro",
	"Tariq",
	"Amir",
	"Kofi",
	"Zane",
	"Cole",
	"Reid",
	"Duke",
	"Clay",
	"Frank",
	"Earl",
	"Gil",
	"Lou",
	"Moe",
	"Pete",
	"Rex",
	"Sid",
	"Vic",
	"Walt",
	"Abe",
	"Bert",
	"Curt",
	"Dex",
	"Emmet",
	"Floyd",
	"Roscoe",
	"Marlon",
	"Garry",
}

local FEMALE_NAMES = {
	"Lala",
	"Rosa",
	"Ines",
	"Ada",
	"Fern",
	"Juno",
	"Pip",
	"Aerielle",
	"Claire",
	"Nina",
	"Mia",
	"Zoe",
	"Lena",
	"Cora",
	"Ruby",
	"Iris",
	"Opal",
	"Pearl",
	"Hazel",
	"Willa",
	"Maeve",
	"Elsie",
	"Greta",
	"Anita",
	"Lola",
	"Carmen",
	"Paloma",
	"Sofia",
	"Elena",
	"Nadia",
	"Yara",
	"Amina",
	"Leila",
	"Zara",
	"Mei",
	"Sana",
	"Aiko",
	"Priya",
	"Esme",
	"Bea",
	"Dot",
	"Etta",
	"Flo",
	"Ginny",
	"Hattie",
	"Ivy",
	"Kitty",
	"Lulu",
	"Mabel",
	"Nell",
	"Oona",
	"Poppy",
	"Rita",
	"Susie",
	"Tess",
	"Vera",
	"Winnie",
	"Birdie",
	"Clara",
	"Daisy",
	"Edie",
	"Ann",
}

local UNISEX_NAMES = {
	"Dee",
	"Kel",
	"Tay",
	"Sam",
	"Rue",
	"Jay",
	"Charlie",
	"Alex",
	"Jamie",
	"Jordan",
	"Casey",
	"Riley",
	"Quinn",
	"Avery",
	"Frankie",
	"Jules",
	"Kai",
	"Lee",
	"Mickey",
	"Robin",
	"Sage",
	"Sky",
	"Toby",
	"Val",
	"Wren",
	"Ash",
	"Blair",
	"Drew",
	"Ellis",
	"Harper",
}

-- [body] = its own names with the unisex ones after. Concatenated in a fixed order, since a name drawn off a
-- shared seed has to come out the same on every server
Employees.NAMES_BY_BODY = {}

for body, names in { Male = MALE_NAMES, Female = FEMALE_NAMES } do
	local combined = table.clone(names)

	for _, name in UNISEX_NAMES do
		table.insert(combined, name)
	end

	table.freeze(combined)
	Employees.NAMES_BY_BODY[body] = combined
end

table.freeze(Employees.NAMES_BY_BODY)

-- The names that suit `body`. Falls back to the first body's, so a body the config doesn't know still gets a name rather than nil.
function Employees.GetNames(body: string): { string }
	return Employees.NAMES_BY_BODY[body] or Employees.NAMES_BY_BODY[Employees.BODIES[1]]
end

-- What a role's state reads as over their head. Falls back through the plain state to the state id, so a new state is visible rather than blank.
function Employees.GetStateLabel(role: string, state: string, variant: string?): string
	local labels = Employees.STATE_LABELS[role]
	if not labels then
		return state
	end

	return (variant and labels[state .. variant]) or labels[state] or state
end

-- A behaviour number for `skill` (0-1), bent by `gamma`. Every star-driven value goes through here.
function Employees.InterpolateBySkill(worst: number, best: number, gamma: number, skill: number): number
	-- Measured up from the floor rather than from 0, so WORST is what a MIN_STARS worker does and the whole
	-- curve is spent on ratings a player can be handed
	local floor = Employees.MIN_STARS / Rating.MAX_STARS
	local reach = math.clamp((skill - floor) / (1 - floor), 0, 1)

	return MathUtil.Lerp(worst, best, reach ^ gamma)
end

-- How many of `marks` a star rating has cleared, so an integer ladder reads off one authored array.
function Employees.GetTierFromStars(marks: { number }, stars: number): number
	local tier = 0

	for _, mark in marks do
		if stars >= mark then
			tier += 1
		end
	end

	return tier
end

return Employees
