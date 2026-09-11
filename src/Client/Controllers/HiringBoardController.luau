-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Replica = require(Packages.Replica)
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local Employees = require(Shared.Config.Employees)
local HiringBoard = require(Shared.Config.HiringBoard)
local Rating = require(Shared.Config.Rating)

-- Modules
local ViewportPortrait = require(script.Parent.Parent.Modules.ViewportPortrait)

-- Components
local HeldItem = require(script.Parent.Parent.Components.HeldItem)

-- Controllers
local UIController
local CameraController
local InventoryController
local PlayerDataController
local SoundController

-- Assets
local UI = ReplicatedStorage.Assets.UI

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- How long a streamed-in stall gets to finish replicating the folders the board hangs off
local CHILD_TIMEOUT = 10

-- The featured entry's flight out and back. The prompt-slide pair, which reads as deliberate rather than snappy
local ENTRY_DAMPING = 0.9
local ENTRY_FREQUENCY = 4

-- The Hired stamp landing on a card: in oversized and clear, down to rest. The scale eases out with a little
-- give so it lands like a thump; the fade is quicker, so it's solid by the time it hits
local STAMP_START_SCALE = 1.4
local STAMP_SCALE_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local STAMP_FADE_TWEEN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Past this the entry panels stop drawing, which is what stops four viewports rendering for someone across the map
local ENTRY_MAX_DISTANCE = 80

-- The board's ScreenGui. In PlayerGui adorned back onto the world entries, which is what makes Hire clickable.
local function getScreenGui(): ScreenGui
	local playerGui = LocalPlayer.PlayerGui
	local screenGui = playerGui:FindFirstChild("HiringBoard")

	if screenGui == nil then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "HiringBoard"
		screenGui.ResetOnSpawn = false
		screenGui.Parent = playerGui
	end

	return screenGui
end

-- The worker board: four candidates on four parts, one of them flown out in front of the camera at a time. The roll is the server's and shared by every server; this only draws it, pages it, and asks to buy.
local HiringBoardController = {
	HireWorkerEvent = Network.Event("HireWorker"),
	HireWorkerResultEvent = Network.Event("HireWorkerResult"),

	_entries = {}, -- [slotIndex] = { Part, Home, Holder, Viewport, PortraitCleaner, StampTransparency, PendingStamp }
	_featured = 1, -- which slot is out in front of the camera
	_open = false,
	_replica = nil,
	_stall = nil,
	_previewFolder = nil,
	_prompt = nil, -- turned off while the board is up, so a second press can't fight the panel that's open

	_savedCamera = nil, -- where the camera was before the board took it, to hand back exactly
	_frozen = nil, -- the humanoid held still while the board is up, and the speed it was held at
	_hidden = nil, -- { Cleaner, Saved } while players are hidden, Saved being what each hidden instance held before

	_cleaner = Trove.new(),
}

-- This window's four, or an empty list until the replica lands.
function HiringBoardController:GetWorkers()
	return self._replica and self._replica.Data.Workers or {}
end

-- Whether this player has already taken `index` this window. Their own hires, not the server's -- the roll is shared, but who took it isn't.
function HiringBoardController:IsHired(index: number): boolean
	local board = PlayerDataController:GetKey("HiringBoard")

	-- A stale seed means the window rolled over and last window's ledger doesn't apply to this one
	if not board or not self._replica or board.Seed ~= self._replica.Data.Seed then
		return false
	end

	return board.Hired[index] == true
end

-- Puts this window's baked rig for `index` in the entry's viewport. The rigs land a beat after the roll does, so a mismatch here is normal and the folder's ChildAdded brings us back.
function HiringBoardController:_drawPortrait(index: number)
	local entry = self._entries[index]
	local preview = self._previewFolder and self._previewFolder:FindFirstChild(tostring(index))

	if not entry or not preview or preview:GetAttribute(HiringBoard.SEED_ATTRIBUTE) ~= self._replica.Data.Seed then
		return
	end

	entry.PortraitCleaner:Clean()
	entry.PortraitCleaner:Add(ViewportPortrait.Show(entry.Viewport, preview))
end

