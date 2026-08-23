--!strict
-- Network.luau
-- A custom, fully-typed networking layer for client <-> server messaging.
--
-- A high-performance messaging layer: per-frame batching, 1-2 byte identifier compression,
-- a single RemoteEvent per direction, and recycled-thread dispatch. Features:
--   * UnreliableRemoteEvent support via a per-event flag.
--   * Optimized multi-argument fires (arity-aware encoding; single-value fires avoid any
--     wrapper allocation).
--   * Typed generics for Fire*/On*Event/Invoke/OnInvoke.
--   * Client -> server request/response (Function).
--   * Per-event inbound/outbound middleware and server-side rate limiting.
--   * Hardened server inbound: defensive payload decode, per-player flood caps,
--     per-event direction locks, and optional argument validators.
--
-- All remote instances live under ReplicatedStorage.NetworkRemotes.
--
-- USAGE
--   local Network = require(ReplicatedStorage.Shared.Network)
--
--   -- 1) Define remotes once with the same name on client and server.
--   --    Event = fire-and-forget messages.
--   --    Function = request/response (client yields until server replies).
--   local SetSlot = Network.Event("SetSlot") :: Network.Event<number, CFrame>
--   local TransformSync = Network.Event("TransformSync", { Unreliable = true }) :: Network.Event<CFrame>
--   local GetData = Network.Function("GetData") :: Network.Function<{ any }, string>
--
--   -- 2) Client -> Server
--   SetSlot:FireServer(slotIndex, cf)
--   TransformSync:FireServer(cameraCFrame) -- unreliable/best-effort stream
--   local coins = GetData:Invoke("coins") -- throws on timeout or server error
--
--   -- 3) Server receives Client -> Server events
--   SetSlot:OnServerEvent(function(player, slotIndex, cf)
--       print(player.Name, slotIndex, cf)
--   end)
--
--   -- 4) Server -> Client
--   SetSlot:FireClient(player, slotIndex, cf) -- single player
--   SetSlot:FireClients(players, slotIndex, cf) -- specific list
--   SetSlot:FireAllClients(slotIndex, cf) -- everyone
--   SetSlot:FireAllClientsExcept({ player }, slotIndex, cf) -- everyone except list
--
--   -- 5) Client receives Server -> Client events
--   SetSlot:OnClientEvent(function(slotIndex, cf) end)
--
--   -- 6) Server handles Function invokes
--   GetData:OnInvoke(function(player, key)
--       return PlayerStore[player][key]
--   end)
--
--   -- 7) Convenience helpers (either side, depends on context)
--   local onceConnection = SetSlot:Once(function(...) end)
--   local slotIndex, cf = SetSlot:Wait() -- yields for next event fire
--   onceConnection:Disconnect()
--
--   -- 8) Optional security/rules (server):
--   local Move = Network.Event("Move", {
--       Direction = "ClientToServer",
--       RateLimit = { MaxPerSecond = 30 },
--       Validate = function(player, x, y, z)
--           return typeof(x) == "number" and typeof(y) == "number" and typeof(z) == "number"
--       end,
--   })
--
-- NOTE: event/function names must be attribute-safe (letters, digits, underscores) because
-- the identifier table replicates through Folder attributes.
--
-- SERIALIZATION CAVEATS (Roblox remote limitations; they apply to the VALUES you pass):
--   * Don't pass a MIXED table -- one with both a 1..n array part AND string keys. Roblox
--     silently drops the string keys in transit. Pass a pure array or a pure dictionary.
--   * Avoid interior/leading nils in a multi-arg fire, e.g. Fire(a, nil, b). Args are packed
--     positionally and sparse arrays don't round-trip reliably; trailing nils are fine.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IS_SERVER = RunService:IsServer()

-- ============================================================================
-- Constants
-- ============================================================================

local IDENTIFIER_CAP = 65535 -- 2^16, matches the 1/2-byte packing scheme
local IDENTIFIER_TIMEOUT = 10 -- seconds a client waits for an identifier to replicate
local READY_FRAMES = 10 -- frames the client waits before signalling "ready" (lets handlers connect)
local READY_SIGNAL = "ready"
local UNRELIABLE_CHUNK = 60 -- max payloads per unreliable packet (best-effort size guard)
local DEFAULT_INVOKE_TIMEOUT = 10 -- seconds before an Invoke throws

-- Security defaults (server-side, always on; tune via Network.ConfigureSecurity).
local MAX_PACK_ARGS = 4096 -- reject a wire payload claiming more packed args than this
local DEFAULT_MAX_INBOUND_PER_FRAME = 512 -- per-player messages accepted per frame before drops

