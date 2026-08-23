-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

-- Packages
local Packages = ReplicatedStorage.Packages
local TopbarPlus = require(Packages.TopbarPlus)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

-- Modules
local PitchLadder = require(script.Parent.Parent.Modules.PitchLadder)

--
local TIME_THRESHOLD = 0.05
local STOP_FADE_TIME = 1 -- seconds StopSound eases a sound out over before dropping it

-- Sounds that climb in pitch across a rapid streak instead of flatly repeating, so a run of purchases
-- or upgrades escalates. Each name ramps independently and drops back once the player pauses.
local PITCHED_SOUNDS = { Upgrade = true, Purchase = true }
local pitchLadder = PitchLadder.new({ Increment = 0.08, Max = 1.5, MaxHits = 1 })

--
local SoundController = {
	PlaySoundEvent = Network.Event("PlaySound"),
	PlayRandomSoundEvent = Network.Event("PlayRandomSoundInFolder"),
	ReplicateToOthersEvent = Network.Event("ReplicateSoundToOthers"),

	_lastPlayedSounds = {},
	_muted = false,
}

--
local function createLocationPart(position: Vector3): BasePart
	local locationPart = Instance.new("Part")
	locationPart.Anchored = true
	locationPart.CanCollide = false
	locationPart.Transparency = 1
	locationPart.Size = Vector3.one
	locationPart.Position = position
	locationPart.Parent = workspace.Terrain
	return locationPart
end

-- Eases a sound down to silence and drops it, so a loop ends rather than cutting off mid-frame
local function fadeOutAndDestroy(sound: Sound, duration: number)
	local tween = TweenService:Create(sound, TweenInfo.new(duration), { Volume = 0 })
	tween:Play()
	tween.Completed:Connect(function()
		sound:Destroy()
	end)
end

-- Plays a sound at a location with optional custom properties
-- @param soundName The name of the sound to play
-- @param location The location to play the sound at (CFrame, Vector3, or Part)
-- @param customProperties Optional custom properties to apply to the sound
-- @param limit Whether to limit overlapping sounds
-- @param replicate Whether to replicate the sound to other clients
-- @returns Sound The sound instance that was played
function SoundController:PlaySound(
	soundName: string,
	location: CFrame | Vector3 | Part?,
	customProperties: { [any]: any }?,
	limit: boolean?,
	replicate: boolean?
): Sound?
	local sound: Sound? = SoundService:FindFirstChild(soundName, true)
	if not sound then
		warn(`Sound {soundName} not found in SoundService`)
		return
	end

	if limit and self._lastPlayedSounds[soundName] then
		return
	end

	local soundClone = sound:Clone()

	-- Laddered sounds ramp on each consecutive play. Set before customProperties so a caller passing an
	-- explicit PlaybackSpeed still wins.
	if PITCHED_SOUNDS[soundName] then
		soundClone.PlaybackSpeed = pitchLadder:Next(soundName)
	end

	if customProperties then
		for property, val in customProperties do
			soundClone[property] = val
		end
	end

	-- Convert CFrame to Vector3 if needed
	if typeof(location) == "CFrame" then
		location = location.Position
	end

	-- Set sound parent based on location type
	local locationPart: BasePart?
	if typeof(location) == "Vector3" then
		locationPart = createLocationPart(location)
		soundClone.Parent = locationPart
	elseif location and location:IsA("BasePart") then
		soundClone.Parent = location
	else
		soundClone.Parent = SoundService.SFX
	end

	if replicate then
		self.ReplicateToOthersEvent:FireServer({ soundName, location, customProperties, limit })
	end

	soundClone.Name = `{soundName}_Played`
	soundClone.SoundGroup = SoundService.SFX
	soundClone:Play()

	-- Cleanup sound after it finishes
	task.delay(sound.TimeLength + 1, function()
		if soundClone.Looped then
			return
		end

		if soundClone then
			soundClone:Destroy()
		end

		if locationPart then
			locationPart:Destroy()
		end
	end)

	-- Prevent overlapping sounds
	if limit then
		self._lastPlayedSounds[soundName] = true
		task.delay(TIME_THRESHOLD, function()
			self._lastPlayedSounds[soundName] = nil
		end)
	end

	return soundClone
end

