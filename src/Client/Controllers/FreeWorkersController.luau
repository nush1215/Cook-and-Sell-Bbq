-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local FreeWorkers = require(Shared.Config.FreeWorkers)
local Employees = require(Shared.Config.Employees)
local Rating = require(Shared.Config.Rating)

-- Modules
local ViewportPortrait = require(script.Parent.Parent.Modules.ViewportPortrait)

-- Controllers
local UIController = require(script.Parent.UIController)
local PlayerDataController = require(script.Parent.PlayerDataController)
local NotificationController = require(script.Parent.NotificationController)
local WorkerGuideController = require(script.Parent.WorkerGuideController)
local WorkerHutController = require(script.Parent.WorkerHutController)
local SoundController = require(script.Parent.SoundController)

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- The loader runs every OnInit on one thread, so this waits with a timeout rather than hanging the boot
local UI_TIMEOUT = 10

-- How long the cards stay locked after a claim, in case the server turns it down and no result lands
local REQUEST_TIMEOUT = 3

-- The cards' entrance: up from under the screen to the middle of it
local CONTAINER_CLOSED_POSITION = UDim2.fromScale(0.5, 1.5)
local CONTAINER_OPEN_POSITION = UDim2.fromScale(0.5, 0.5)
local CONTAINER_DAMPING = 0.7
local CONTAINER_FREQUENCY = 2.5

-- The backdrop behind them, faded rather than sprung so it doesn't chase the cards up the screen
local BACKDROP_FADE_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- The size of a card not standing forward, face-down or merely passed over. The one brought forward springs
-- up to full size and whatever was there springs back down to this, so only ever one of the three is big
local CARD_CLOSED_SCALE = 0.5
local CARD_REVEAL_DAMPING = 0.6
local CARD_REVEAL_FREQUENCY = 3.5

-- How a card answers the cursor, as a share of its resting size: UIController's own hover and press figures,
-- taken around a card sitting at CARD_CLOSED_SCALE rather than around 1
local CARD_HOVER_MULTIPLIER = 1.06
local CARD_PRESS_MULTIPLIER = 0.93

-- The Hired stamp landing on the card they took: in oversized, down to rest like a thump, as the board's own does
local STAMP_START_SCALE = 1.4
local STAMP_SCALE_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- How long the stamp is left up before the panel hands over to the hut's own
local CLOSE_DELAY = 0.7

-- The three workers given away on the first open of a repaired hut: one per role, face-down until each is turned over, and one of them theirs for nothing. Who they are is derived from their own UserId rather than sent, so this draws the same three the server reads the claim against; the portraits are baked by the server into this player's own PlayerGui.
local FreeWorkersController = {
	ClaimFreeWorkerEvent = Network.Event("ClaimFreeWorker"),
	ClaimFreeWorkerResultEvent = Network.Event("ClaimFreeWorkerResult"),
	FreeWorkersOpenedEvent = Network.Event("FreeWorkersOpened"), -- client -> server (no args)
	FreeWorkerLookedAtEvent = Network.Event("FreeWorkerLookedAt"), -- client -> server (slotIndex)

	_slots = {}, -- [slot] = { Frame, Scale, StampScale, Revealed, PortraitCleaner, EffectCleaner }
	_candidates = {}, -- this player's three, rolled once on start
	_selected = nil, -- the card standing forward, the only one Hire is offered on
	_claiming = false, -- the client half of the debounce; the server holds the authoritative one
	_cleaner = Trove.new(),
}

-- Whether the three are still on the table, which is what puts this panel up in place of the hut's own.
function FreeWorkersController:ShouldOffer(): boolean
	return not PlayerDataController:GetKey("FreeWorkersClaimed")
end

-- Writes one candidate onto its card. Drawn once and left under the Mystery frame, so turning a card over reveals rather than paints.
function FreeWorkersController:_drawCard(slot: number)
	local state = self._slots[slot]
	local candidate = self._candidates[slot]
	local frame = state.Frame

	frame.EmployeeName.Text = candidate.Name
	frame.RoleName.Text = Employees.ROLE_NAMES[candidate.Role]
	frame.Description.Text = Employees.ROLE_DESCRIPTIONS[candidate.Role]
	frame.EmployeeRoleIcon.Image = Employees.ROLE_ICONS[candidate.Role]

	Rating.DrawStars(frame.Stars, candidate.Stars)
	frame.Rating.Text = Rating.FormatStars(candidate.Stars)

	state.PortraitCleaner:Clean()

	-- Baked on handover, so a missing one is normal and the folder's ChildAdded repaints it
	local portraits = PlayerGui:FindFirstChild(FreeWorkers.PORTRAIT_FOLDER)
	local portrait = portraits and portraits:FindFirstChild(tostring(slot))
	if portrait then
		state.PortraitCleaner:Add(ViewportPortrait.Show(frame.ViewportFrame, portrait))
	end
end

