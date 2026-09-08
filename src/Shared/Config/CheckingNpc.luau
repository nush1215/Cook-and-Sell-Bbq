-- The customer who turns up to ask whether there's any BBQ going, when the stand has sat empty. See docs/balance.md.

--
local CheckingNpc = {}

-- Sweep interval and per-player chance out of 100; with COOLDOWN these set how often one comes asking
CheckingNpc.CHECK_INTERVAL = 10
CheckingNpc.SPAWN_CHANCE = 60

-- Seconds since the last completed sale before one is worth sending -- the "they've drifted off" signal
CheckingNpc.SALE_IDLE_TIME = 70

-- Seconds before that player can draw another, so an empty stand isn't a stream of them
CheckingNpc.COOLDOWN = 40

-- Seconds it stands there asking before giving up, short enough that ignoring it costs nothing
CheckingNpc.WAIT_DURATION = 25

-- How often the wait loop re-reads the stand, so a placement is spotted near-instantly
CheckingNpc.POLL_INTERVAL = 0.5

-- Gap between repeated asking lines, so it nags a couple of times over WAIT_DURATION rather than every poll
CheckingNpc.ASK_INTERVAL_MIN = 4
CheckingNpc.ASK_INTERVAL_MAX = 6

-- Where it waits: back from the stand and off to one side, out of the lane a buying customer queues in
CheckingNpc.LOITER_BACK_DISTANCE = 5
CheckingNpc.LOITER_SIDE_DISTANCE_MIN = 3
CheckingNpc.LOITER_SIDE_DISTANCE_MAX = 6

-- How it walks, fades and haggles once it has a skewer it reads off SellNpc

return CheckingNpc
