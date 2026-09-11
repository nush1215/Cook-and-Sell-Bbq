-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local EmployeeHut = require(Shared.Config.EmployeeHut)
local Plots = require(Shared.Config.Plots)
local GuiUtil = require(Shared.GuiUtil)

-- Assets
local UI = ReplicatedStorage.Assets.UI

-- Controllers
local PlayerDataController = require(script.Parent.PlayerDataController)
local UIController = require(script.Parent.UIController)
local NotificationController = require(script.Parent.NotificationController)
local EffectController = require(script.Parent.EffectController)

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- How long a streamed-in base gets to finish replicating the folder its hut sits in
local CHILD_TIMEOUT = 10

-- The loader runs every OnInit on one thread, so this waits with a timeout rather than hanging the boot
local UI_TIMEOUT = 10

-- How long the buy button stays down after a repair is asked for, in case the server turns it down and no hut ever leaves
local REPAIR_TIMEOUT = 5

-- The View prompt on every base's broken hut and the panel it opens, where the repair is bought. Owner-only and held until the hut's plot is bought; once repaired the server empties the folder and the hut becomes an ordinary placed structure, so an empty folder is what "repaired" looks like from here.
local EmployeeHutController = {
	RepairHutEvent = Network.Event("RepairHut"),

	_huts = {}, -- [baseModel] = { Folder, BaseCleaner, Prompt?, Cleaner?, RepairCleaner?, RepairEndsAt? }
	_repairing = false, -- the client half of the debounce; the server holds the authoritative one
	_cleaner = Trove.new(),
}

-- Opens the repair panel, or shuts it again if it's the frame already up -- OpenFrame toggles on a repeat.
function EmployeeHutController:Open()
	if not self.UI then
		return
	end

	UIController:OpenFrame(self.UI.Holder)
end

-- Shuts the panel. Guarded on it being up, since CloseFrame springs the camera back whether it was or not.
function EmployeeHutController:Close()
	if not self.UI or not self.UI.Holder.Visible then
		return
	end

	UIController:CloseFrame(self.UI.Holder)
end

-- Answers the prompt: the panel if the hut's plot is theirs, otherwise a word about which plot stands in the way, said with the plot itself lit up so they know the one meant.
function EmployeeHutController:RequestOpen(baseModel: Model)
	if Plots.IsOwned(EmployeeHut.REQUIRED_PLOT, PlayerDataController:GetKey("Plots") or {}) then
		self:Open()
		return
	end

	NotificationController:NotifyNormal({
		Text = `Unlock Plot {EmployeeHut.REQUIRED_PLOT} to repair the hut`,
		Effect = "Error",
		Duration = 3,
		Sound = "Reject",
	})

	-- The toast names the plot; this says which one it is out in the world
	local folder = baseModel:FindFirstChild(Plots.FOLDER_NAME)
	local plotModel = folder and folder:FindFirstChild(EmployeeHut.REQUIRED_PLOT)

	if plotModel then
		EffectController:RunEffect("HighlightPulse", {
			plotModel,
			EmployeeHut.PLOT_PULSE_COLOR,
			EmployeeHut.PLOT_PULSE_DURATION,
			EmployeeHut.PLOT_PULSE_START_TRANSPARENCY,
			EmployeeHut.PLOT_PULSE_COUNT,
		})
	end
end

-- Asks the server to repair the hut. The price isn't the client's to send, and nor is whether they may.
function EmployeeHutController:RequestRepair()
	if self._repairing then
		return
	end

	self._repairing = true
	self.RepairHutEvent:FireServer()

	-- Cleared by the hut leaving the folder on a repair; this is only the backstop for one the server refused
	task.delay(REPAIR_TIMEOUT, function()
		self._repairing = false
	end)
end

-- Where the prompt and the repair billboard both hang. Searched, since the attachment sits under the Hitbox.
function EmployeeHutController:_getPromptHost(model: Model): Instance?
	return model:FindFirstChild(EmployeeHut.PROMPT_ATTACHMENT, true) or model.PrimaryPart
end

