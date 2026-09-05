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

-- The tutorial's reward crate: crashed onto the finishing player's base, held behind a saved countdown, and opened by its owner.

--
type CrateEntry = {
	Model: Model,
	UniqueId: string,
	Trove: any,
	SpawnedThisSession: boolean,
}

--
local TutorialCrateManager = {
	-- Tells the finishing player's client to play the crash; everyone else sees it already landed
	CrashEvent = Network.Event("TutorialCrateCrash"),

	-- The owner held Open. The server validates, grants, and broadcasts so every client plays the reveal
	OpenEvent = Network.Event("TutorialCrateOpen"),

	-- (player, spawnedThisSession) on a claim; false means they left before the countdown and came back
	OnClaimed = Signal.new(),

	_active = {} :: { [Player]: CrateEntry },
	_spawning = {}, -- [player] = true while a resume is awaiting data
}

--
local function validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

-- The part on a player's base the crate lands on, or nil. Resolved off the BaseId attribute.
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

	-- A part copied from another base keeps that position, dropping every crate onto the base it came off
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

-- Saves the crate's absolute open time, or -1 once claimed, so it survives a rejoin.
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

-- Spawns the crate on a player's base and wires up its lifetime. Returns whether one went down.
function TutorialCrateManager:_spawnCrate(player: Player, openAt: number, playCrash: boolean): boolean
	local spawnPart = getSpawnPart(player)
	if not spawnPart then
		warn(`[TutorialCrate] {player.Name} has no Core.{Crates.METEOR_SPAWN_PART} on their base, no crate for them`)
		return false
	end

	local landingCFrame = spawnPart.CFrame

	-- Spawned at rest, so a visitor only sees it landed. TimeToOpen is what the claim is gated on
	local model, uniqueId = CrateManager:SpawnCrate(Crates.TUTORIAL_CRATE_ID, landingCFrame, {
		AutoIdle = true,
		TimeToOpen = openAt,
	})

	if not (model and uniqueId) then
		warn(`[TutorialCrate] failed to spawn {Crates.TUTORIAL_CRATE_ID} for {player.Name}`)
		return false
	end

	-- Owner is left unset until an open -- it's what tells clients to throw a crate out of someone's hands
	model:SetAttribute("CrashOwner", player.UserId)

	-- Only on the spawn that falls, so the countdown isn't hung on a crate still in the air
	if playCrash then
		model:SetAttribute("PlayCrash", true)
	end

	local entry: CrateEntry = {
		Model = model,
		UniqueId = uniqueId,
		Trove = Trove.new(),

		-- The same condition as the crash; the only other way here is a rejoin resuming a saved stamp
		SpawnedThisSession = playCrash,
	}

	-- The crate is destroyed when its rewards are granted, which is what ends the countdown for good
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
		-- The id, not the model -- an Instance argument that hasn't replicated arrives as nil
		self.CrashEvent:FireClient(player, uniqueId, Crates.METEOR_FALL_DURATION, landingCFrame)
	end

	return true
end

-- Drops the reward crate for a player who's just finished, crash and all. Returns whether one went down.
function TutorialCrateManager:SpawnFor(player: Player, showTimer: boolean): boolean
	if self._active[player] then
		return false
	end

	-- A stamp of now is already past when the client reads it, so the countdown skips to the prompt
	local now = workspace:GetServerTimeNow()
	local openAt = if showTimer then now + Crates.TUTORIAL_TIMER_DURATION else now

	return self:_spawnCrate(player, openAt, true)
end

-- Takes a pending crate out of the world without paying it out, leaving the saved stamp for a rejoin.
function TutorialCrateManager:RemoveFor(player: Player)
	local entry = self._active[player]
	if not entry then
		return
	end

	-- Cleanup first: the Destroying hook wipes the stamp, so destroying with it connected loses the reward
	self:_cleanup(player)

	if entry.Model.Parent then
		entry.Model:Destroy()
	end
end

-- Restores a returning player's pending crate on the saved countdown, with no crash.
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

	-- Passed straight through -- time away is already in the stamp, so a past value spawns it ready
	if typeof(openAt) == "number" and openAt >= 0 then
		self:_spawnCrate(player, openAt, false)
	end

	self._spawning[player] = nil
end

-- Handles the owner's Open: validates the countdown, grants, and broadcasts so everyone sees the reveal.
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

	-- Stamped before the broadcast, so the attribute lands first and the owner's client alone claims
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
		self:RemoveFor(player)
		self._spawning[player] = nil
	end)
end

return TutorialCrateManager
