-- The shared "who are you buying this for?" picker. Opens independently, guarantees exactly one of onSelected/onClosed runs, and keeps its list live so a gift can't be aimed at someone already gone.

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Controllers
local UIController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

--
local SelectPlayerController = {
	_playerFrames = {}, -- [userId] = that player's cloned row
	_playerFrameCleaners = {}, -- [userId] = the row's own Trove, holding its button binding
	_uiCleaner = Trove.new(),

	_selectionCallback = nil,
	_closedCallback = nil,
}

-- Opens the picker, calling `onSelected` with the choice or `onClosed` if it's dismissed -- exactly one runs.
function SelectPlayerController:StartSelectPlayer(onSelected: (player: Player) -> (), onClosed: () -> ())
	self._selectionCallback = onSelected
	self._closedCallback = onClosed

	UIController:OpenFrame(self.UI.Holder, true)
end

-- Closes the picker and runs the caller's onClosed. Safe on an already-closed one, so every dismissal comes through here.
function SelectPlayerController:StopSelectPlayer()
	local closedCallback = self._closedCallback

	-- Cleared before the close, which re-enters this through OnFrameClosed and would fire the callback twice
	self._selectionCallback = nil
	self._closedCallback = nil

	if self.UI.Holder.Visible then
		UIController:CloseFrame(self.UI.Holder)
	end

	if closedCallback then
		task.spawn(closedCallback)
	end
end

-- Takes the callback before closing, which clears it, then runs it with the player whose row was pressed.
function SelectPlayerController:_selectPlayer(player: Player)
	local selectionCallback = self._selectionCallback

	-- Dropped rather than run: this was a choice, so onSelected is what puts the caller back on screen
	self._closedCallback = nil
	self:StopSelectPlayer()

	if selectionCallback then
		task.spawn(selectionCallback, player)
	end
end

function SelectPlayerController:_initUI()
	local holder = self.UI.Holder
	local container = holder.Container.ScrollingFrame
	local template = container.PlayerFrameTemplate

	template.Visible = false

	-- A web call, so it's dropped if the row was recycled -- otherwise a leaver stamps their face on a stranger
	local function setPlayerIcon(playerFrame: Frame, userId: number)
		task.spawn(function()
			local success, image = pcall(
				Players.GetUserThumbnailAsync,
				Players,
				userId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size100x100
			)

			if success and self._playerFrames[userId] == playerFrame then
				playerFrame.PlayerIcon.Image = image
			end
		end)
	end

	local function updatePlayerFrame(playerFrame: Frame, player: Player, layoutOrder: number)
		playerFrame.LayoutOrder = layoutOrder
		playerFrame.PlayerDisplayName.Text = player.DisplayName
		playerFrame.PlayerUserName.Text = `@{player.Name}`
	end

	local function removePlayerFrame(userId: number)
		local playerFrame = self._playerFrames[userId]
		if not playerFrame then
			return
		end

		local frameCleaner = self._playerFrameCleaners[userId]
		if frameCleaner then
			frameCleaner:Destroy()
			self._playerFrameCleaners[userId] = nil
		end

		playerFrame:Destroy()
		self._playerFrames[userId] = nil
	end

	local function createPlayerFrame(player: Player, layoutOrder: number)
		local userId = player.UserId
		local playerFrame = template:Clone()
		local frameCleaner = Trove.new()

		playerFrame.Name = `PlayerFrame_{userId}`
		playerFrame.Visible = true
		playerFrame.Parent = container

		self._playerFrames[userId] = playerFrame
		self._playerFrameCleaners[userId] = frameCleaner

		updatePlayerFrame(playerFrame, player, layoutOrder)
		setPlayerIcon(playerFrame, userId)

		frameCleaner:Add(UIController:BindButtonClick(playerFrame.Button, function()
			self:_selectPlayer(player)
		end, true, false, { ShowFrame = playerFrame, ButtonDownScale = 0.98, ButtonHoverscale = 1.02 }).Disconnect)
	end

	-- Reconciled rather than rebuilt, so a join doesn't flicker the whole list
	local function syncPlayers()
		local activeUserIds = {}
		local staleUserIds = {}
		local layoutOrder = 0

		for _, player in Players:GetPlayers() do
			if player == LocalPlayer then
				continue
			end

			local userId = player.UserId
			activeUserIds[userId] = true
			layoutOrder += 1

			local playerFrame = self._playerFrames[userId]
			if playerFrame then
				updatePlayerFrame(playerFrame, player, layoutOrder)
			else
				createPlayerFrame(player, layoutOrder)
			end
		end

		-- Collected first, then removed: dropping entries out of the table being walked isn't safe
		for userId in self._playerFrames do
			if not activeUserIds[userId] then
				table.insert(staleUserIds, userId)
			end
		end

		for _, userId in staleUserIds do
			removePlayerFrame(userId)
		end
	end

	self._uiCleaner:Add(UIController:BindButtonClick(holder.Exit, function()
		self:StopSelectPlayer()
	end, true).Disconnect)

	self._uiCleaner:Add(Players.PlayerAdded:Connect(syncPlayers))

	self._uiCleaner:Add(Players.PlayerRemoving:Connect(function(player: Player)
		removePlayerFrame(player.UserId)
	end))

	-- Any close ends the request, routed through StopSelectPlayer so a hidden caller is always brought back
	self._uiCleaner:Add(UIController.OnFrameClosed:Connect(function(frame)
		if frame == self.UI.Holder then
			self:StopSelectPlayer()
		end
	end))

	syncPlayers()
end

function SelectPlayerController:OnInit()
	UIController = require(script.Parent.UIController)

	self.UI = PlayerGui:WaitForChild("SelectPlayerUI")
end

function SelectPlayerController:OnStart()
	self.UI.Holder.Visible = false

	task.spawn(SelectPlayerController._initUI, self)
end

return SelectPlayerController