-- Puts every card back face-down, so the panel comes up on three mysteries however it was last left.
function FreeWorkersController:_closeCards()
	self._selected = nil

	for _, state in self._slots do
		local frame = state.Frame

		state.Revealed = false

		-- A hidden button can't be pressed, so visibility is the whole of what keeps a face-down card from being
		-- hired: a plain frame laid over one wouldn't block the press on its own
		frame.Mystery.Visible = true
		frame.Button.Visible = true
		frame.Hire.Visible = false
		frame.Info.Visible = false
		frame.Hired.Visible = false

		self:_bindCardEffect(state)

		-- Stopped before it's written, or a reveal or a hover still settling would pull the card back open
		Spr.stop(state.Scale)
		state.Scale.Scale = CARD_CLOSED_SCALE
	end
end

-- Springs the card itself under the cursor rather than the invisible button laid over it. Bound only while the card is back with the rest: the one standing forward has its button hidden anyway, and this effect rests at the smaller size, so leaving it on would pull a selected card back down out of the selection.
function FreeWorkersController:_bindCardEffect(state)
	state.EffectCleaner:Clean()

	state.EffectCleaner:Add(UIController:BindButtonEffect(state.Frame.Button, {
		ShowFrame = state.Frame,
		ButtonNormalScale = CARD_CLOSED_SCALE,
		ButtonHoverscale = CARD_CLOSED_SCALE * CARD_HOVER_MULTIPLIER,
		ButtonDownScale = CARD_CLOSED_SCALE * CARD_PRESS_MULTIPLIER,
	}).Disconnect)
end

-- Brings one card forward, turning it over the first time, and sends whatever was forward back down to the size of the rest. Only the one standing forward offers Hire, so which worker a press is for is never in doubt.
function FreeWorkersController:SelectSlot(slot: number)
	if self._selected == slot then
		return
	end

	local previous = self._selected and self._slots[self._selected]
	if previous then
		-- Back down to the size of one not picked, but never back under its Mystery frame: it has been seen,
		-- and its Button comes back so it can be brought forward again
		previous.Frame.Button.Visible = true
		previous.Frame.Hire.Visible = false
		previous.Frame.Info.Visible = false

		-- Hoverable again now its button is back. Bound before the spring below, since swapping an effect out
		-- targets the resting size and the spring has to be the last word
		self:_bindCardEffect(previous)

		Spr.target(previous.Scale, CARD_REVEAL_DAMPING, CARD_REVEAL_FREQUENCY, { Scale = CARD_CLOSED_SCALE })
	end

	self._selected = slot

	local state = self._slots[slot]

	-- Reported the first time each card is turned over; the server counts them, so this only says which
	if not state.Revealed then
		state.Revealed = true
		self.FreeWorkerLookedAtEvent:FireServer(slot)
	end

	local frame = state.Frame
	frame.Mystery.Visible = false
	frame.Button.Visible = false
	frame.Hire.Visible = true
	frame.Info.Visible = true

	-- Dropped before the spring below, and in this order whichever way the release lands: letting the effect
	-- go targets the smaller resting size, so the spring to full size has to be the last word
	state.EffectCleaner:Clean()

	Spr.target(state.Scale, CARD_REVEAL_DAMPING, CARD_REVEAL_FREQUENCY, { Scale = 1 })
end

-- Asks for the worker on `slot`, once every card has been looked at. Which one they took is all that goes out -- the server derives the three itself.
function FreeWorkersController:RequestClaim(slot: number)
	if self._claiming then
		return
	end

	-- Looking is the whole point of the three, so a blind pick is sent back to the cards rather than taken
	for _, state in self._slots do
		if not state.Revealed then
			NotificationController:NotifyNormal({
				Text = "Check the other Workers to see what you got",
				Effect = "Error",
				Duration = 3,
				Sound = "Reject",
			})
			return
		end
	end

	self._claiming = true
	self.ClaimFreeWorkerEvent:FireServer(slot)

	-- Cleared by the result; this is only the backstop for one the server never answered
	task.delay(REQUEST_TIMEOUT, function()
		self._claiming = false
	end)
end

-- Thumps the Hired stamp down onto the card they took, from oversized to where it was authored.
function FreeWorkersController:_stampHired(state)
	state.Frame.Hire.Visible = false
	state.Frame.Hired.Visible = true

	state.StampScale.Scale = STAMP_START_SCALE
	TweenService:Create(state.StampScale, STAMP_SCALE_TWEEN, { Scale = 1 }):Play()

	-- Played flat rather than from the hut: it's their own pick, and they're stood right at it
	SoundController:PlaySound("Stamp")
end

-- Puts the three up: the backdrop fades in behind them while they spring up from under the screen.
function FreeWorkersController:Open()
	if not self.UI then
		return
	end

	local holder = self.UI.Holder
	local container = holder.Container

	self:_closeCards()

	-- Through UIController, so it shuts whatever else was up and the pad gets its cursor on the cards
	UIController:OpenFrame(holder)

	-- The backdrop only fades, so the entrance OpenFrame springs on it is stopped and replaced below
	Spr.stop(holder)
	Spr.stop(self._holderScale)
	holder.Position = holder:GetAttribute("OrigPosition")
	self._holderScale.Scale = 1

	holder.BackgroundTransparency = 1
	TweenService:Create(holder, BACKDROP_FADE_TWEEN, { BackgroundTransparency = self._backdropTransparency }):Play()

	-- Stopped before it is written: a spring left over from the last open keeps its own idea of where the
	-- cards are, and targeting it again would only re-goal that rather than send them back under the screen
	Spr.stop(container)
	container.Position = CONTAINER_CLOSED_POSITION
	Spr.target(container, CONTAINER_DAMPING, CONTAINER_FREQUENCY, { Position = CONTAINER_OPEN_POSITION })