-- Thumps the Hired stamp down onto an entry's card, from oversized and clear to where it was authored.
function HiringBoardController:_stampHired(entry)
	local icon = entry.Holder.Hired.Icon

	icon.UIScale.Scale = STAMP_START_SCALE
	icon.ImageTransparency = 1

	TweenService:Create(icon.UIScale, STAMP_SCALE_TWEEN, { Scale = 1 }):Play()
	TweenService:Create(icon, STAMP_FADE_TWEEN, { ImageTransparency = entry.StampTransparency }):Play()

	-- Played flat rather than from the entry: it's the player's own purchase, and they're stood right at it
	SoundController:PlaySound("Stamp")
end

-- Paints one entry off the window's roll and this player's own ledger.
function HiringBoardController:_refreshEntry(index: number)
	local entry = self._entries[index]
	local worker = self:GetWorkers()[index]
	if not entry or not worker then
		return
	end

	local holder = entry.Holder

	holder.EmployeeName.Text = worker.Name
	holder.RoleName.Text = Employees.ROLE_NAMES[worker.Role]
	holder.Description.Text = Employees.ROLE_DESCRIPTIONS[worker.Role]
	holder.EmployeeRoleIcon.Image = Employees.ROLE_ICONS[worker.Role]
	holder.Price.Text = `${GuiUtil.ConvertNumberWithCommas(worker.Price)}`

	Rating.DrawStars(holder.Stars, worker.Stars)
	holder.Rating.Text = Rating.FormatStars(worker.Stars)

	-- A hidden button can't be pressed, so visibility is the whole of what turns hiring off. It stays
	-- pressable when they can't afford it, so the server is the one that says why
	local hired = self:IsHired(index)
	holder.Hired.Visible = hired
	holder.Hire.Visible = not hired

	-- Authored hidden, so it has to be switched on with the frame rather than left to show on its own
	holder.Hired.Icon.Visible = hired

	-- Stamped only for a hire made just now. Every other way this reads as hired -- a join, a reopen -- shows
	-- it at rest, or walking up to the board would thump down every stamp it already has. Waits on the data
	-- landing rather than the hire's answer, since the two arrive in either order
	if hired and entry.PendingStamp then
		entry.PendingStamp = false
		self:_stampHired(entry)
	end

	self:_drawPortrait(index)
end

function HiringBoardController:Refresh()
	for index = 1, HiringBoard.ENTRY_COUNT do
		self:_refreshEntry(index)
	end
end

-- Asks for the candidate in `index`. The slot number is all that goes out -- the server rolled these and re-reads its own.
function HiringBoardController:RequestHire(index: number)
	if self:IsHired(index) then
		return
	end

	self.HireWorkerEvent:FireServer(index)
end

-- Flies `index` out to the pose in front of the camera and sends whatever was out back to the board.
function HiringBoardController:_feature(index: number)
	local previous = self._entries[self._featured]
	if previous and self._featured ~= index then
		Spr.target(previous.Part, ENTRY_DAMPING, ENTRY_FREQUENCY, { Pivot = previous.Home })
	end

	self._featured = index

	local entry = self._entries[index]
	if entry and self._featurePose then
		Spr.target(entry.Part, ENTRY_DAMPING, ENTRY_FREQUENCY, { Pivot = self._featurePose })
	end
end

-- Moves the featured entry `step` along, wrapping, so neither arrow ever needs a dead state.
function HiringBoardController:Page(step: number)
	if not self._open then
		return
	end

	local count = HiringBoard.ENTRY_COUNT
	self:_feature((self._featured - 1 + step) % count + 1)
end

-- Puts every entry back exactly where it was authored. Stopped before it's written, or a spring still running would overwrite the home it was just set to.
function HiringBoardController:_returnEntries()
	for _, entry in self._entries do
		Spr.stop(entry.Part)
		entry.Part:PivotTo(entry.Home)
	end
end

-- Holds the player still while the board is up, so the camera can be handed back exactly where it was taken.
function HiringBoardController:_setFrozen(frozen: boolean)
	if not frozen then
		local held = self._frozen
		self._frozen = nil

		-- Dropped rather than restored if they've respawned since: that humanoid is gone either way
		if held and held.Humanoid.Parent then
			held.Humanoid.WalkSpeed = held.WalkSpeed
			held.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end

		return
	end

	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	self._frozen = { Humanoid = humanoid, WalkSpeed = humanoid.WalkSpeed }
	humanoid.WalkSpeed = 0
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
end

