-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local TopbarPlus = require(Packages.TopbarPlus)
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local UpdateLogs = require(Shared.Config.UpdateLogs)
local Keywords = require(Shared.Config.Keywords)

-- Controllers
local UIController = require(script.Parent.UIController)
local PlayerDataController = require(script.Parent.PlayerDataController)
local OfflineEarningController = require(script.Parent.OfflineEarningController)

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- The loader runs every OnInit on one thread, so this waits with a timeout rather than hanging the boot
local UI_TIMEOUT = 10

-- Where the button sits among the top bar's: after the Daily Rewards button's 4
local TOPBAR_ORDER = 5

-- What changed in each update: one button per update down the side, and the picked one's changes beside it. A returning player is shown the newest once, on join.

--
local UpdateLogController = {
	MarkUpdateLogSeenEvent = Network.Event("MarkUpdateLogSeen"), -- client -> server ()

	_titleTemplate = nil, -- the detached change line, cloned once per change
	_changeLines = Trove.new(), -- the shown update's change lines, cleaned out when another is picked
}

-- Puts `log`'s title and one line per change in the details pane.
function UpdateLogController:ShowUpdateLog(log: UpdateLogs.UpdateLog)
	local details = self.UI.Holder.LogsDetailsContainer
	local scrollingFrame = details.ScrollingFrame

	details.UpdateTitle.Text = log.Title
	self._changeLines:Clean()

	for order, change in log.Changes do
		local line = self._changeLines:Clone(self._titleTemplate)
		line.Name = `Change{order}`
		line.LayoutOrder = order
		line.Text = Keywords.Highlight(change)
		line.Visible = true
		line.Parent = scrollingFrame
	end

	scrollingFrame.CanvasPosition = Vector2.zero
end

-- Tells the server the newest update's log has been seen, unless it's already stamped.
function UpdateLogController:MarkNewestUpdateLogSeen()
	if PlayerDataController:GetKey("LastSeenUpdateLog") ~= UpdateLogs.Data[1].Title then
		self.MarkUpdateLogSeenEvent:FireServer()
	end
end

function UpdateLogController:OnInit()
	-- Timed out rather than waited on, since the loader runs every OnInit on one thread
	self.UI = PlayerGui:WaitForChild(UpdateLogs.UI_NAME, UI_TIMEOUT)

	if not self.UI then
		warn(`[UpdateLog] PlayerGui.{UpdateLogs.UI_NAME} is missing, so the update log can't be shown`)
	end
end

function UpdateLogController:OnStart()
	if not self.UI then
		return
	end

	local holder = self.UI.Holder
	holder.Visible = false

	local logContainer = holder.LogsContainer.Container
	local logTemplate = logContainer.LogTemplate
	logTemplate.Parent = nil

	local titleTemplate = holder.LogsDetailsContainer.ScrollingFrame.TitleTemplate
	titleTemplate.Parent = nil
	titleTemplate.RichText = true
	self._titleTemplate = titleTemplate

	for order, log in UpdateLogs.Data do
		local button = logTemplate:Clone()
		button.Name = log.Title
		button.LayoutOrder = order
		button.Icon.Image = log.Icon
		button.Title.Text = log.Title
		button.Visible = true
		button.Parent = logContainer

		-- The button is what picks the update, so a Frame authored in its place can't switch to it
		if button:IsA("GuiButton") then
			UIController:BindButtonClick(button, function()
				self:ShowUpdateLog(log)
			end, true)
		else
			warn(`UpdateLogsUI's LogTemplate is a {button.ClassName}, not a GuiButton, so only the newest update can be shown`)
		end
	end

	self:ShowUpdateLog(UpdateLogs.Data[1])

	-- oneClick keeps it momentary; autoDeselect is off, or pressing it would un-mute the game, as the Codes button notes
	local icon = TopbarPlus.new()
	icon:setCaption("Update Log")
	icon:setImage(UpdateLogs.TOPBAR_ICON)
	icon:autoDeselect(false)
	icon:oneClick(true)
	icon:setOrder(TOPBAR_ORDER)
	icon:align("Right")

	icon.selected:Connect(function()
		UIController:OpenFrame(holder)
	end)

	UIController:BindButtonClick(holder.Exit, function()
		UIController:CloseFrame(holder)
	end, true)

	-- Stamped once it's on screen rather than when queued, so a player who leaves before it comes up still gets it
	UIController.OnFrameOpened:Connect(function(frame)
		if frame == holder then
			self:MarkNewestUpdateLogSeen()
		end
	end)

	PlayerDataController:GetReplica()
		:andThen(function(replica)
			-- Stood on their base first, and behind the offline earnings panel, as the daily rewards wait
			while LocalPlayer:GetAttribute("BaseId") == nil do
				LocalPlayer:GetAttributeChangedSignal("BaseId"):Wait()
			end

			OfflineEarningController:WaitForJoinClaim()

			-- Read after the wait, so one opened by hand meanwhile isn't put up a second time. New players are stamped on load
			if replica.Data.LastSeenUpdateLog == UpdateLogs.Data[1].Title then
				return
			end

			-- Deferred so the daily rewards, resumed off the same signal, queue ahead of it
			task.defer(function()
				UIController:OpenFrameWhenFree(holder)
			end)
		end)
		:catch(warn)
end

return UpdateLogController