end

function FreeWorkersController:OnInit()
	-- Timed out rather than waited on, since the loader runs every OnInit on one thread
	self.UI = PlayerGui:WaitForChild(FreeWorkers.UI_NAME, UI_TIMEOUT)

	if not self.UI then
		warn(`[FreeWorkers] PlayerGui.{FreeWorkers.UI_NAME} is missing, so the free Workers cannot be offered`)
	end
end

function FreeWorkersController:OnStart()
	if not self.UI then
		return
	end

	local holder = self.UI.Holder
	holder.Visible = false

	-- Read off the art before anything fades it, so the dim behind the cards is the authored one
	self._backdropTransparency = holder.BackgroundTransparency

	-- Made by OpenFrame on the first open if the art carries none, so it's resolved the same way here
	self._holderScale = holder:FindFirstChildOfClass("UIScale")
	if not self._holderScale then
		self._holderScale = Instance.new("UIScale")
		self._holderScale.Parent = holder
	end

	self._candidates = FreeWorkers.RollCandidates(LocalPlayer.UserId)

	-- Bound once here rather than per open: a hidden button can't be pressed, so the bindings stay live
	for slot, candidate in self._candidates do
		local frame = holder.Container[tostring(slot)]

		-- The stamp is the Icon inside the Hired frame where the art carries one, as the hiring board's cards do
		local stamp = frame.Hired:FindFirstChild("Icon") or frame.Hired
		local stampScale = stamp:FindFirstChildOfClass("UIScale")
		if not stampScale then
			stampScale = Instance.new("UIScale")
			stampScale.Parent = stamp
		end

		local state = {
			Frame = frame,
			Scale = frame.UIScale,
			StampScale = stampScale,
			Revealed = false,
			PortraitCleaner = self._cleaner:Construct(Trove),
			EffectCleaner = self._cleaner:Construct(Trove),
		}
		self._slots[slot] = state

		-- Button is laid over the whole card, so bringing one forward is a press anywhere on it. Only its
		-- effect is swapped as the selection moves; the press itself is bound once, so none is ever dropped
		UIController:BindButtonClick(frame.Button, function()
			self:SelectSlot(slot)
		end)

		self:_bindCardEffect(state)

		UIController:BindButtonClick(frame.Hire, function()
			self:RequestClaim(slot)
		end, true)

		UIController:BindButtonClick(frame.Info, function()
			WorkerGuideController:OpenRoleGuide(candidate.Role)
		end, true)

		-- A viewport measures zero until it's been laid out once, so the first framing waits for a size
		frame.ViewportFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			ViewportPortrait.Reframe(frame.ViewportFrame)
		end)

		self:_drawCard(slot)
	end

	-- Reported off the signal rather than Open, which toggles -- calling it on an open panel shuts it
	UIController.OnFrameOpened:Connect(function(frame)
		if frame == holder then
			self.FreeWorkersOpenedEvent:FireServer()
		end
	end)

	-- Every way out lands here, so one dismissed with the pad's B comes back on a fresh set of mysteries
	UIController.OnFrameClosed:Connect(function(frame)
		if frame == holder then
			self:_closeCards()
		end
	end)

	-- Made by the server on the first portrait it bakes, so it can land after this runs
	local function watchPortraits(folder: Instance)
		folder.ChildAdded:Connect(function()
			for slot in self._slots do
				self:_drawCard(slot)
			end
		end)

		for slot in self._slots do
			self:_drawCard(slot)
		end
	end

	local portraits = PlayerGui:FindFirstChild(FreeWorkers.PORTRAIT_FOLDER)
	if portraits then
		watchPortraits(portraits)
	else
		local connection
		connection = PlayerGui.ChildAdded:Connect(function(child)
			if child.Name == FreeWorkers.PORTRAIT_FOLDER then
				connection:Disconnect()
				watchPortraits(child)
			end
		end)
	end

	self.ClaimFreeWorkerResultEvent:OnClientEvent(function(success: boolean, slot: number)
		self._claiming = false

		local state = self._slots[slot]
		if not success or not state then
			return
		end

		self:_stampHired(state)

		-- Left up long enough to read as taken, then the hut's own panel, where they are equipped
		task.delay(CLOSE_DELAY, function()
			UIController:CloseFrame(holder)
			WorkerHutController:Open()

			-- This panel is done for good, so the three faces in its viewports go with it
			for _, cardState in self._slots do
				cardState.PortraitCleaner:Clean()
			end
		end)
	end)
end

return FreeWorkersController
