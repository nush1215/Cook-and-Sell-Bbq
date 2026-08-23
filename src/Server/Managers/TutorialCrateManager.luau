-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Crates = require(Shared.Config.Crates)

-- Managers
local BaseManager
local CrateManager
local PlayerDataManager

--
local SAVE_KEY = "TutorialCrateTimer"

--[[
    The crate finishing the tutorial drops.

    It doesn't go into the backpack like every other crate -- it crashes into the player's own base,
    sits there bobbing behind a countdown, and is opened where it landed. It's a real server model, so
    everyone at the base watches it come down and watches it open; only its owner gets the prompt and
    the rewards.

    The countdown is stored as the absolute server-time it opens at, written once and never touched
    again. That's what makes it keep running while the player is offline, and what lets a rejoin
    resume it without any of the bookkeeping a ticking timer would need. -1 means none pending, and a
    stamp in the past is one that's already ready.

    Nothing here drives the countdown or the prompt: both are client-side, off the crate's own
    attributes. The server only owns the two things a client can't be trusted with -- when the crate
    may be opened, and who it pays out to.
]]

--
type CrateEntry = {
	Model: Model,
	UniqueId: string,
	Trove: any,
	SpawnedThisSession: boolean,
}

--
local TutorialCrateManager = {
	-- Tells the finishing player's client to play the crash. Only they see the fall; for everyone
	-- else the crate simply appears where it landed.
	CrashEvent = Network.Event("TutorialCrateCrash"),

	-- The owner held the Open prompt. The server validates, hands the crate over, and broadcasts the
	-- open back so every client plays the reveal rather than just the owner's screen.
	OpenEvent = Network.Event("TutorialCrateOpen"),

	-- (player, spawnedThisSession) once a player's tutorial crate is claimed. The boolean is false
	-- when they left before the countdown ended and came back for it, which is what tells us whether
	-- the wait holds players in the session or loses them.
	OnClaimed = Signal.new(),

	_active = {} :: { [Player]: CrateEntry },
	_spawning = {}, -- [player] = true while a resume is awaiting data
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- The part on a player's base the crate lands on, or nil if they have no base in the world (or it
-- was never given one). Resolved off the BaseId attribute rather than the Base object, which is how
-- everything else in the game finds a player's base parts.
local function getSpawnPart(player: Player): BasePart?
	local baseId = player:GetAttribute("BaseId")
	if not baseId then
		return nil
	end

	local baseModel = workspace.Base:FindFirstChild(baseId)
	local core = baseModel and baseModel:FindFirstChild("Core")
	local spawnPart = core and core:FindFirstChild(Crates.METEOR_SPAWN_PART)

	if not (spawnPart and spawnPart:IsA("BasePart")) then
		return nil
	end

	-- The crate lands on this part's world position, so a copy pasted from another base -- which keeps
	-- the position it was copied from however it's reparented -- drops every crate onto whichever base
	-- it came off. Nothing in game says so; you'd have to be standing on two bases at once to notice.
	local basePivot, baseSize = baseModel:GetBoundingBox()
	local localPosition = basePivot:PointToObjectSpace(spawnPart.Position)

	if math.abs(localPosition.X) > baseSize.X / 2 or math.abs(localPosition.Z) > baseSize.Z / 2 then
		warn(
			`[TutorialCrate] Base {baseId}'s {Crates.METEOR_SPAWN_PART} sits outside the base it's parented `
				.. `under -- it was almost certainly copied from another base and never moved, so this crate `
				.. `is about to land on that one instead`
		)
	end

	return spawnPart
end

-- Writes the crate's open time to the player's profile, so it survives a rejoin and a server restart.
-- @param player: The owner of the timer
-- @param openAt: Absolute server-time it opens at, or -1 once it's claimed
function TutorialCrateManager:_persist(player: Player, openAt: number)
	if not validatePlayer(player) then
		return
	end

	PlayerDataManager:SetPlayerDataKey(player, SAVE_KEY, openAt)
end

-- Drops everything tracked for a player's crate, without touching the crate itself.
function TutorialCrateManager:_cleanup(player: Player)
	local entry = self._active[player]
	if not entry then
		return
	end

	entry.Trove:Destroy()
	self._active[player] = nil
end