-- Plays a sound on loop, easing it up from silence, and hands back a stopper that eases it back down and
-- drops it -- so a loop can start and stop without cracking in or cutting dead.
-- @param soundName The name of the sound to play
-- @param location The location to play the sound at (CFrame, Vector3, or Part)
-- @param fadeIn Seconds the volume ramps up over
-- @param fadeOut Seconds the volume ramps back down over once stopped
-- @returns A function that stops the loop, or nil if the sound wasn't found
function SoundController:PlayLoopedSound(
	soundName: string,
	location: (CFrame | Vector3 | Part)?,
	fadeIn: number,
	fadeOut: number
): (() -> ())?
	-- Started silent, so the first frame can't crack in at full volume before the ramp takes over.
	local sound = self:PlaySound(soundName, location, { Looped = true, Volume = 0 })
	if not sound then
		return nil
	end

	-- The level the ramp climbs to is the original's, since the clone's own has been zeroed above.
	local template: Sound = SoundService:FindFirstChild(soundName, true)
	TweenService:Create(sound, TweenInfo.new(fadeIn), { Volume = template.Volume }):Play()

	return function()
		fadeOutAndDestroy(sound, fadeOut)
	end
end

-- Stops a sound with optional fade out
-- @param soundName The name of the sound to stop
-- @param location Optional location to search for the sound (defaults to ReplicatedStorage)
function SoundController:StopSound(soundName: string, location: Instance?)
	local soundLocation = location or ReplicatedStorage
	local sound: Sound? = soundLocation:FindFirstChild(soundName)

	if not sound then
		return
	end

	if sound.Playing then
		fadeOutAndDestroy(sound, STOP_FADE_TIME)
	else
		sound:Destroy()
	end
end

-- Sets the core BGM volume with optional tween duration
-- @param volume The target volume (0-1)
-- @param setDuration Optional duration for the volume tween (default: 0)
function SoundController:SetBGMCoreVolume(volume: number, setDuration: number?)
	local coreBGM = SoundService:FindFirstChild("CoreBGM", true)
	if not coreBGM then
		warn("CoreBGM Sound Group not found in SoundService")
		return
	end

	TweenService:Create(coreBGM, TweenInfo.new(setDuration or 0, Enum.EasingStyle.Linear), {
		Volume = volume,
	}):Play()
end

-- Plays a random sound from a folder
-- @param folderName The name of the folder containing sounds
-- @param params Optional parameters to pass to PlaySound
function SoundController:PlayRandomSoundInFolder(folderName: string, params: { any }?)
	local soundFolder = SoundService:FindFirstChild(folderName, true)
	if not soundFolder then
		warn(`Sound folder {folderName} not found`)
		return
	end

	local sounds = soundFolder:GetChildren()
	if #sounds == 0 then
		warn(`Sound folder {folderName} is empty`)
		return
	end

	local randomSound: Sound = sounds[math.random(1, #sounds)]
	self:PlaySound(randomSound.Name, table.unpack(params or {}))
end

-- Starts the background music cycle
function SoundController:_startBackgroundMusicCycle()
	local backgroundMusic = SoundService:FindFirstChild("BackgroundMusic", true)
	if not backgroundMusic then
		warn("BackgroundMusic Sound Group not found in SoundService")
		return
	end

	while true do
		for _, sound: Sound in backgroundMusic:GetChildren() do
			if not sound:IsA("Sound") then
				continue
			end

			sound:Play()
			sound.Ended:Wait()
		end
		task.wait(1)
	end
end

-- Mutes or unmutes the background music
-- @param toggle Whether to mute (true) or unmute (false)
function SoundController:MuteBGM(toggle: boolean)
	local backgroundMusic = SoundService:FindFirstChild("BackgroundMusic", true)
	if not backgroundMusic then
		warn("BackgroundMusic Sound Group not found in SoundService")
		return
	end

	TweenService:Create(backgroundMusic, TweenInfo.new(1), {
		Volume = toggle and 0 or 1,
	}):Play()
end

function SoundController:OnInit()
	task.spawn(function()
		self:_startBackgroundMusicCycle()
	end)
end

function SoundController:OnStart()
	-- Setup mute button
	local muteButton = TopbarPlus.new()
	muteButton:setImage("rbxassetid://105660815548502", "Deselected")
	muteButton:setImage("rbxassetid://97396994687957", "Selected")

	muteButton.selected:Connect(function()
		self:MuteBGM(true)
	end)

	muteButton.deselected:Connect(function()
		self:MuteBGM(false)
	end)

	-- Setup event handlers
	self.PlaySoundEvent:OnClientEvent(function(data: { any })
		self:PlaySound(table.unpack(data))
	end)

	self.PlayRandomSoundEvent:OnClientEvent(function(data: { any })
		self:PlayRandomSoundInFolder(table.unpack(data))
	end)
end

return SoundController
