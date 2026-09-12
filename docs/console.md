# Console and gamepad

How the game plays on a controller, and the pieces that make it so. Everything here is client-side; nothing
about a pad crosses the wire, since every action a pad takes lands on an event the mouse already fired.

## Button map

| Button | What it does |
|---|---|
| Left stick | Walks; moves the cursor while a menu is up |
| Right stick | Camera. On a pad the camera is also the pointer, for building and for customers |
| A | Jumps; clicks whatever the cursor is on |
| B | Closes the top menu |
| X | The default ProximityPrompt key: grills, stands, boards, shops |
| Y | Prompts that share a spot with an X prompt: "Take BBQ" off a grill, "Open Worker Hut" |
| R2 | Uses the equipped tool: places a structure, arms and takes with the pickup hammer, opens a crate |
| L2 | Rotates the structure being placed |
| L1 / R1 | Cycles the hotbar (Satchel) |
| D-pad Up | Highlights the topbar icons (TopbarPlus) |
| D-pad Right / Left | Accepts / declines the customer being looked at |
| View (Select) | Summons the system cursor, for the HUD buttons when no menu is up |
| Menu (Start) | The Roblox menu |

`InputController` owns which device the player is on (`UserInputService.PreferredInput`) and fires
`OnPreferredInputChanged` when it changes. Anything device-specific reads it rather than `TouchEnabled`; the
touch-only paths a phone still needs (the on-screen Place and Rotate buttons, the hidden build hint) keep
`TouchEnabled`, and `InputController:IsCursorless()` is the "touch or pad" question.

## Menus

Cursor-first: `UIController:OpenFrame` keeps a stack of every frame it has opened and, on a pad, puts the
gamepad cursor over the newest one. B closes the top of the stack. The cursor comes down when the stack
empties, unless the player summoned it themselves with View. Frames tagged `PassiveFrame` (the tutorial
banner) skip the stack: no cursor, and B leaves them alone.

While a menu is up the left stick moves the cursor, not the character. The zone shops open on walking in, so
on a pad the player closes them with B before walking on, and walks out and back in to reopen — the same as
pressing Exit inside the zone.

Every button goes through `UIController:BindButtonClick`, and the cursor fires the same mouse events a real
one does, so nothing per-button was needed beyond the press spring releasing on A.

## Building

A pad aims the ghost the way a phone does: off the camera, clamped near the player, dropped straight down
(`BuildController:_getAimRay`). The pickup hammer aims from the middle of the screen, with the hover outline
as the reticle. The `PCGuide` hint follows the ghost instead of the cursor and shows the R2 / L2 glyphs over
its authored key labels.

## Customers

`NpcBillboard` keeps every answerable offer and, on a pad, targets the customer nearest the middle of the
screen each frame, drawing the D-pad glyphs on that customer's Accept and Decline only. Turning the camera
moves the target. Sell and custom-order customers both register through it. A hidden button (the tutorial
hides Decline on its one offer; an employee seller hides the whole row) can't be pressed from the pad either.

## Studio prerequisites

- `StarterGui.VirtualCursorMode = Enabled` — without it View can't summon the cursor, and the HUD buttons
  are unreachable with no menu up.
- `BuildingUI.PCGuide.Place` and `.Rotate` each need a child named `Key` holding the key label; the code
  warns once and skips the glyph if it's missing.
- If selene flags `Enum.PreferredInput`, regenerate the Roblox std (`selene generate-roblox-std`).

## Known limits

- The D-pad answer is sunk while the Satchel inventory panel is open (it sinks all pad input at default
  priority); close it first.
- No rumble and no 10-foot scaling yet. Rumble would hook `HapticEffect` presets into the existing sound,
  notification and camera-shake points; scaling needs a base-scale multiplier in `OpenFrame`'s spring and a
  UIScale per HUD region, tuned in the Xbox emulator.
- Menu buttons aren't D-pad navigable (`SelectionGroup`); the cursor is the only pointer.
- The dormant sauce dispenser's bottle is a ClickDetector and will need a prompt or binding for pads when it
  comes back.