-- Puts the crate on a player's base and wires up its lifetime.
-- @param player: Who the crate belongs to
-- @param openAt: Absolute server-time it can be opened at; a value in the past spawns it ready
-- @param playCrash: Whether their client plays the meteor crash (finishing only, never on a rejoin)
function TutorialCrateManager:_spawnCrate(player: Player, openAt: number, playCrash: boolean)
	local spawnPart = getSpawnPart(player)
	if not spawnPart then
		warn(`[TutorialCrate] {player.Name} has no Core.{Crates.METEOR_SPAWN_PART} on their base, no crate for them`)
		return
	end

	local landingCFrame = spawnPart.CFrame

	-- Spawned already at rest, so a visitor only ever sees it landed. AutoIdle bobs it where it sits;
	-- TimeToOpen is what the client counts down to and what the server gates the claim on.
	local model, uniqueId = CrateManager:SpawnCrate(Crates.TUTORIAL_CRATE_ID, landingCFrame, {
		AutoIdle = true,
		TimeToOpen = openAt,
	})

	if not (model and uniqueId) then
		warn(`[TutorialCrate] failed to spawn {Crates.TUTORIAL_CRATE_ID} for {player.Name}`)
		return
	end

	-- Marks whose crate this is before anyone can open it. Owner is deliberately left unset until
	-- then: it's what tells every client's CrateController to throw a crate out of someone's hands,
	-- and this one arrived by falling out of the sky.
	model:SetAttribute("CrashOwner", player.UserId)

	-- Only set on the one spawn that actually falls, so the owner's client knows to hold the
	-- countdown back until it lands rather than hanging it on a crate that's still in the air.
	if playCrash then
		model:SetAttribute("PlayCrash", true)
	end

	local entry: CrateEntry = {
		Model = model,
		UniqueId = uniqueId,
		Trove = Trove.new(),

		-- The same condition the crash is: this is the spawn that falls out of the sky when the
		-- tutorial ends, and the only other way a crate gets here is a rejoin resuming a saved stamp.
		SpawnedThisSession = playCrash,
	}

	-- The crate is destroyed when its rewards are granted, which is the one thing that ends the
	-- countdown for good.
	entry.Trove:Add(model.Destroying:Connect(function()
		if self._active[player] ~= entry then
			return
		end

		self:_persist(player, -1)
		self:_cleanup(player)
		self.OnClaimed:Fire(player, entry.SpawnedThisSession)
	end))

	self._active[player] = entry
	self:_persist(player, openAt)

	if playCrash then
		-- The id rather than the model: a model parented this frame may not have replicated yet, and
		-- an Instance argument that hasn't arrives as nil. The client waits for the id to show up.
		self.CrashEvent:FireClient(player, uniqueId, Crates.METEOR_FALL_DURATION, landingCFrame)
	end
end

-- Drops the reward crate for a player who's just finished the tutorial, crash and all.
function TutorialCrateManager:SpawnFor(player: Player)
	if self._active[player] then
		return
	end

	self:_spawnCrate(player, workspace:GetServerTimeNow() + Crates.TUTORIAL_TIMER_DURATION, true)
end

-- Puts a pending crate back when a returning player is given a base, resuming the saved countdown
-- with no crash. Does nothing if they have no crate waiting.
function TutorialCrateManager:_resumeForPlayer(player: Player)
	if self._active[player] or self._spawning[player] then
		return
	end

	self._spawning[player] = true

	local hasStamp, openAt = PlayerDataManager:GetPlayerDataKey(player, SAVE_KEY):await()

	-- They may have left, or been given a crate, while the read was in flight
	if not hasStamp or not validatePlayer(player) or self._active[player] then
		self._spawning[player] = nil
		return
	end

	-- Passed straight through: whatever elapsed while they were away is already in the stamp, so a
	-- value in the past spawns the crate ready to open rather than needing any catch-up.
	if typeof(openAt) == "number" and openAt >= 0 then
		self:_spawnCrate(player, openAt, false)
	end

	self._spawning[player] = nil
end

-- Handles the owner holding the Open prompt: checks the countdown really is up, hands them the
-- crate, and tells every client to play the reveal -- opening is local, so without the broadcast
-- nobody but the owner would see it happen.
function TutorialCrateManager:_handleOpenRequest(player: Player)
	local entry = self._active[player]
	if not entry or not entry.Model.Parent then
		return
	end

	-- Ignore a repeat or late request: an open already underway has taken the crate's owner
	if entry.Model:GetAttribute("Owner") then
		return
	end

	-- The prompt only goes up once the countdown ends, but that's the client's word for it
	local openAt = entry.Model:GetAttribute("TimeToOpen")
	if typeof(openAt) == "number" and workspace:GetServerTimeNow() < openAt then
		return
	end

	-- Stamped before the broadcast, and the crate already exists on every client, so the attribute
	-- lands ahead of the event: the reveal then flies the rewards to the owner and claims from their
	-- client alone, exactly as it would for a crate they'd thrown themselves.
	if not CrateManager:BeginCrateOpen(entry.UniqueId, player) then
		return
	end

	self.OpenEvent:FireAllClients(entry.Model)
end

function TutorialCrateManager:OnInit()
	BaseManager = require(script.Parent.BaseManager)
	CrateManager = require(script.Parent.CrateManager)
	PlayerDataManager = require(script.Parent.PlayerDataManager)
end

function TutorialCrateManager:OnStart()
	-- A returning player's crate goes back the moment they're given a base to put it on
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		task.spawn(function()
			self:_resumeForPlayer(player)
		end)
	end)

	self.OpenEvent:OnServerEvent(function(player: Player)
		self:_handleOpenRequest(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		local entry = self._active[player]
		if entry then
			-- Cleanup first, destroy second, and the order is the whole point: cleanup drops the
			-- Destroying hook, and that hook wipes the saved stamp to -1. Destroy the crate with it
			-- still connected and the player loses a reward they never opened.
			self:_cleanup(player)

			if entry.Model.Parent then
				entry.Model:Destroy()
			end
		end

		self._spawning[player] = nil
	end)
end

return TutorialCrateManager