local PACK_KEY = "@n" -- wire-safe marker key identifying a packed multi-arg payload (also holds the arg count)
local PACK_VALUES = "@v" -- wire-safe key holding the packed values array (kept separate so the wrapper is a PURE dict)
local EMPTY_ARGS = table.freeze({ [PACK_KEY] = 0 }) -- shared zero-arg payload (no per-fire allocation)
local DROP = {} -- sentinel returned by encodeOutbound when middleware drops a fire

-- ============================================================================
-- Types
-- ============================================================================

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

-- Middleware receives the (packed) args table (args.n = count). Return false to drop the
-- message; optionally return a replacement packed args table to transform it.
export type Middleware = (player: Player?, args: { any }) -> (boolean, { any }?)

export type RateLimitConfig = {
	MaxPerSecond: number,
	OnExceeded: ((player: Player) -> ())?,
}

-- Restricts which way an event may legitimately travel. The server drops any inbound
-- traffic on a "ServerToClient" event, and the client refuses to FireServer on one;
-- "ClientToServer" likewise refuses a server-side FireClient*.
export type NetworkDirection = "ServerToClient" | "ClientToServer"

export type EventConfig = {
	Unreliable: boolean?, -- route over an UnreliableRemoteEvent (best-effort, drop-tolerant)
	RateLimit: RateLimitConfig?, -- server-side, per-player inbound limit
	Direction: NetworkDirection?, -- restrict legitimate travel direction (server-enforced)
	Validate: ((player: Player?, ...any) -> boolean)?, -- server inbound: return false to drop
	InboundMiddleware: { Middleware }?,
	OutboundMiddleware: { Middleware }?,
}

-- Global server-side security knobs. OnViolation fires (at most once per player per frame)
-- when inbound traffic is dropped for flooding, a malformed payload, a direction lock, or a
-- failed validator. reason is one of: "flood" | "malformed" | "direction" | "validate".
export type SecurityConfig = {
	MaxInboundPerFrame: number?,
	OnViolation: ((player: Player, reason: string) -> ())?,
}

export type FunctionConfig = {
	Timeout: number?,
	InboundMiddleware: { Middleware }?,
}

export type Event<T...> = {
	-- client -> server
	FireServer: (self: Event<T...>, T...) -> (),
	OnClientEvent: (self: Event<T...>, callback: (T...) -> ()) -> Connection,
	-- server -> client
	FireClient: (self: Event<T...>, player: Player, T...) -> (),
	FireClients: (self: Event<T...>, players: { Player }, T...) -> (),
	FireAllClients: (self: Event<T...>, T...) -> (),
	FireAllClientsExcept: (self: Event<T...>, except: { Player }, T...) -> (),
	OnServerEvent: (self: Event<T...>, callback: (player: Player, T...) -> ()) -> Connection,
	-- both sides (loosely typed convenience)
	Once: (self: Event<T...>, callback: (...any) -> ()) -> Connection,
	Wait: (self: Event<T...>) -> ...any,
}

export type Function<R, A...> = {
	Invoke: (self: Function<R, A...>, A...) -> R, -- client; yields, throws on timeout/error
	OnInvoke: (self: Function<R, A...>, handler: (player: Player, A...) -> R) -> (), -- server
}

-- ============================================================================
-- Recycled-thread spawner (avoids allocating a thread per dispatched callback)
-- ============================================================================

local freeThreads: { thread } = {}

local function runCallback(callback, thread, ...)
	callback(...)
	table.insert(freeThreads, thread)
end

local function yielder()
	while true do
		runCallback(coroutine.yield())
	end
end

local function spawnCallback<T...>(callback: (T...) -> (), ...: T...)
	local thread: thread
	local count = #freeThreads
	if count > 0 then
		thread = freeThreads[count]
		freeThreads[count] = nil
	else
		thread = coroutine.create(yielder)
		coroutine.resume(thread)
	end
	task.spawn(thread, callback, thread, ...)
end

-- ============================================================================
-- Argument packing (the multi-arg optimization)
-- ============================================================================

