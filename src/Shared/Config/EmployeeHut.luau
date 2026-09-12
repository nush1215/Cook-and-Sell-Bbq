-- The employee hut on every base: broken from handover, repaired once for currency, and the shop the employees are bought from. Repairing hands over the Structures entry, so from then on it moves like any other build.

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Assets
local Assets = ReplicatedStorage.Assets

--
local EmployeeHut = {}

-- The folder made on each base model holding the broken hut, so the client has one place to watch
EmployeeHut.FOLDER_NAME = "Hut"

-- What the clone is renamed to, so the art asset's name isn't load-bearing across the client boundary
EmployeeHut.MODEL_NAME = "Hut"

-- Both hut models live in the structures folder together; only the repaired one is a Structures entry
EmployeeHut.CATEGORY = "Huts"

-- The Structures entry the repair hands over. Also the repaired model's name, which is how the back-fill finds it
EmployeeHut.STRUCTURE_ID = "RepairedHut"

-- The attachment under the broken hut's Hitbox the repair prompt hangs off; one parented to a Model never fires
EmployeeHut.PROMPT_ATTACHMENT = "PromptAttachment"

-- The attachments under a repaired hut's Hitbox its storage prompts hang off; one parented to a Model never fires
EmployeeHut.STORE_ONE_ATTACHMENT = "StoreOneAttachment"
EmployeeHut.STORE_ALL_ATTACHMENT = "StoreAllAttachment"
EmployeeHut.VIEW_STORAGE_ATTACHMENT = "ViewStorageAttachment"

-- Where a stored item flies to on its way into the hut
EmployeeHut.STORAGE_INGREDIENT_ATTACHMENT = "StorageIngredientAttachment"

-- The part of a repaired hut that lights up while they hold something it would take, searched for under the model
EmployeeHut.STORAGE_HIGHLIGHT_NAME = "Chest"

-- Answers on the press: dropping one thing in isn't a decision worth holding a key for
EmployeeHut.STORAGE_HOLD_DURATION = 0
EmployeeHut.STORAGE_MAX_DISTANCE = 12

-- A short hold since it moves the whole stack, and F so it sits beside the E store prompt rather than competing with it
EmployeeHut.STORE_ALL_HOLD_DURATION = 0.5
EmployeeHut.STORE_ALL_KEY = Enum.KeyCode.F
EmployeeHut.STORE_ALL_GAMEPAD_KEY = Enum.KeyCode.ButtonY

-- Below this, "all" is just the one the E prompt already stores
EmployeeHut.STORE_ALL_MIN_AMOUNT = 2

-- Shares E with the store prompt, which is safe because it's only up while they hold nothing storable
EmployeeHut.VIEW_STORAGE_ACTION_TEXT = "View Storage"

-- The PlayerGui panel the View Storage prompt opens
EmployeeHut.STORAGE_UI_NAME = "HutStorageUI"

-- The attachment under a repaired hut's Hitbox the Worker Hut prompt hangs off, set apart from the storage ones
EmployeeHut.WORKER_ATTACHMENT = "WorkerAttachment"

-- On E like the others: it hangs far enough from them that OnePerButton showing only the nearer never hides the one meant
EmployeeHut.WORKER_PROMPT_ACTION_TEXT = "Open Worker Hut"
EmployeeHut.WORKER_PROMPT_HOLD_DURATION = 0
EmployeeHut.WORKER_PROMPT_MAX_DISTANCE = 12

-- The PlayerGui panel the Worker Hut prompt opens, where slots are bought and workers equipped
EmployeeHut.SLOTS_UI_NAME = "HutUI"

-- What each slot costs, by slot number. Slot 1 comes with the repair; the length is how many slots there are
EmployeeHut.SLOT_PRICES = { 0, 50_000, 100_000 }

table.freeze(EmployeeHut.SLOT_PRICES)

-- Robux dev product per slot, keyed by the slot it's sold on. Each only sets the price: a receipt grants whichever slot is next
EmployeeHut.SLOT_PRODUCT_IDS = { [2] = 3712388056, [3] = 3712388074 }

table.freeze(EmployeeHut.SLOT_PRODUCT_IDS)

