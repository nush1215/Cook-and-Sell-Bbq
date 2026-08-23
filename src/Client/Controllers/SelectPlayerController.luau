--[[
    The "who are you buying this for?" list, shared by anything that gifts.

    Opens as an independent frame, so it stacks on top of whatever asked for it rather than replacing
    it -- the shop hides itself for the pick and shows itself again either way. The caller hands over
    two callbacks and the picker guarantees exactly one of them runs: onSelected when a player is
    chosen, onClosed when the list is dismissed instead.

    The list is kept live rather than rebuilt on open: a player who joins mid-pick appears, and one
    who leaves has their row pulled, so a gift can't be aimed at somebody who is already gone.
]]

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

-- Opens the picker and calls `onSelected` with whoever is chosen. Dismissing the list instead --
-- the exit button, or another frame replacing this one -- drops the request and calls `onClosed`,
-- so a caller that hid itself for the pick always has something to bring it back.
-- @param onSelected Runs with the chosen player
-- @param onClosed Runs instead if the picker is dismissed without a choice
function SelectPlayerController:StartSelectPlayer(onSelected: (player: Player) -> (), onClosed: () -> ())
	self._selectionCallback = onSelected
	self._closedCallback = onClosed

	UIController:OpenFrame(self.UI.Holder, true)
end

-- Closes the picker and drops any pending request, running the caller's onClosed. Safe to call on an
-- already-closed picker, which is what lets every way of dismissing it come through here.
function SelectPlayerController:StopSelectPlayer()
	local closedCallback = self._closedCallback

	-- Both cleared before the frame closes, because closing re-enters this through OnFrameClosed --
	-- and by then there has to be nothing left to run, or the callback would fire twice.
	self._selectionCallback = nil
	self._closedCallback = nil

	if self.UI.Holder.Visible then
		UIController:CloseFrame(self.UI.Holder)
	end

	if closedCallback then
		task.spawn(closedCallback)
	end
end

-- Takes the pending callback before closing, since closing is what clears it, then runs it with the
-- player whose row was pressed.
function SelectPlayerController:_selectPlayer(player: Player)
	local selectionCallback = self._selectionCallback

	-- The dismissal callback is dropped rather than run: this was a choice, not a cancel, so exactly
	-- one of the caller's two callbacks fires and onSelected is what puts them back on screen.
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

	-- The thumbnail is a web call, so it's fetched off the build and dropped if the row it was for has
	-- since been recycled -- otherwise a player who left mid-fetch would stamp their face on whoever
	-- took their place in the list.
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

	-- Reconciles the list against who's actually in the server: rows for players still here are
	-- re-ordered in place rather than rebuilt, so a join doesn't flicker the whole list.
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

		-- Collected first, then removed: dropping entries out of the table being walked isn't safe.
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

	-- Any close at all ends the request, including one this controller didn't ask for -- another frame
	-- opening over the picker. Routed through StopSelectPlayer rather than just clearing the selection,
	-- so a caller that hid itself for the pick is brought back however the picker went away.
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
