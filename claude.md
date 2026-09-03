# Project Conventions

## Networking
- All network code (`Network.Event` / `Network.Function`, `:FireServer`, `:OnServerEvent`, `:OnInvoke`, etc.) lives in **controllers (client)** and **managers (server)** — never in classes or anywhere else. A class that needs the server delegates to a method on its owning controller/manager.
- Keep event handlers thin: an `:OnServerEvent` / `:OnInvoke` callback should just delegate to a named manager/controller method, not hold logic inline.

## Modularity
- Don't spin up a new controller/manager/module just because some behavior is a distinct piece of logic. If the logic has no networking and is only used by one class, put it on that class as a method. Controllers (client) and managers (server) earn their place by owning network code or cross-cutting systems shared across many callers — not by wrapping self-contained logic that belongs to a single owner.
- Before adding a new method to a manager, check whether the manager already has a function that does (or nearly does) what you need. Reuse or extend it instead of writing a duplicate.

### Requires (lazy vs top-level)
- Require modules at the **top of the file** like any other dependency
  (`local SoundController = require(Controllers.SoundController)`), grouped under a `-- Controllers` /
  `-- Managers` comment next to the other require groups.
- The **lazy require** idiom — a forward-declared `local X` at the top plus `X = X or require(...)`
  deferred into a method/function so it only requires on first use — exists **only to break a genuine
  circular dependency** (two modules that require each other at load time). The canonical case is a
  `Base` class and its owning controller: `BaseController` requires `Base`, and `Base` requires
  `BaseController` back. Use it only there.

## Debounce
- When debouncing a player action, add the debounce on the **server** too, not just the client. The client debounce avoids sending redundant requests; the server debounce is the authoritative guard against spam.

## Naming
- Prefer descriptive, reusable method names over generic ones (e.g. `CollectPlayerIncome` rather than `Collect`), since manager/controller methods tend to get reused by other systems.

## Functions
- Avoid one-off helper functions for logic that's only used once — inline it instead. Only extract to a named function if the logic is reused or complex enough that naming it genuinely aids readability.
- Add a one-line doc comment to custom functions explaining what they do. Skip this for lifecycle/event hooks (`OnServerEvent`, `Heartbeat`, etc.) — their purpose is already obvious from context.
- Comments are one line, no exceptions. If something is genuinely tricky (non-obvious algorithm, workaround, timing dependency), flag it with a short "why" note — never a multi-line explanation. If you can't say it in one line, the code needs a clearer name, not a longer comment.

## Defensive Checks
- Don't add type guards or existence checks when the context already guarantees the type or value. Trust the data you set up.
- Only add checks where there's a real failure case to guard against (e.g. a remote call that could arrive with nil data, or a player that may have left).

## Config Files
- Before creating a config, look at an existing one in the project to match its structure and style — key naming, value format, layout. Don't invent a new pattern.

## Roblox Globals
- Use Roblox globals directly instead of `game:GetService()` where they're available. `workspace` is a global — use `workspace.Thing` directly, not `game:GetService("Workspace").Thing`. Same applies to other globals like `script`, `plugin`, etc.

## Notifications
- Notification/toast text shouldn't end with a period — drop the trailing dot, it looks off in the UI.

## Code Style
- Always scan existing scripts for structure and patterns before writing new code.
- Be consistent with code style — if unsure what pattern to use, check other modules first rather than introducing a new convention.

### Reference Implementations
- When a reference implementation is provided or already exists (a sibling project, another file,
  a pattern the user points at), study it and mirror its structure and data flow — parameters,
  responsibilities, replication approach. Don't invent a new pattern or re-derive from scratch when
  a working reference is in front of you.

## Collaboration
- Ask before assuming on anything unclear.
- Correct me if I'm wrong — don't just go along with it.
- Suggest better approaches when you see one.