# Network

`src/Shared/Network.luau` — a custom, fully-typed networking layer for client ↔ server messaging.

A high-performance messaging layer: per-frame batching, 1–2 byte identifier compression, a single
RemoteEvent per direction, and recycled-thread dispatch.

- `UnreliableRemoteEvent` support via a per-event flag.
- Optimized multi-argument fires (arity-aware encoding; single-value fires avoid any wrapper allocation).
- Typed generics for `Fire*` / `On*Event` / `Invoke` / `OnInvoke`.
- Client → server request/response (`Function`).
- Per-event inbound/outbound middleware and server-side rate limiting.
- Hardened server inbound: defensive payload decode, per-player flood caps, per-event direction locks,
  and optional argument validators.

All remote instances live under `ReplicatedStorage.NetworkRemotes`.

## Usage

```lua
local Network = require(ReplicatedStorage.Shared.Network)
```

### 1) Define remotes once, with the same name on client and server

`Event` is fire-and-forget; `Function` is request/response (the client yields until the server replies).

```lua
local SetSlot = Network.Event("SetSlot") :: Network.Event<number, CFrame>
local TransformSync = Network.Event("TransformSync", { Unreliable = true }) :: Network.Event<CFrame>
local GetData = Network.Function("GetData") :: Network.Function<{ any }, string>
```

### 2) Client → Server

```lua
SetSlot:FireServer(slotIndex, cf)
TransformSync:FireServer(cameraCFrame) -- unreliable/best-effort stream
local coins = GetData:Invoke("coins")  -- throws on timeout or server error
```

### 3) Server receives Client → Server events

```lua
SetSlot:OnServerEvent(function(player, slotIndex, cf)
    print(player.Name, slotIndex, cf)
end)
```

### 4) Server → Client

```lua
SetSlot:FireClient(player, slotIndex, cf)               -- single player
SetSlot:FireClients(players, slotIndex, cf)             -- specific list
SetSlot:FireAllClients(slotIndex, cf)                   -- everyone
SetSlot:FireAllClientsExcept({ player }, slotIndex, cf) -- everyone except list
```

### 5) Client receives Server → Client events

```lua
SetSlot:OnClientEvent(function(slotIndex, cf) end)
```

### 6) Server handles Function invokes

```lua
GetData:OnInvoke(function(player, key)
    return PlayerStore[player][key]
end)
```

### 7) Convenience helpers (either side, depends on context)

```lua
local onceConnection = SetSlot:Once(function(...) end)
local slotIndex, cf = SetSlot:Wait() -- yields for next event fire
onceConnection:Disconnect()
```

### 8) Optional security/rules (server)

```lua
local Move = Network.Event("Move", {
    Direction = "ClientToServer",
    RateLimit = { MaxPerSecond = 30 },
    Validate = function(player, x, y, z)
        return typeof(x) == "number" and typeof(y) == "number" and typeof(z) == "number"
    end,
})
```

## Naming

Event and function names must be **attribute-safe** (letters, digits, underscores), because the
identifier table replicates through Folder attributes.

## Serialization caveats

Roblox remote limitations; they apply to the **values** you pass:

- **Don't pass a mixed table** — one with both a `1..n` array part *and* string keys. Roblox silently
  drops the string keys in transit. Pass a pure array or a pure dictionary.
- **Avoid interior/leading nils** in a multi-arg fire, e.g. `Fire(a, nil, b)`. Args are packed
  positionally and sparse arrays don't round-trip reliably. Trailing nils are fine.

## Argument packing

`packArgs` encodes a fire's arguments into a single wire payload, minimising allocations:

| Arity | Payload |
|---|---|
| 0 args | shared frozen sentinel (no allocation) |
| 1 arg | the raw value (no wrapper allocation; the common fast path) |
| ≥2 args | a dictionary wrapper `{ [PACK_KEY] = n, [PACK_VALUES] = { v1, ..., vn } }` |

The wrapper is a **pure dictionary** (string keys only) holding the values in a nested array. This
matters because Roblox RemoteEvent serialization silently drops the string keys of a *mixed* table.
Storing the count as a string key alongside the array values would lose it in transit, so the client
would receive the bare values array as a single argument.

The rare arity-1 cases that would be ambiguous on decode (`nil`, or a table that itself carries
`PACK_KEY`) are wrapped so they still round-trip exactly.

## Hardening notes

- **Defensive decode.** A hostile client can hand-craft a payload whose `PACK_KEY` (`"@n"`) is
  non-integer or absurdly large, which would make `unpackArgs` error inside a non-isolated loop. Such
  payloads are dropped instead. The same applies to a forged `{ [PACK_KEY] = n }` with no valid values
  array.
- **Per-frame inbound budget.** Both remotes feed the same per-player packet queue; the budget bounds
  memory and CPU so a single client can't flood the queue before `PostSimulation` drains it.
- **Dispatch list cloning.** `spawnCallback` runs callbacks synchronously, so a listener that
  disconnects a sibling mid-fire (`Once`/`Wait`, or any self-removing handler) would shift the live
  array and skip the next listener. The list is cloned only when there's more than one listener, which
  fixes that without allocating on the common single-listener path.
