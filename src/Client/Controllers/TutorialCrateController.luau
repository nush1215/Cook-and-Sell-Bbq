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

-- The crate that crashes in for finishing the tutorial. The crash and open come over remotes; the countdown comes off the crate's own attributes, so it survives a rejoin. Its Trove's identity doubles as the loop's guard.

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

-- Tags invisible parts so RockModule's ground rays fall through to the floor, or the debris copies their invisibility. Idempotent, and re-run per landing.
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

-- Swaps the billboard to its alert and puts the Open prompt up. Built on the owner's machine alone, so nobody else sees one.
function TutorialCrateController:_onReady(model: Model, billboard: BillboardGui)
	local trove = self._timerTrove
	if not trove or not model.PrimaryPart then
		return
	end

	billboard.Title.Visible = false
	billboard.Timer.Visible = false
	billboard.Alert.Visible = true

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

	-- Cleared for the instant feedback; the reveal arrives back over OpenEvent once the server agrees
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

-- Hangs the countdown over the crate and drives it off the crate's own stamp, needing nothing from the server.
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
	billboard.Title.Text = GuiUtil.Colorize(crate.Name, crate.Color)
	billboard.Alert.Visible = false
	billboard.Parent = primaryPart

	local label = billboard.Timer

	trove:Add(model.Destroying:Connect(function()
		self:_clearTimer()
	end))

	-- Counted on the synced clock, so it can't drift. The trove identity is the loop's guard
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

-- Plays the crash for the finishing player, yanking the already-landed crate up and dropping it back onto its own spot.
function TutorialCrateController:PlayCrash(uniqueId: string, duration: number, landingCFrame: CFrame)
	local model = MeteorFall.WaitForCrate(uniqueId)
	if not model then
		return
	end

	-- Nothing should be sat over the crash
	UIController:CloseOpenFrame()

	-- Clears any billboard that did go up, in case the attribute hadn't replicated when the crate appeared
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
			-- A pull, never a lock, so the player keeps their own look control the whole way down
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

	-- Handed back whatever happened -- a crate destroyed mid-fall never reaches OnLanded
	task.delay(duration + CratesConfig.METEOR_CAMERA_RELEASE_SLACK, function()
		cancel()
		LocalPlayer.CameraMode = Enum.CameraMode.Classic
	end)
end

-- Picks up a tutorial crate appearing in the world and starts its countdown, leaving the crashing one to PlayCrash.
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

	-- Broadcast so the whole base sees the reveal; the crate carries Owner, so only their client claims
	self.OpenEvent:OnClientEvent(function(model: Model)
		CrateController:OpenCrate(model)
	end)

	-- Off the world, not a remote, so a crate already here when this started is caught too
	for _, model in CollectionService:GetTagged(CRATE_TAG) do
		self:_onCrateAdded(model)
	end

	CollectionService:GetInstanceAddedSignal(CRATE_TAG):Connect(function(model: Instance)
		self:_onCrateAdded(model)
	end)
end

return TutorialCrateController
