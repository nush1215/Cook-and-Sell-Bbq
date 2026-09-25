-- Hungry Joe: lends a stick, waits for it to come back cooked, and pays a feast for it. See docs/balance.md.

--
local HungryJoeNpc = {}

-- How Hungry Joe is named in toasts
HungryJoeNpc.LABEL = `<font color="#ff8c3c">HUNGRY JOE</font>`

-- The Sticks entry he lends. Flagged Borrowed there, which is what keeps it off the stall, the huts and the staff
HungryJoeNpc.STICK_ID = "HungryJoeStick"

-- Sweep interval and per-player chance out of 100, rolled only once MIN_GAP has passed. Low, so visits spread across the gap
HungryJoeNpc.CHECK_INTERVAL = 30
HungryJoeNpc.SPAWN_CHANCE = 5

-- Seconds since his last visit ended: never sooner than MIN_GAP, always sent by MAX_GAP (the pity). With a visit's own length on top, about one an hour
HungryJoeNpc.MIN_GAP = 40 * 60
HungryJoeNpc.MAX_GAP = 60 * 60

-- The same for their very first visit, counted from when his clock starts after the tutorial, so a new player meets him in their first session
HungryJoeNpc.FIRST_MIN_GAP = 15 * 60
HungryJoeNpc.FIRST_MAX_GAP = 20 * 60

-- Seconds he waits for an answer before walking off. Once they take the job, his patience clock below takes over
HungryJoeNpc.OFFER_TIMEOUT = 45

-- Seconds a saved visit waits before he's put back, so he lands on a settled client
HungryJoeNpc.RESTORE_DELAY = 2

-- Where he stands: just off the stand's centre, a step back and a little to one side, inside where custom orders wait
HungryJoeNpc.WAIT_BACK_DISTANCE = 4
HungryJoeNpc.WAIT_SIDE_DISTANCE = 6

-- Seconds his stick can go without reaching a grill before he warns he's leaving. Never shown, so the wait reads as open-ended
HungryJoeNpc.IDLE_TIMEOUT = 15 * 60

-- Seconds the shown warning gives them to hand his BBQ over before he leaves with his stick. Only a hand-over stops it
HungryJoeNpc.WARNING_DURATION = 90

-- The shown clock once his stick is on a grill, sized as a custom order's is: the cook plus this much leeway
HungryJoeNpc.COOK_LEEWAY_BASE = 90
HungryJoeNpc.COOK_LEEWAY_PER_INGREDIENT = 45

-- His clock's stages. Idle is hidden; Cook and Warning publish their deadline on the rig for the countdown
HungryJoeNpc.CLOCK_ATTRIBUTE = "HungryJoeDeadline"
HungryJoeNpc.CLOCK_PHASES = {
	Idle = "Idle",
	Cook = "Cook",
	Warning = "Warning",
}

-- Seconds between his waiting lines, so a long wait nags now and then rather than constantly
HungryJoeNpc.WAIT_SAY_INTERVAL_MIN = 40
HungryJoeNpc.WAIT_SAY_INTERVAL_MAX = 70

-- Seconds between refused hand-overs, so leaning on the prompt can't stack bubbles and toasts
HungryJoeNpc.SCOLD_INTERVAL = 1.5

-- Seconds he spends eating. Longer than SellNpc.EAT_DURATION, since it's up to ten bites
HungryJoeNpc.EAT_DURATION = 12

-- Cook states he won't take. Any fill is fine, and the feast scales with it
HungryJoeNpc.REFUSED_COOK_STATES = {
	Raw = true,
}

-- The feast's Bux: the stick's sell value times this, paid as a sale so the player's boosts apply
HungryJoeNpc.FEAST_MULTIPLIER = 1.5

-- Gems on a full stick, rolled between these and scaled down by how much of it was filled
HungryJoeNpc.GEMS_MIN = 30
HungryJoeNpc.GEMS_MAX = 50

-- Luck on a full stick by how it cooked, Amount a multiplier and Duration in seconds. A state missing here earns none
HungryJoeNpc.LUCK_BY_COOK_STATE = {
	Perfect = { Amount = 1.5, Duration = 300 },
	Cooked = { Amount = 1.25, Duration = 180 },
}

-- The tag a live Hungry Joe wears, so a client that streams him in finds him without a remote
HungryJoeNpc.TAG = "HungryJoeCustomer"

-- How far his visit has got, published on the rig for every client. Shared, so the manager and the controller can't drift
HungryJoeNpc.PHASE_ATTRIBUTE = "HungryJoePhase"
HungryJoeNpc.PHASES = {
	Offering = "Offering",
	Waiting = "Waiting",
}

return HungryJoeNpc