-- Encodes a fire's arguments into a single wire payload, minimising allocations:
--   * 0 args  -> shared frozen sentinel (no allocation)
--   * 1 arg   -> the raw value (no wrapper allocation; the common fast path)
--   * >=2 args -> a dictionary wrapper { [PACK_KEY] = n, [PACK_VALUES] = { v1, ..., vn } }
-- The wrapper is a PURE DICTIONARY (string keys only) holding the values in a nested array.
-- This matters because Roblox RemoteEvent serialization silently drops the string keys of a
-- MIXED table (one with both a 1..n array part and string keys). Storing the count as a string
-- key alongside the array values would lose it in transit, so the client would receive the bare
-- values array as a single argument.
-- The rare arity-1 cases that would be ambiguous on decode (nil, or a table that itself
-- carries PACK_KEY) are wrapped so they still round-trip exactly.
local function pack(...): any
	local n = select("#", ...)
	if n == 0 then
		return EMPTY_ARGS
	elseif n == 1 then
		local value = ...
		if value == nil then
			return { [PACK_KEY] = 1, [PACK_VALUES] = {} } -- a single, explicit nil argument
		end
		if type(value) == "table" and (value :: any)[PACK_KEY] ~= nil then
			return { [PACK_KEY] = 1, [PACK_VALUES] = { value } } -- defuse a user table that carries PACK_KEY
		end
		return value
	end

	local values = table.pack(...)
	values.n = nil -- keep the nested values a clean array; the count lives under PACK_KEY
	return { [PACK_KEY] = n, [PACK_VALUES] = values }
end

-- Decodes a wire payload back into the original argument tuple.
local function unpackArgs(payload: any): ...any
	if type(payload) == "table" then
		local n = (payload :: any)[PACK_KEY]
		if n ~= nil then
			if n == 0 then
				return
			end
			return table.unpack((payload :: any)[PACK_VALUES], 1, n)
		end
	end
	return payload
end

-- ============================================================================
-- Middleware
-- ============================================================================

local function runMiddleware(list: { Middleware }, player: Player?, args: { any }): (boolean, { any }?)
	local current = args
	for _, middleware in list do
		local allowed, replaced = middleware(player, current)
		if not allowed then
			return false
		end
		if replaced then
			current = replaced
		end
	end
	return true, current
end