-- Hides `root` and everything under it for the session, including whatever lands under it while the board is up.
function HiringBoardController:_hideDescendants(root: Instance)
	local hidden = self._hidden
	local saved = hidden.Saved

	local function hide(instance: Instance)
		-- Already saved means the value on it now is ours, and saving that would restore it hidden
		if saved[instance] ~= nil then
			return
		end

		-- The local modifier rather than Transparency, so a write the game makes mid-session isn't clobbered on restore
		if instance:IsA("BasePart") or instance:IsA("Decal") then
			saved[instance] = instance.LocalTransparencyModifier
			instance.LocalTransparencyModifier = 1
		elseif instance:IsA("BillboardGui") then
			saved[instance] = instance.Enabled
			instance.Enabled = false
		end
	end

	hide(root)
	for _, descendant in root:GetDescendants() do
		hide(descendant)
	end

	hidden.Cleaner:Connect(root.DescendantAdded, hide)
end

-- Hides every player, their name tag and whatever they're carrying while the board is up, so nobody stood in front of it blocks the camera.
function HiringBoardController:_setPlayersHidden(hidden: boolean)
	if not hidden then
		local held = self._hidden
		self._hidden = nil

		if not held then
			return
		end

		-- Cleaned before restoring, so nothing arriving mid-restore gets hidden again
		held.Cleaner:Destroy()

		-- Restored off what was saved rather than a fresh sweep, so a tool unequipped mid-session still comes back
		for instance, value in held.Saved do
			if instance:IsA("BillboardGui") then
				instance.Enabled = value
			else
				instance.LocalTransparencyModifier = value
			end
		end

		return
	end

	local cleaner = Trove.new()
	self._hidden = { Cleaner = cleaner, Saved = {} }

	local function hidePlayer(player: Player)
		if player.Character then
			self:_hideDescendants(player.Character)
		end

		cleaner:Connect(player.CharacterAdded, function(character: Model)
			self:_hideDescendants(character)
		end)
	end

	for _, player in Players:GetPlayers() do
		hidePlayer(player)
	end
	cleaner:Connect(Players.PlayerAdded, hidePlayer)

	-- The server hangs name tags off Terrain rather than the character, so they're found by the template's name
	local overheadName = UI.OverheadUI.Name

	local function hideOverhead(child: Instance)
		if child.Name == overheadName then
			self:_hideDescendants(child)
		end
	end

	for _, child in workspace.Terrain:GetChildren() do
		hideOverhead(child)
	end
	cleaner:Connect(workspace.Terrain.ChildAdded, hideOverhead)

	for _, model in CollectionService:GetTagged(HeldItem.MODEL_TAG) do
		self:_hideDescendants(model)
	end
	cleaner:Connect(CollectionService:GetInstanceAddedSignal(HeldItem.MODEL_TAG), function(model: Instance)
		self:_hideDescendants(model)
	end)
end

-- Takes the camera to the board and flies the first candidate out. Driven off OnFrameOpened rather than Open, which toggles.
function HiringBoardController:_beginSession()
	if self._open or not self._stall then
		return
	end

	self._open = true
	self._savedCamera = CameraController:GetCameraState()

	-- Off while they're reading it: they're stood inside its range with nothing to walk away to, so leaving
	-- it up would hang a "View Workers" over a board already being viewed
	if self._prompt then
		self._prompt.Enabled = false
	end

	-- Nothing here is held or used, and the hotbar sits right where the entry flies out to
	InventoryController:HideInventory()

	self:_setFrozen(true)
	self:_setPlayersHidden(true)

	if self._cameraPose then
		CameraController:TweenCameraCFrameTo(self._cameraPose)
	end

	self:Refresh()
	self:_feature(self._featured)
end

-- Hands the camera and every entry back. Travelled on the way in and cut on the way out: the character hasn't moved, so the cut lands exactly where they were looking, and nothing can be left holding the camera.
function HiringBoardController:_endSession()
	if not self._open then
		return
	end

	self._open = false

	if self._prompt then
		self._prompt.Enabled = true
	end

	InventoryController:ShowInventory()

	self:_setFrozen(false)
	self:_setPlayersHidden(false)
	self:_returnEntries()

	local saved = self._savedCamera
	self._savedCamera = nil

	if saved then
		CameraController:SetBackToDefault(saved.CFrame)
	end
end

-- Answers the prompt. OpenFrame shuts whatever else was up, and its own OnFrameClosed is what tears this down.
function HiringBoardController:Open()
	if not self.UI or not self._stall then
		return
	end

	UIController:OpenFrame(self.UI.Holder)
end

