-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Assets
local UI = ReplicatedStorage.Assets.UI

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local CratesConfig = require(Shared.Config.Crates)

-- Controllers
local CameraController
local CrateController
local EffectController
local NotificationController
local SoundController
local UIController

-- Modules
local Modules = script.Parent.Parent.Modules
local MeteorFall = require(Modules.MeteorFall)
local RockModule = require(Modules.RockModule)

-- Local Player
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

--
local CRATE_TAG = "Crate"
local TIMER_UI_NAME = "TutorialCrateUI"

-- RockModule's own ignore tag: anything carrying it is left out of its ground raycasts.
local ROCK_IGNORE_TAG = "RockModuleIgnore"

--[[
    The crate that crashes into a player's base for finishing the tutorial.

    Three jobs, and they're deliberately driven off different things. The crash comes over a remote,
    because only the finishing player should see the fall. The countdown comes off the crate's own
    tag and attributes, because that has to work on a rejoin with no remote to race against. The open
    comes over a remote again, broadcast to everyone, because opening is local and otherwise nobody
    but the owner would see the reveal.

    Everything the countdown owns -- the billboard, the loop driving it, and the prompt that replaces
    it -- lives in one Trove, and that Trove's identity doubles as the loop's guard. Replacing the
    timer stops the old thread rather than leaving two of them fighting over one label.
]]

--
local TutorialCrateController = {
	CrashEvent = Network.Event("TutorialCrateCrash"),
	OpenEvent = Network.Event("TutorialCrateOpen"),

	_timerTrove = nil :: any,
}

-- Whole seconds as MM:SS -- 310 reads as "05:10".
local function formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d", seconds // 60, seconds % 60)
end