-- Puts the countdown over a hut being repaired and takes it down when it isn't. Everyone sees it, so a visitor can tell why the hut is still broken.
function EmployeeHutController:_refreshRepairingUI(hut, model: Model?, repairing: boolean, endsAt: number?)
	if not repairing then
		if hut.RepairCleaner then
			self._cleaner:Remove(hut.RepairCleaner)
			hut.RepairCleaner = nil
			hut.RepairEndsAt = nil
		end

		return
	end

	-- Rebuilt rather than left alone if the deadline moved, since the loop below closes over it
	if hut.RepairCleaner then
		if hut.RepairEndsAt == endsAt then
			return
		end

		self._cleaner:Remove(hut.RepairCleaner)
		hut.RepairCleaner = nil
	end

	local template = UI:FindFirstChild(EmployeeHut.REPAIRING_UI)
	local host = self:_getPromptHost(model)

	-- Warned rather than thrown, so a missing template costs the countdown and nothing else
	if not template or not host then
		warn(`[EmployeeHut] no Assets.UI.{EmployeeHut.REPAIRING_UI} or prompt host, the repair won't show a timer`)
		return
	end

	local repairCleaner = self._cleaner:Construct(Trove)
	hut.RepairCleaner = repairCleaner
	hut.RepairEndsAt = endsAt

	-- Straight onto the attachment, which carries the authored offset. The PlayerGui route is only for clickable billboards
	local billboard = repairCleaner:Clone(template)
	billboard.Adornee = host
	billboard.Parent = host

	-- Counted on the synced clock, so every client agrees. The trove identity is the loop's guard
	repairCleaner:Add(task.spawn(function()
		local dots = 0

		while hut.RepairCleaner == repairCleaner do
			local remaining = endsAt - workspace:GetServerTimeNow()
			if remaining <= 0 then
				break
			end

			-- Cycles 1..MAX so the title always carries at least one dot
			dots = dots % EmployeeHut.REPAIRING_MAX_DOTS + 1

			billboard.Title.Text = EmployeeHut.REPAIRING_TITLE .. string.rep(".", dots)
			billboard.Time.Text = GuiUtil.ConvertSecondsToDHMS(remaining)

			task.wait(EmployeeHut.REPAIRING_DOT_INTERVAL)
		end

		-- Deferred, or refreshing would clean the trove holding this very thread and cancel it mid-call
		task.defer(function()
			self:RefreshHuts()
		end)
	end))
end

-- Repaints every base's hut. Cheap, and what's shown depends on the local base and which plots are owned.
function EmployeeHutController:RefreshHuts()
	for baseModel, hut in self._huts do
		self:_refreshHut(baseModel, hut)
	end
end

-- Puts the repair prompt up on the owner's broken hut only, so a visitor can look at one without being offered it.
function EmployeeHutController:_refreshHut(baseModel: Model, hut)
	local model = hut.Folder:FindFirstChild(EmployeeHut.MODEL_NAME)

	local owned = baseModel.Name == LocalPlayer:GetAttribute("BaseId")

	-- The deadline rides the base model, not player data, so a visitor sees the repair too
	local endsAt = baseModel:GetAttribute(EmployeeHut.REPAIR_ENDS_ATTRIBUTE)
	local repairing = model ~= nil and endsAt ~= nil and endsAt > workspace:GetServerTimeNow()

	-- Our own request landing, so the button is free again and the panel has nothing left to sell
	if owned and repairing and self._repairing then
		self._repairing = false
		self:Close()
	end

	self:_refreshRepairingUI(hut, model, repairing, endsAt)

	-- An empty folder is a repaired hut, a repairing one has nothing left to buy, and off our base
	-- there's nothing to offer either way. The hut's plot isn't checked here: the prompt goes up whether or
	-- not they own it, and refuses by pointing at the plot -- which is how they learn what's in the way
	local offered = model ~= nil and not repairing and owned

	if not offered then
		if hut.Cleaner then
			self._cleaner:Remove(hut.Cleaner)
			hut.Cleaner = nil
			hut.Prompt = nil
		end

		return
	end

	if not hut.Prompt then
		local promptHost = self:_getPromptHost(model)
		if not promptHost then
			warn(`[EmployeeHut] {baseModel.Name}'s hut has no {EmployeeHut.PROMPT_ATTACHMENT} or PrimaryPart, it can't be repaired`)
			return
		end

		local hutCleaner = self._cleaner:Construct(Trove)

		local prompt = Instance.new("ProximityPrompt")
		prompt.RequiresLineOfSight = false
		prompt.HoldDuration = EmployeeHut.PROMPT_HOLD_DURATION
		prompt.MaxActivationDistance = EmployeeHut.PROMPT_MAX_DISTANCE
		prompt.ActionText = EmployeeHut.PROMPT_ACTION_TEXT
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.Parent = promptHost
		hutCleaner:Add(prompt)

		hutCleaner:Connect(prompt.Triggered, function()
			self:RequestOpen(baseModel)
		end)

		hut.Prompt = prompt
		hut.Cleaner = hutCleaner
	end
