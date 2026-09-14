-- The wandering wizard: buys one skewer and pays in luck rather than money. See docs/balance.md.

--
local WizardNpc = {}

-- Sweep interval and per-player chance out of 100, rolled only once MIN_GAP has passed
WizardNpc.CHECK_INTERVAL = 30
WizardNpc.SPAWN_CHANCE = 30

-- Seconds since the last visit: never sooner than MIN_GAP, always sent by MAX_GAP (the pity)
WizardNpc.MIN_GAP = 5 * 60
WizardNpc.MAX_GAP = 7 * 60

-- The luck multiplier and how long it lasts in seconds, both rolled when it arrives
WizardNpc.LUCK_MIN = 1.25
WizardNpc.LUCK_MAX = 1.5
WizardNpc.DURATION_MIN = 180
WizardNpc.DURATION_MAX = 300

-- Seconds spent looking the skewer over, standing in for the decide beat it doesn't run
WizardNpc.APPRAISE_DURATION_MIN = 2
WizardNpc.APPRAISE_DURATION_MAX = 3

-- Seconds it waits for an answer before putting the skewer back
WizardNpc.OFFER_TIMEOUT = 30

return WizardNpc