-- The plot the hut stands on: nothing is offered on it until that plot is bought
EmployeeHut.REQUIRED_PLOT = "1"

-- The cell the hut sits on, in the base's own lattice -- both states are posed off it, so the repair swaps
-- the model without moving it. Quarter-turns, as everything placed uses (see GridUtil.RotateFootprint)
EmployeeHut.CELL_X = -20
EmployeeHut.CELL_Z = 14
EmployeeHut.CELL_ROTATION = 3

-- What repairing it costs. Sits between the first plot (5k) and the second (50k) -- it's the next thing bought after making room for it
EmployeeHut.REPAIR_COST = 25_000

-- How long the repair takes once bought. Stamped absolute, so it runs down while they're offline
EmployeeHut.REPAIR_DURATION = 5 --20 * 60

-- The base-model attribute the repair's deadline is published under, so the server write and the client read can't drift. Nil while nothing is running
EmployeeHut.REPAIR_ENDS_ATTRIBUTE = "HutRepairEndsAt"

-- The Assets.UI billboard shown over a hut being repaired, and how its title animates
EmployeeHut.REPAIRING_UI = "RepairingUI"
EmployeeHut.REPAIRING_TITLE = "Repairing"
EmployeeHut.REPAIRING_MAX_DOTS = 3
EmployeeHut.REPAIRING_DOT_INTERVAL = 0.4

-- The builder working a hut while its repair runs. Resolved by name off ServerStorage, so only the server ever sees him
EmployeeHut.BUILDER_MODEL = "Builder"

-- How far clear of the hut's edge he circles it, and how far around that ring one leg of a lap takes him
EmployeeHut.BUILDER_CLEARANCE = 3
EmployeeHut.BUILDER_LAP_STEP = math.pi / 4

-- The odds a leg ends in a bout of work rather than walking straight on, which is what makes it every now and then
EmployeeHut.BUILDER_WORK_CHANCE = 0.5

-- Swings to a bout, so a stop reads as a spell of work rather than a single tap
EmployeeHut.BUILDER_SWINGS_MIN = 1
EmployeeHut.BUILDER_SWINGS_MAX = 3

-- The beat he holds after the last swing, or he snaps out of it straight into the next leg
EmployeeHut.BUILDER_SWING_PAUSE = 0.5

EmployeeHut.BUILDER_FADE_DURATION = 0.4

-- The flash on the plot the hut stands on, fed to HighlightPulse so the refusal points at the plot to buy
EmployeeHut.PLOT_PULSE_COLOR = Color3.fromRGB(255, 205, 65)
EmployeeHut.PLOT_PULSE_START_TRANSPARENCY = 0.35
EmployeeHut.PLOT_PULSE_DURATION = 2
EmployeeHut.PLOT_PULSE_COUNT = 3

-- The PlayerGui panel the prompt opens, where the repair is actually bought
EmployeeHut.UI_NAME = "RepairHutUI"

-- The prompt only opens the panel, so it answers on the press -- a hold belongs on the button that spends
EmployeeHut.PROMPT_ACTION_TEXT = "View"
EmployeeHut.PROMPT_HOLD_DURATION = 0
EmployeeHut.PROMPT_MAX_DISTANCE = 12

-- Resolved rather than indexed: this is required on the client too, so a rename in the place file must warn rather than error the config on both sides. The repaired one is left to the Structures back-fill, which owns every structure model.
local hutsFolder = Assets.Structures:FindFirstChild(EmployeeHut.CATEGORY)
EmployeeHut.BROKEN_MODEL = hutsFolder and hutsFolder:FindFirstChild("BrokenHut")

if not EmployeeHut.BROKEN_MODEL then
	warn(`Assets.Structures.{EmployeeHut.CATEGORY}.BrokenHut is missing, no base will show a broken hut`)
end

-- Whether `slot` is among the player's `unlocked` slots. Slots unlock in order, so the count is the whole of it.
function EmployeeHut.IsSlotUnlocked(slot: number, unlocked: number): boolean
	return slot <= unlocked
end

-- The Products id for one slot, built in one place so the config and the prompt can't drift.
function EmployeeHut.GetSlotProductStringId(slot: number): string
	return `HutSlot_{slot}`
end

return EmployeeHut