-- Writes the window's time left onto the board's own billboard.
function HiringBoardController:_refreshTimer()
	if not self._timerLabel then
		return
	end

	self._timerLabel.Text =
		HiringBoard.FormatTimeLeft(ReplicatedStorage:GetAttribute(HiringBoard.TIME_LEFT_ATTRIBUTE) or 0)
end

-- Puts one panel up per entry part and wires its Hire button. Done once; what's drawn on them is Refresh's job.
function HiringBoardController:_mountEntries(entries: Instance)
	local template = UI:FindFirstChild(HiringBoard.INFO_UI)
	if not template then
		warn(`[HiringBoard] no Assets.UI.{HiringBoard.INFO_UI}, the board can't show anyone`)
		return
	end

	for index = 1, HiringBoard.ENTRY_COUNT do
		local part = entries:FindFirstChild(tostring(index))
		if not part then
			warn(`[HiringBoard] {HiringBoard.ENTRIES_FOLDER} has no {index}, that slot won't show`)
			continue
		end

		local gui = self._cleaner:Clone(template)
		gui.Adornee = part
		gui.Active = true
		gui.MaxDistance = ENTRY_MAX_DISTANCE
		gui.Parent = getScreenGui()

		local holder = gui.Holder

		-- Bound once, at mount. Rebuilding a binding under a player mid-press would drop the press
		local binding = UIController:BindButtonClick(holder.Hire, function()
			self:RequestHire(index)
		end, true)
		self._cleaner:Add(binding.Disconnect)

		local entry = {
			Part = part,
			-- Cached before anything moves it, and as the pivot rather than the CFrame: a spring's Pivot goal
			-- routes through PivotTo, so a part with a pivot offset would drift a little every open and close
			Home = part:GetPivot(),
			Holder = holder,
			Viewport = holder.ViewportFrame,
			PortraitCleaner = self._cleaner:Construct(Trove),
			-- Read off the template before anything animates it, so the stamp settles where the art put it
			StampTransparency = holder.Hired.Icon.ImageTransparency,
			PendingStamp = false, -- set by a hire going through, spent by the refresh that first shows it hired
		}

		-- A viewport measures zero until it's been laid out once, so the first framing has to wait for a size
		self._cleaner:Connect(entry.Viewport:GetPropertyChangedSignal("AbsoluteSize"), function()
			ViewportPortrait.Reframe(entry.Viewport)
		end)

		self._entries[index] = entry
	end
end

-- Finds the stall, hangs the prompt and countdown off its board, and mounts the entries. Waits on its own thread, since the loader runs every OnStart on one.
function HiringBoardController:_setupStall()
	local stalls = workspace:WaitForChild(HiringBoard.STALL_FOLDER, CHILD_TIMEOUT)
	local stall = stalls and stalls:WaitForChild(HiringBoard.STALL_NAME, CHILD_TIMEOUT)
	local board = stall and stall:WaitForChild(HiringBoard.BOARD_NAME, CHILD_TIMEOUT)
	local entries = stall and stall:WaitForChild(HiringBoard.ENTRIES_FOLDER, CHILD_TIMEOUT)

	if not board or not entries then
		warn(`[HiringBoard] {HiringBoard.STALL_NAME} never replicated, the board won't open`)
		return
	end

	self._stall = stall

	-- Authored poses rather than ones derived off the camera: the camera is still springing while the entry
	-- flies, and chasing it would have the two settle against each other
	local cameraAttachment = board:FindFirstChild(HiringBoard.CAMERA_ATTACHMENT)
	local featureAttachment = board:FindFirstChild(HiringBoard.FEATURE_ATTACHMENT)

	if not cameraAttachment or not featureAttachment then
		warn(
			`[HiringBoard] {HiringBoard.BOARD_NAME} needs a {HiringBoard.CAMERA_ATTACHMENT} and a {HiringBoard.FEATURE_ATTACHMENT}`
		)
	end

	self._cameraPose = cameraAttachment and cameraAttachment.WorldCFrame
	self._featurePose = featureAttachment and featureAttachment.WorldCFrame

	self:_mountEntries(entries)
	self:Refresh()

	local timerAttachment = board:FindFirstChild(HiringBoard.TIMER_ATTACHMENT)
	local billboard = timerAttachment and timerAttachment:FindFirstChild(HiringBoard.TIMER_BILLBOARD)
	self._timerLabel = billboard and billboard:FindFirstChild(HiringBoard.TIMER_LABEL)

	if self._timerLabel then
		self._timerLabel.RichText = true
		self:_refreshTimer()
	end

	-- On the attachment rather than the model, since a prompt parented to a Model never fires at all
	local promptAttachment = board:FindFirstChild(HiringBoard.PROMPT_ATTACHMENT)
	if not promptAttachment then
		warn(`[HiringBoard] {HiringBoard.BOARD_NAME} has no {HiringBoard.PROMPT_ATTACHMENT}, it can't be opened`)
		return
	end

	local prompt = self._cleaner:Add(Instance.new("ProximityPrompt"))
	prompt.ActionText = HiringBoard.PROMPT_ACTION_TEXT
	prompt.HoldDuration = HiringBoard.PROMPT_HOLD_DURATION
	prompt.MaxActivationDistance = HiringBoard.PROMPT_MAX_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Parent = promptAttachment
	self._prompt = prompt

	-- Built after the panel could already be open, if another frame opened it first
	prompt.Enabled = not self._open

	self._cleaner:Connect(prompt.Triggered, function()
		self:Open()
	end)