end

-- Tracks a base's hut once its folder has replicated; the wait lives here, and the folder is watched for the swap.
function EmployeeHutController:_setupBase(baseModel: Model)
	if self._huts[baseModel] then
		return
	end

	local folder = baseModel:WaitForChild(EmployeeHut.FOLDER_NAME, CHILD_TIMEOUT)
	if not folder then
		warn(`[EmployeeHut] {baseModel.Name}'s hut folder never replicated, its repair won't show`)
		return
	end

	-- Waiting above yields, so the base can have streamed out or been built by a racing thread
	if not baseModel.Parent or self._huts[baseModel] then
		return
	end

	-- Its own trove, so a base streaming out takes these two connections with it
	local baseCleaner = self._cleaner:Construct(Trove)

	local hut = { Folder = folder, BaseCleaner = baseCleaner }
	self._huts[baseModel] = hut

	-- The hut leaves the folder when the repair finishes, and the swap is what the prompt reads
	baseCleaner:Connect(folder.ChildRemoved, function()
		self:RefreshHuts()
	end)
	baseCleaner:Connect(folder.ChildAdded, function()
		self:RefreshHuts()
	end)

	-- The repair starting, ending or being cleared all land here
	baseCleaner:Connect(baseModel:GetAttributeChangedSignal(EmployeeHut.REPAIR_ENDS_ATTRIBUTE), function()
		self:RefreshHuts()
	end)

	self:_refreshHut(baseModel, hut)
end

-- Drops the prompt for a base that's streamed out or been removed.
function EmployeeHutController:_removeBase(baseModel: Model)
	local hut = self._huts[baseModel]
	if not hut then
		return
	end

	if hut.Cleaner then
		self._cleaner:Remove(hut.Cleaner)
	end

	if hut.RepairCleaner then
		self._cleaner:Remove(hut.RepairCleaner)
	end

	self._cleaner:Remove(hut.BaseCleaner)
	self._huts[baseModel] = nil
end

function EmployeeHutController:OnInit()
	-- Timed out rather than waited on, since the loader runs every OnInit on one thread
	self.UI = PlayerGui:WaitForChild(EmployeeHut.UI_NAME, UI_TIMEOUT)

	if not self.UI then
		warn(`[EmployeeHut] PlayerGui.{EmployeeHut.UI_NAME} is missing, so the hut can't be repaired`)
	end
end

function EmployeeHutController:OnStart()
	-- Bound once here rather than per open: a hidden frame can't be clicked, so the bindings stay live
	if self.UI then
		local holder = self.UI.Holder
		holder.Visible = false

		-- The cost never moves, so the label is written once rather than repainted
		-- In full rather than shortened: it's a one-off price they're saving up to, so the exact figure is
		-- what they're checking their Bux against
		holder.Price.Text = `${GuiUtil.ConvertNumberWithCommas(EmployeeHut.REPAIR_COST)}`

		-- Left pressable when they can't afford it, so the server is the one that says why
		UIController:BindButtonClick(holder.Purchase, function()
			self:RequestRepair()
		end, true)

		UIController:BindButtonClick(holder.Exit, function()
			self:Close()
		end, true)
	end

	-- Watched rather than swept once, and off this thread since the loader runs every OnStart on one
	task.spawn(function()
		local baseFolder = workspace:WaitForChild("Base")

		self._cleaner:Connect(baseFolder.ChildAdded, function(baseModel)
			self:_setupBase(baseModel)
		end)
		self._cleaner:Connect(baseFolder.ChildRemoved, function(baseModel)
			self:_removeBase(baseModel)
		end)

		-- _setupBase waits on the base's hut folder, so keep the sweep off this thread too
		for _, baseModel in baseFolder:GetChildren() do
			task.spawn(function()
				self:_setupBase(baseModel)
			end)
		end
	end)

	-- BaseId lands after the huts are built and moves on assignment, so re-check which prompt is up
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:RefreshHuts()
	end)

	-- No plots listener: what's shown no longer turns on owning the hut's plot, and the refusal reads it live
	self:RefreshHuts()
end

return EmployeeHutController