-- Tags every fully invisible part on the base the crate landed on, so RockModule's ground rays fall
-- through them to the floor underneath. It copies whatever it hits onto each rock -- so a ray that
-- stops on an invisible part (a locked unlock's ghost, a trigger volume) spawns invisible debris.
-- Idempotent, and re-run per landing so anything that streamed in since is covered.
local function tagInvisibleBaseParts(baseModel: Model)
	for _, descendant in baseModel:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Transparency >= 1 then
			descendant:AddTag(ROCK_IGNORE_TAG)
		end
	end
end

-- Tears down the countdown -- billboard, loop, prompt and all -- if one is running.
function TutorialCrateController:_clearTimer()
	if self._timerTrove then
		self._timerTrove:Destroy()
		self._timerTrove = nil
	end
end

-- The countdown has run out: drop the billboard, put the Open prompt up in its place, and say so.
-- The prompt is built client-side on the owner's machine alone, so nobody else ever sees one.
-- @param model: The crate to attach the prompt to
-- @param billboard: The countdown billboard, finished with now the crate is openable
function TutorialCrateController:_onReady(model: Model, billboard: BillboardGui)
	local trove = self._timerTrove
	if not trove or not model.PrimaryPart then
		return
	end

	-- Remove rather than Clean: this drops the billboard alone and leaves the trove holding the
	-- prompt, so one _clearTimer still takes down whatever stage the countdown is at.
	trove:Remove(billboard)

	local attachment = trove:Add(Instance.new("Attachment"))
	attachment.Name = "TutorialCratePromptAttachment"
	attachment.Position = Vector3.new(0, 3, 0)
	attachment.Parent = model.PrimaryPart

	local prompt = trove:Add(Instance.new("ProximityPrompt"))
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = "Open"
	prompt.HoldDuration = CratesConfig.TUTORIAL_PROMPT_HOLD
	prompt.MaxActivationDistance = CratesConfig.TUTORIAL_PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = attachment

	-- Cleared here for the instant feedback; the reveal itself arrives back over OpenEvent once the
	-- server has agreed the crate is theirs to open.
	trove:Add(prompt.Triggered:Connect(function()
		self:_clearTimer()
		self.OpenEvent:FireServer()
	end))

	local crate = CratesConfig.GetCrateFromId(model:GetAttribute("CrateId"))

	NotificationController:NotifyNormal({
		Text = `Your {GuiUtil.Colorize(crate.Name, crate.Color)} is ready to open`,
		Duration = 5,
		Sound = "Notify",
		Effect = "Success",
	})
end

-- Hangs the countdown billboard over the crate and drives it locally off the stamp the crate is
-- carrying, so it needs nothing from the server once it's up.
-- @param model: The tutorial crate this countdown belongs to
function TutorialCrateController:_showTimer(model: Model)
	self:_clearTimer()

	local openAt = model:GetAttribute("TimeToOpen")
	if typeof(openAt) ~= "number" then
		return
	end

	-- Claimed before anything yields, so a later call can supersede this one mid-wait
	local trove = Trove.new()
	self._timerTrove = trove

	-- A crate's PrimaryPart can trail the model by a frame on a fresh join
	local deadline = os.clock() + CratesConfig.PRIMARY_PART_WAIT
	while not model.PrimaryPart and os.clock() < deadline do
		task.wait()

		if self._timerTrove ~= trove then
			return
		end
	end

	local primaryPart = model.PrimaryPart
	if not primaryPart then
		self:_clearTimer()
		return
	end

	local crate = CratesConfig.GetCrateFromId(model:GetAttribute("CrateId"))

	local billboard = trove:Clone(UI[TIMER_UI_NAME])
	billboard.Adornee = primaryPart
	billboard.TextLabel.Text = GuiUtil.Colorize(crate.Name, crate.Color)
	billboard.Parent = primaryPart

	local label = billboard.Timer

	trove:Add(model.Destroying:Connect(function()
		self:_clearTimer()
	end))

	-- Counted against the synced server clock rather than a local tick, so it can't drift and needs
	-- no traffic. The trove identity is the loop's guard: replace the timer and this thread ends.
	trove:Add(task.spawn(function()
		while self._timerTrove == trove do
			local remaining = openAt - workspace:GetServerTimeNow()

			if remaining <= 0 then
				self:_onReady(model, billboard)
				break
			end

			label.Text = formatTime(remaining)
			task.wait(0.5)
		end
	end))
end

-- Plays the crash on the finishing player's client and softly tracks it with the camera. The crate
-- is already at rest on the server -- everyone else just sees it landed -- so this yanks it up to a
-- diagonal entry point and drops it back onto the exact spot it's already sitting on.
-- @param uniqueId: The crate's id, resolved to the model once it has replicated
-- @param duration: How long the fall takes
-- @param landingCFrame: Where it comes to rest
function TutorialCrateController:PlayCrash(uniqueId: string, duration: number, landingCFrame: CFrame)
	local model = MeteorFall.WaitForCrate(uniqueId)
	if not model then
		return
	end

	-- Nothing should be sat over the crash
	UIController:CloseOpenFrame()

	-- The tag listener skips crash spawns so the billboard doesn't ride the crate down; clear any
	-- that did go up, in case the attribute hadn't replicated when the crate first appeared.
	self:_clearTimer()

	-- The crash only ever fires for the crate's own owner, so the base it landed on is ours
	local landingPos = landingCFrame.Position
	local baseId = LocalPlayer:GetAttribute("BaseId")
	local baseModel = baseId and workspace.Base:FindFirstChild(baseId)

	LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson

	local cancel = MeteorFall.Play(model, {
		Duration = duration,
		LandingCFrame = landingCFrame,

		OnFrame = function(_: number, position: Vector3)
			-- Only a pull, never a lock: the camera is nudged a fraction toward the crate each frame
			-- so the player still has their own look control the whole way down.
			Camera.CFrame = Camera.CFrame:Lerp(
				CFrame.lookAt(Camera.CFrame.Position, position),
				CratesConfig.METEOR_FOCUS_ALPHA
			)
		end,

		OnLanded = function()
			-- Settled, so the bob can take the pivot now without fighting the fall for it
			CrateController:IdleCrate(model)
			LocalPlayer.CameraMode = Enum.CameraMode.Classic

			if baseModel then
				tagInvisibleBaseParts(baseModel)
			end

			local impactCFrame = CFrame.new(landingPos)
			RockModule.Explosion(
				impactCFrame,
				CratesConfig.METEOR_EXPLOSION_ROCKS,
				CratesConfig.METEOR_EXPLOSION_MIN_SIZE,
				CratesConfig.METEOR_EXPLOSION_MAX_SIZE,
				false
			)
			RockModule.Crater(
				impactCFrame,
				CratesConfig.METEOR_CRATER_RADIUS,
				CratesConfig.METEOR_CRATER_MIN_ROCKS,
				CratesConfig.METEOR_CRATER_MAX_ROCKS,
				false
			)

			SoundController:PlaySound("CrateCrash", model.PrimaryPart)
			EffectController:RunEffect("CrateTwitch", model)

			self:_showTimer(model)

			local shake = CratesConfig.METEOR_SHAKE
			task.defer(function()
				CameraController:ShakeCustom(shake.Magnitude, shake.Roughness, shake.FadeIn, shake.FadeOut)
			end)
		end,
	})

	-- Hands the camera back whatever happened -- a crate destroyed mid-fall never reaches OnLanded,
	-- and leaving someone stuck in first person would be a lot worse than a missed cinematic.
	task.delay(duration + CratesConfig.METEOR_CAMERA_RELEASE_SLACK, function()
		cancel()
		LocalPlayer.CameraMode = Enum.CameraMode.Classic
	end)
end

-- Picks up a tutorial crate appearing in the world and starts its countdown, leaving the one that's
-- about to crash to PlayCrash -- which starts it on landing, so the billboard doesn't fall with it.
function TutorialCrateController:_onCrateAdded(model: Instance)
	if not model:IsA("Model") then
		return
	end

	if model:GetAttribute("CrashOwner") ~= LocalPlayer.UserId then
		return
	end

	if model:GetAttribute("PlayCrash") then
		return
	end

	self:_showTimer(model)
end

function TutorialCrateController:OnInit()
	CameraController = require(script.Parent.CameraController)
	CrateController = require(script.Parent.CrateController)
	EffectController = require(script.Parent.EffectController)
	NotificationController = require(script.Parent.NotificationController)
	SoundController = require(script.Parent.SoundController)
	UIController = require(script.Parent.UIController)
end

function TutorialCrateController:OnStart()
	self.CrashEvent:OnClientEvent(function(uniqueId: string, duration: number, landingCFrame: CFrame)
		self:PlayCrash(uniqueId, duration, landingCFrame)
	end)

	-- Broadcast to everyone once the owner opens theirs, so the whole base sees the reveal. The crate
	-- carries Owner by now, so only their client claims and the rewards fly to them.
	self.OpenEvent:OnClientEvent(function(model: Model)
		CrateController:OpenCrate(model)
	end)

	-- Off the world rather than off a remote: catch our crate appearing, and any that was already
	-- here when this started, which is the rejoin case.
	for _, model in CollectionService:GetTagged(CRATE_TAG) do
		self:_onCrateAdded(model)
	end

	CollectionService:GetInstanceAddedSignal(CRATE_TAG):Connect(function(model: Instance)
		self:_onCrateAdded(model)
	end)
end

return TutorialCrateController