end

function HiringBoardController:OnInit()
	UIController = require(script.Parent.UIController)
	CameraController = require(script.Parent.CameraController)
	InventoryController = require(script.Parent.InventoryController)
	PlayerDataController = require(script.Parent.PlayerDataController)
	SoundController = require(script.Parent.SoundController)

	self.UI = PlayerGui:WaitForChild(HiringBoard.SCREEN_UI)

	Replica.OnNew("HiringBoard", function(replica)
		self._replica = replica

		replica:OnChange(function()
			self:Refresh()
		end)

		self:Refresh()
	end)
end

function HiringBoardController:OnStart()
	local holder = self.UI.Holder
	holder.Visible = false

	UIController:BindButtonClick(holder.Forward, function()
		self:Page(1)
	end, true)

	UIController:BindButtonClick(holder.Back, function()
		self:Page(-1)
	end, true)

	UIController:BindButtonClick(holder.Exit, function()
		UIController:CloseFrame(holder)
	end, true)

	-- Both halves ride the frame's own signals: OpenFrame shuts whatever else was up, so another panel
	-- opening has to tear this down too, and Exit is only one of the ways it can close
	UIController.OnFrameOpened:Connect(function(frame)
		if frame == holder then
			self:_beginSession()
		end
	end)

	UIController.OnFrameClosed:Connect(function(frame)
		if frame == holder then
			self:_endSession()
		end
	end)

	-- A respawn wants its camera the same frame, so this hands back without waiting for a spring to settle
	local function watchCharacter(character: Model)
		local humanoid = character:WaitForChild("Humanoid", CHILD_TIMEOUT)
		if not humanoid then
			return
		end

		humanoid.Died:Connect(function()
			self:_endSession()
			UIController:CloseFrame(holder)
		end)
	end

	if LocalPlayer.Character then
		task.spawn(watchCharacter, LocalPlayer.Character)
	end

	LocalPlayer.CharacterAdded:Connect(function(character: Model)
		-- Guarded on it being up, since CloseFrame springs the FOV back whether it was or not, and this fires
		-- on an ordinary spawn too
		if self._open then
			self:_endSession()
			UIController:CloseFrame(holder)
		end

		task.spawn(watchCharacter, character)
	end)

	ReplicatedStorage:GetAttributeChangedSignal(HiringBoard.TIME_LEFT_ATTRIBUTE):Connect(function()
		self:_refreshTimer()
	end)

	-- The portraits are dressed after the roll is published, so they arrive a beat behind it
	task.spawn(function()
		self._previewFolder = ReplicatedStorage:WaitForChild(HiringBoard.PREVIEW_FOLDER, CHILD_TIMEOUT)
		if not self._previewFolder then
			return
		end

		self._previewFolder.ChildAdded:Connect(function()
			self:Refresh()
		end)

		self:Refresh()
	end)

	-- Waits on the stall replicating, so it's kept off the loader's one thread
	task.spawn(function()
		self:_setupStall()
	end)

	-- Spawned, since GetKey and ListenForChange both await the data replica
	task.spawn(function()
		PlayerDataController:ListenForChange("HiringBoard", function()
			self:Refresh()
		end)

		self:Refresh()
	end)

	self.HireWorkerResultEvent:OnClientEvent(function(success: boolean, index: number)
		local entry = self._entries[index]
		if not success or not entry then
			return
		end

		entry.PendingStamp = true
		self:_refreshEntry(index)
	end)
end

return HiringBoardController