-- Applies outbound middleware (if any) then packs. Returns DROP if a middleware rejected.
local function encodeOutbound(self: any, ...): any
	local middleware = self.OutboundMiddleware
	if middleware then
		local args = table.pack(...)
		local allowed, replaced = runMiddleware(middleware, nil, args)
		if not allowed then
			return DROP
		end
		local final = replaced or args
		return pack(table.unpack(final, 1, (final :: any).n or #final))
	end
	return pack(...)
end

-- ============================================================================
-- Shared state
-- ============================================================================

-- callbacksById holds the listener list for every identifier (user events AND the internal
-- request/response channels of Functions). eventsById only holds user-event metadata so the
-- middleware / rate-limit paths can be skipped entirely when unconfigured.
local callbacksById: { [string]: { (...any) -> () } } = {}
local eventsById: { [string]: any } = {}

local identifierFolder: Folder
local refIdentifier: (name: string) -> string

local function makeConnection(list: { (...any) -> () }, callback: (...any) -> ()): Connection
	return {
		Disconnect = function()
			local index = table.find(list, callback)
			if index then
				table.remove(list, index)
			end
		end,
	}
end

-- Returns a stable list to iterate while dispatching. spawnCallback runs callbacks synchronously,
-- so a listener that disconnects a sibling mid-fire (Once/Wait, or any self-removing handler)
-- would shift the live array and skip the next listener. Cloning only when there's more than one
-- listener fixes that without allocating on the common single-listener path.
local function snapshot<T>(list: { T }): { T }
	return if #list > 1 then table.clone(list) else list
end

-- Forward declarations for the per-side outbound queues (referenced by the method tables).
local reliableOutbound: { any } = {}
local unreliableOutbound: { any } = {}

local reliableRemote: RemoteEvent
local unreliableRemote: UnreliableRemoteEvent
local metaRemote: RemoteEvent

-- These are populated inside the IS_SERVER branch below.
local createEvent: (name: string, config: EventConfig?) -> Event<...any>
local createFunction: (name: string, config: FunctionConfig?) -> Function<any, ...any>
local configureSecurity: (config: SecurityConfig) -> ()

if IS_SERVER then
	-- ========================================================================
	-- Server runtime
	-- ========================================================================

	-- Remote instances (created once, replicate to clients together).
	local folder = ReplicatedStorage:FindFirstChild("NetworkRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "NetworkRemotes"

		reliableRemote = Instance.new("RemoteEvent")
		reliableRemote.Name = "Reliable"
		reliableRemote.Parent = folder

		unreliableRemote = Instance.new("UnreliableRemoteEvent")
		unreliableRemote.Name = "Unreliable"
		unreliableRemote.Parent = folder

		metaRemote = Instance.new("RemoteEvent")
		metaRemote.Name = "Meta"
		metaRemote.Parent = folder

		identifierFolder = Instance.new("Folder")
		identifierFolder.Name = "Identifiers"
		identifierFolder.Parent = folder

		folder.Parent = ReplicatedStorage
	else
		reliableRemote = folder:WaitForChild("Reliable") :: RemoteEvent
		unreliableRemote = folder:WaitForChild("Unreliable") :: UnreliableRemoteEvent
		metaRemote = folder:WaitForChild("Meta") :: RemoteEvent
		identifierFolder = folder:WaitForChild("Identifiers") :: Folder
	end

	-- Identifier registry: assign incrementing ids, pack to 1 byte (<256) or 2 bytes, publish
	-- as Folder attributes for clients to read.
	local identifierCount = 0
	local nameToId: { [string]: string } = {}

	refIdentifier = function(name: string): string
		local cached = nameToId[name]
		if cached then
			return cached
		end
		assert(identifierCount <= IDENTIFIER_CAP, "[Network] identifier cap reached")
		local packed = if identifierCount <= 255
			then string.pack("B", identifierCount)
			else string.pack("H", identifierCount)
		identifierCount += 1
		nameToId[name] = packed
		identifierFolder:SetAttribute(name, packed)
		return packed
	end

	-- Security state (per-frame inbound budget + violation reporting).
	local security = {
		MaxInboundPerFrame = DEFAULT_MAX_INBOUND_PER_FRAME,
		OnViolation = nil :: ((player: Player, reason: string) -> ())?,
	}
	local inboundCount: { [Player]: number } = {} -- messages accepted this frame, per player
	local violatedThisFrame: { [Player]: true } = {} -- debounce: one OnViolation per player per frame

	configureSecurity = function(config: SecurityConfig)
		if config.MaxInboundPerFrame ~= nil then
			security.MaxInboundPerFrame = config.MaxInboundPerFrame
		end
		if config.OnViolation ~= nil then
			security.OnViolation = config.OnViolation
		end
	end

	local function flagViolation(player: Player, reason: string)
		if violatedThisFrame[player] then
			return
		end
		violatedThisFrame[player] = true
		local hook = security.OnViolation
		if hook then
			spawnCallback(hook, player, reason)
		end
	end

	-- Per-player bookkeeping.
	local playerSet: { [Player]: true } = {}
	local playerLoading: { [Player]: true } = {}
	local loadingQueue: { [Player]: { [string]: { any } } } = {}
	local serverInbound: { [Player]: { { any } } } = {}

	local function addPlayer(player: Player)
		playerSet[player] = true
		playerLoading[player] = true
		loadingQueue[player] = {}
		serverInbound[player] = {}
	end

	local function removePlayer(player: Player)
		playerSet[player] = nil
		playerLoading[player] = nil
		loadingQueue[player] = nil
		serverInbound[player] = nil
		inboundCount[player] = nil
		violatedThisFrame[player] = nil
		for _, impl in eventsById do
			if impl.RateState then
				impl.RateState[player] = nil
			end
		end
	end

	for _, player in Players:GetPlayers() do
		addPlayer(player)
	end
	Players.PlayerAdded:Connect(addPlayer)
	Players.PlayerRemoving:Connect(removePlayer)

	-- Outbound queue entry helper.
	local function enqueue(queue: { any }, kind: string, value: any, id: string, payload: any)
		table.insert(queue, { Kind = kind, Value = value, Id = id, Payload = payload })
	end

	-- Groups a frame's outbound entries into { [player] = { [id] = { payloads } } }.
	local function buildSendStructure(queue: { any }): { [Player]: { [string]: { any } } }
		local structure: { [Player]: { [string]: { any } } } = {}

		local function add(player: Player, id: string, payload: any)
			local perPlayer = structure[player]
			if not perPlayer then
				structure[player] = { [id] = { payload } }
			else
				local list = perPlayer[id]
				if list then
					table.insert(list, payload)
				else
					perPlayer[id] = { payload }
				end
			end
		end

		for _, entry in queue do
			local kind = entry.Kind
			if kind == "single" then
				add(entry.Value, entry.Id, entry.Payload)
			elseif kind == "all" then
				for player in playerSet do
					add(player, entry.Id, entry.Payload)
				end
			elseif kind == "set" then
				for _, player in entry.Value do
					add(player, entry.Id, entry.Payload)
				end
			elseif kind == "except" then
				local except = entry.Value
				for player in playerSet do
					if not table.find(except, player) then
						add(player, entry.Id, entry.Payload)
					end
				end
			end
		end

		table.clear(queue)
		return structure
	end

	-- Merges a player's reliable batch into their loading queue (player not ready yet).
	local function mergeInto(destination: { [string]: { any } }, source: { [string]: { any } })
		for id, payloads in source do
			local existing = destination[id]
			if existing then
				for _, payload in payloads do
					table.insert(existing, payload)
				end
			else
				destination[id] = payloads
			end
		end
	end

	-- Sends a player's unreliable batch, splitting into multiple packets to stay under the
	-- UnreliableRemoteEvent size limit (best-effort, by payload count).
	local function fireUnreliableChunks(player: Player, dict: { [string]: { any } })
		local chunk: { [string]: { any } } = {}
		local count = 0
		for id, payloads in dict do
			chunk[id] = payloads
			count += #payloads
			if count >= UNRELIABLE_CHUNK then
				unreliableRemote:FireClient(player, chunk)
				chunk = {}
				count = 0
			end
		end
		if next(chunk) then
			unreliableRemote:FireClient(player, chunk)
		end
	end

	-- Rate limit check (returns true if the message is allowed).
	local function checkRate(impl: any, player: Player): boolean
		local config = impl.RateLimit
		local state = impl.RateState[player]
		local now = os.clock()
		if not state or now - state.sec >= 1 then
			impl.RateState[player] = { sec = now, count = 1 }
			return true
		end
		state.count += 1
		if state.count > config.MaxPerSecond then
			if config.OnExceeded then
				spawnCallback(config.OnExceeded, player)
			end
			return false
		end
		return true
	end

	local function dispatchServer(player: Player, id: string, payload: any)
		local callbacks = callbacksById[id]
		if not callbacks then
			return
		end

		-- Defensive decode: a hostile client can hand-craft a payload whose PACK_KEY ("@n")
		-- is non-integer or absurdly large, which would make unpackArgs error inside this
		-- (non-isolated) loop. Drop it instead.
		if type(payload) == "table" then
			local n = (payload :: any)[PACK_KEY]
			if n ~= nil then
				if type(n) ~= "number" or n ~= n // 1 or n < 0 or n > MAX_PACK_ARGS then
					flagViolation(player, "malformed")
					return
				end
				-- A forged { [PACK_KEY] = n } without a valid values array would make unpackArgs
				-- error inside this non-isolated loop; drop it instead.
				if n > 0 and type((payload :: any)[PACK_VALUES]) ~= "table" then
					flagViolation(player, "malformed")
					return
				end
			end
		end

		local impl = eventsById[id]
		if impl then
			if impl.Direction == "ServerToClient" then
				flagViolation(player, "direction")
				return
			end
			if impl.RateLimit and not checkRate(impl, player) then
				return
			end
			if impl.Validate or impl.InboundMiddleware then
				local args = table.pack(unpackArgs(payload))
				if impl.Validate and not impl.Validate(player, table.unpack(args, 1, args.n)) then
					flagViolation(player, "validate")
					return
				end
				if impl.InboundMiddleware then
					local allowed, replaced = runMiddleware(impl.InboundMiddleware, player, args)
					if not allowed then
						return
					end
					args = replaced or args
				end
				for _, callback in snapshot(callbacks) do
					spawnCallback(callback, player, table.unpack(args, 1, (args :: any).n or #args))
				end
				return
			end
		end

		for _, callback in snapshot(callbacks) do
			spawnCallback(callback, player, unpackArgs(payload))
		end
	end

	local function processServerInbound()
		for player, packets in serverInbound do
			for _, packet in packets do
				for i = 1, #packet, 2 do
					local payload = packet[i]
					local id = packet[i + 1]
					if type(id) == "string" then
						dispatchServer(player, id, payload)
					end
				end
			end
			serverInbound[player] = {}
		end
	end

	-- Inbound: both remotes feed the same per-player packet queue. A per-frame budget bounds
	-- memory/CPU so a single client can't flood the queue before PostSimulation drains it.
	local function receivePacket(player: Player, packet: any)
		if type(packet) ~= "table" then
			return
		end
		local queue = serverInbound[player]
		if not queue then
			return
		end
		local messages = #packet // 2 -- packets are flat (payload, id) pairs
		local count = inboundCount[player] or 0
		if count + messages > security.MaxInboundPerFrame then
			flagViolation(player, "flood")
			return
		end
		inboundCount[player] = count + messages
		table.insert(queue, packet)
	end

	reliableRemote.OnServerEvent:Connect(receivePacket)
	unreliableRemote.OnServerEvent:Connect(receivePacket)

	metaRemote.OnServerEvent:Connect(function(player, signal)
		if signal == READY_SIGNAL and playerLoading[player] then
			playerLoading[player] = nil
			local pending = loadingQueue[player]
			loadingQueue[player] = nil
			if pending and next(pending) then
				reliableRemote:FireClient(player, pending)
			end
		end
	end)

	-- Per-frame flush.
	RunService.PostSimulation:Connect(function()
		local reliable = buildSendStructure(reliableOutbound)
		for player, dict in reliable do
			if playerLoading[player] then
				local pending = loadingQueue[player]
				if pending then
					mergeInto(pending, dict)
				end
			else
				reliableRemote:FireClient(player, dict)
			end
		end

		local unreliable = buildSendStructure(unreliableOutbound)
		for player, dict in unreliable do
			fireUnreliableChunks(player, dict)
		end

		processServerInbound()

		-- Reset per-frame inbound budgets for the next frame.
		table.clear(inboundCount)
		table.clear(violatedThisFrame)
	end)

	-- ---- Server method table ----
	local ServerMethods = {}
	ServerMethods.__index = ServerMethods

	local function assertServerMayFire(self: any)
		if self.Direction == "ClientToServer" then
			error(`[Network] '{self.Name}' is ClientToServer; the server cannot fire it to clients`, 3)
		end
	end

	function ServerMethods.FireClient(self: any, player: Player, ...)
		assertServerMayFire(self)
		local payload = encodeOutbound(self, ...)
		if payload == DROP then
			return
		end
		enqueue(self.Unreliable and unreliableOutbound or reliableOutbound, "single", player, self.Id, payload)
	end

	function ServerMethods.FireClients(self: any, players: { Player }, ...)
		assertServerMayFire(self)
		local payload = encodeOutbound(self, ...)
		if payload == DROP then
			return
		end
		enqueue(self.Unreliable and unreliableOutbound or reliableOutbound, "set", players, self.Id, payload)
	end

	function ServerMethods.FireAllClients(self: any, ...)
		assertServerMayFire(self)
		local payload = encodeOutbound(self, ...)
		if payload == DROP then
			return
		end
		enqueue(self.Unreliable and unreliableOutbound or reliableOutbound, "all", nil, self.Id, payload)
	end

	function ServerMethods.FireAllClientsExcept(self: any, except: { Player }, ...)
		assertServerMayFire(self)
		local payload = encodeOutbound(self, ...)
		if payload == DROP then
			return
		end
		enqueue(self.Unreliable and unreliableOutbound or reliableOutbound, "except", except, self.Id, payload)
	end

	function ServerMethods.OnServerEvent(self: any, callback: (...any) -> ()): Connection
		local list = callbacksById[self.Id]
		table.insert(list, callback)
		return makeConnection(list, callback)
	end

	function ServerMethods.Once(self: any, callback: (...any) -> ()): Connection
		local connection
		connection = self:OnServerEvent(function(...)
			connection:Disconnect()
			callback(...)
		end)
		return connection
	end

	function ServerMethods.Wait(self: any): ...any
		local thread = coroutine.running()
		local connection
		connection = self:OnServerEvent(function(...)
			connection:Disconnect()
			task.spawn(thread, ...)
		end)
		return coroutine.yield()
	end

	local function wrongContext(name: string)
		return function()
			error(`[Network] {name} can only be called on the client`, 2)
		end
	end
	ServerMethods.FireServer = wrongContext("FireServer")
	ServerMethods.OnClientEvent = wrongContext("OnClientEvent")

	createEvent = function(name: string, config: EventConfig?): Event<...any>
		local id = refIdentifier(name)
		if not callbacksById[id] then
			callbacksById[id] = {}
		end
		local impl = setmetatable({
			Name = name,
			Id = id,
			Unreliable = (config and config.Unreliable) or false,
			Direction = config and config.Direction,
			Validate = config and config.Validate,
			OutboundMiddleware = config and config.OutboundMiddleware,
			InboundMiddleware = config and config.InboundMiddleware,
			RateLimit = config and config.RateLimit,
			RateState = (config and config.RateLimit) and {} or nil,
		}, ServerMethods)
		eventsById[id] = impl
		return (impl :: any) :: Event<...any>
	end

	-- ---- Server Function ----
	local ServerFunctionMethods = {}
	ServerFunctionMethods.__index = ServerFunctionMethods

	function ServerFunctionMethods.OnInvoke(self: any, handler: (player: Player, ...any) -> ...any)
		self.Handler = handler
	end

	function ServerFunctionMethods.Invoke()
		error("[Network] Invoke can only be called on the client", 2)
	end

	createFunction = function(name: string, config: FunctionConfig?): Function<any, ...any>
		local reqId = refIdentifier(name .. "_NetFnReq")
		local resId = refIdentifier(name .. "_NetFnRes")
		local self = setmetatable({
			Name = name,
			Handler = nil :: ((player: Player, ...any) -> ...any)?,
			InboundMiddleware = config and config.InboundMiddleware,
		}, ServerFunctionMethods)

		if not callbacksById[reqId] then
			callbacksById[reqId] = {}
		end
		table.insert(callbacksById[reqId], function(player: Player, requestId: number, ...)
			local handler = self.Handler
			if not handler then
				return
			end
			local args = table.pack(...)
			if self.InboundMiddleware then
				local allowed, replaced = runMiddleware(self.InboundMiddleware, player, args)
				if not allowed then
					return
				end
				args = replaced or args
			end
			local results = table.pack(pcall(handler, player, table.unpack(args, 1, args.n)))
			if results[1] then
				enqueue(
					reliableOutbound,
					"single",
					player,
					resId,
					pack(requestId, true, table.unpack(results, 2, results.n))
				)
			else
				warn(`[Network] Function '{name}' handler errored: {results[2]}`)
				enqueue(reliableOutbound, "single", player, resId, pack(requestId, false, results[2]))
			end
		end)

		return (self :: any) :: Function<any, ...any>
	end
else
	-- ========================================================================
	-- Client runtime
	-- ========================================================================

	local folder = ReplicatedStorage:WaitForChild("NetworkRemotes")
	reliableRemote = folder:WaitForChild("Reliable") :: RemoteEvent
	unreliableRemote = folder:WaitForChild("Unreliable") :: UnreliableRemoteEvent
	metaRemote = folder:WaitForChild("Meta") :: RemoteEvent
	identifierFolder = folder:WaitForChild("Identifiers") :: Folder

	-- Security is enforced server-side only; expose a no-op so callers stay context-agnostic.
	configureSecurity = function() end

	-- Resolve a name to its packed id, waiting for the server to publish it if necessary.
	refIdentifier = function(name: string): string
		local packed = identifierFolder:GetAttribute(name)
		if typeof(packed) == "string" then
			return packed
		end
		local deadline = os.clock() + IDENTIFIER_TIMEOUT
		repeat
			task.wait()
			packed = identifierFolder:GetAttribute(name)
			if typeof(packed) == "string" then
				return packed
			end
		until os.clock() > deadline
		error(`[Network] identifier '{name}' did not replicate within {IDENTIFIER_TIMEOUT}s`, 0)
	end

	local clientInbound: { { [string]: { any } } } = {}

	local function dispatchClient(id: string, payloads: { any })
		local callbacks = callbacksById[id]
		if not callbacks then
			return
		end
		local impl = eventsById[id]
		local fire = snapshot(callbacks)

		for _, payload in payloads do
			if impl and impl.InboundMiddleware then
				local args = table.pack(unpackArgs(payload))
				local allowed, replaced = runMiddleware(impl.InboundMiddleware, nil, args)
				if allowed then
					local final = replaced or args
					for _, callback in fire do
						spawnCallback(callback, table.unpack(final, 1, (final :: any).n or #final))
					end
				end
			else
				for _, callback in fire do
					spawnCallback(callback, unpackArgs(payload))
				end
			end
		end
	end

	local function receiveDict(dict: any)
		if type(dict) == "table" then
			table.insert(clientInbound, dict)
		end
	end
	reliableRemote.OnClientEvent:Connect(receiveDict)
	unreliableRemote.OnClientEvent:Connect(receiveDict)

	-- Per-frame flush.
	RunService.PostSimulation:Connect(function()
		if #reliableOutbound > 0 then
			local toSend = table.clone(reliableOutbound)
			table.clear(reliableOutbound)
			reliableRemote:FireServer(toSend)
		end

		if #unreliableOutbound > 0 then
			local toSend = unreliableOutbound
			unreliableOutbound = {}
			-- chunk to stay under the unreliable packet size limit (payload+id pairs)
			local limit = UNRELIABLE_CHUNK * 2
			if #toSend <= limit then
				unreliableRemote:FireServer(toSend)
			else
				for i = 1, #toSend, limit do
					unreliableRemote:FireServer(table.move(toSend, i, math.min(i + limit - 1, #toSend), 1, {}))
				end
			end
		end

		for _, dict in clientInbound do
			for id, payloads in dict do
				dispatchClient(id, payloads)
			end
		end
		table.clear(clientInbound)
	end)

	-- Signal readiness once handlers have had a chance to connect.
	task.spawn(function()
		for _ = 1, READY_FRAMES do
			task.wait()
		end
		metaRemote:FireServer(READY_SIGNAL)
	end)

	-- ---- Client method table ----
	local ClientMethods = {}
	ClientMethods.__index = ClientMethods

	function ClientMethods.FireServer(self: any, ...)
		if self.Direction == "ServerToClient" then
			error(`[Network] '{self.Name}' is ServerToClient; the client cannot fire it to the server`, 2)
		end
		local payload = encodeOutbound(self, ...)
		if payload == DROP then
			return
		end
		local queue = self.Unreliable and unreliableOutbound or reliableOutbound
		table.insert(queue, payload)
		table.insert(queue, self.Id)
	end

	function ClientMethods.OnClientEvent(self: any, callback: (...any) -> ()): Connection
		local list = callbacksById[self.Id]
		table.insert(list, callback)
		return makeConnection(list, callback)
	end

	function ClientMethods.Once(self: any, callback: (...any) -> ()): Connection
		local connection
		connection = self:OnClientEvent(function(...)
			connection:Disconnect()
			callback(...)
		end)
		return connection
	end

	function ClientMethods.Wait(self: any): ...any
		local thread = coroutine.running()
		local connection
		connection = self:OnClientEvent(function(...)
			connection:Disconnect()
			task.spawn(thread, ...)
		end)
		return coroutine.yield()
	end

	local function wrongContext(name: string)
		return function()
			error(`[Network] {name} can only be called on the server`, 2)
		end
	end
	ClientMethods.FireClient = wrongContext("FireClient")
	ClientMethods.FireClients = wrongContext("FireClients")
	ClientMethods.FireAllClients = wrongContext("FireAllClients")
	ClientMethods.FireAllClientsExcept = wrongContext("FireAllClientsExcept")
	ClientMethods.OnServerEvent = wrongContext("OnServerEvent")

	createEvent = function(name: string, config: EventConfig?): Event<...any>
		local id = refIdentifier(name)
		if not callbacksById[id] then
			callbacksById[id] = {}
		end
		local impl = setmetatable({
			Name = name,
			Id = id,
			Unreliable = (config and config.Unreliable) or false,
			Direction = config and config.Direction,
			OutboundMiddleware = config and config.OutboundMiddleware,
			InboundMiddleware = config and config.InboundMiddleware,
		}, ClientMethods)
		eventsById[id] = impl
		return (impl :: any) :: Event<...any>
	end

	-- ---- Client Function ----
	local pendingInvokes: { [number]: thread } = {}
	local nextRequestId = 0

	local ClientFunctionMethods = {}
	ClientFunctionMethods.__index = ClientFunctionMethods

	function ClientFunctionMethods.Invoke(self: any, ...): ...any
		local requestId = nextRequestId
		nextRequestId += 1

		local thread = coroutine.running()
		pendingInvokes[requestId] = thread

		table.insert(reliableOutbound, pack(requestId, ...))
		table.insert(reliableOutbound, self.ReqId)

		task.delay(self.Timeout, function()
			if pendingInvokes[requestId] then
				pendingInvokes[requestId] = nil
				task.spawn(thread, false, "timeout")
			end
		end)

		local results = table.pack(coroutine.yield())
		if not results[1] then
			error(`[Network] Invoke '{self.Name}' failed: {tostring(results[2])}`, 0)
		end
		return table.unpack(results, 2, results.n)
	end

	function ClientFunctionMethods.OnInvoke()
		error("[Network] OnInvoke can only be called on the server", 2)
	end

	createFunction = function(name: string, config: FunctionConfig?): Function<any, ...any>
		local reqId = refIdentifier(name .. "_NetFnReq")
		local resId = refIdentifier(name .. "_NetFnRes")
		local self = setmetatable({
			Name = name,
			ReqId = reqId,
			Timeout = (config and config.Timeout) or DEFAULT_INVOKE_TIMEOUT,
		}, ClientFunctionMethods)

		if not callbacksById[resId] then
			callbacksById[resId] = {}
		end
		table.insert(callbacksById[resId], function(requestId: number, success: boolean, ...)
			local thread = pendingInvokes[requestId]
			if thread then
				pendingInvokes[requestId] = nil
				task.spawn(thread, success, ...)
			end
		end)

		return (self :: any) :: Function<any, ...any>
	end
end

-- ============================================================================
-- Public API
-- ============================================================================

local Network = {
	Event = createEvent,
	Function = createFunction,
	ConfigureSecurity = configureSecurity,
}

return Network
