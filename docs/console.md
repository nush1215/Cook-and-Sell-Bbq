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
`OnPreferredInputChanged` when it changes. Anything that picks controls reads it rather than `TouchEnabled`, and
swaps live when the player changes device: `IsGamepad()`, `IsTouch()`, and `IsCursorless()` for "touch or pad".
Roblox's own touch controls follow the same property, and the on-screen Place and Rotate buttons hang off its jump
button, so they show exactly when the thumbstick does.

Roblox switches to Gamepad or KeyboardAndMouse on the first input from one, but back to Touch only on a tap in the
3D world at least ten seconds after the last keyboard, mouse or pad input. Taps are judged by
`WasLastInputTouch()` instead: a tap never places a structure (the Place button does), and in that window the
pickup hammer takes what was tapped rather than the middle of the screen. `GlobalUtil.IsTouchOnly()` is left to
layouts sized to a phone (the HUD's top offset, the hotbar's slot count), which shouldn't move when a phone player
picks up a pad.

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
as the reticle. The `PCGuide` hint follows the ghost instead of the cursor, and each entry's `Icon` swaps from the
PC art to the game's own R2 / L2 art (set in `BuildController`, not Roblox's per-controller glyphs).

## Customers

`NpcBillboard` keeps every answerable offer and, on a pad, targets the customer nearest the middle of the
screen each frame, drawing the D-pad glyphs on that customer's Accept and Decline only. Turning the camera
moves the target. Sell and custom-order customers both register through it. A hidden button (the tutorial
hides Decline on its one offer; an employee seller hides the whole row) can't be pressed from the pad either.

## Studio prerequisites

- `StarterGui.VirtualCursorMode = Enabled` — without it View can't summon the cursor, and the HUD buttons
  are unreachable with no menu up.
- `BuildingUI.PCGuide.Place` and `.Rotate` each need an image named `Icon`, whose image the code sets per device
  (it warns once if one is missing). Their `Action` labels are Studio's and the code never touches them.
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
