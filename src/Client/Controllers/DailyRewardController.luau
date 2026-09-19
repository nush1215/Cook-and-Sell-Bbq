-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local TopbarPlus = require(Packages.TopbarPlus)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local DailyRewards = require(Shared.Config.DailyRewards)
local FreeWorkers = require(Shared.Config.FreeWorkers)
local Keywords = require(Shared.Config.Keywords)

-- Controllers
local UIController = require(script.Parent.UIController)
local PlayerDataController = require(script.Parent.PlayerDataController)
local FreeWorkersController = require(script.Parent.FreeWorkersController)
local TutorialCrateController = require(script.Parent.TutorialCrateController)
local ShopController = require(script.Parent.ShopController)
local OfflineEarningController = require(script.Parent.OfflineEarningController)

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- The loader runs every OnInit on one thread, so this waits with a timeout rather than hanging the boot
local UI_TIMEOUT = 10

-- How long a claim stays locked after it's asked for, in case the server's answer never lands
local REQUEST_TIMEOUT = 3

-- Seconds between countdown redraws, on the synced clock
local TIMER_INTERVAL = 0.5

-- How long after the tutorial's crate lands a new player's first week comes up
local FIRST_OPEN_DELAY = 2

-- The component pulsing the unlocked day's exclamation
local POP_TAG = "UIPop"

-- The Products entry that unlocks the next day early
local SKIP_DAY_PRODUCT = "SkipDay"

-- Where the button sits among the top bar's: after the Codes button's 3
local TOPBAR_ORDER = 4

-- The top bar badge's fill and count while a day is waiting
local NOTICE_COLOR = Color3.fromRGB(255, 0, 0)
local NOTICE_TEXT_COLOR = Color3.fromRGB(255, 255, 255)

-- The Claimed stamp landing on a tile: in oversized, down to rest like a thump, as the worker cards' Hired stamp does
local STAMP_START_SCALE = 1.4
local STAMP_SCALE_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- The week of daily rewards, one tile a day. The server holds the claim; this draws the week off the replicated count and stamp, counts down to the next day, and puts the panel up when one is waiting.

--
local DailyRewardController = {
	ClaimDailyRewardEvent = Network.Event("ClaimDailyReward"), -- client -> server (slotIndex?)
	ClaimDailyRewardResultEvent = Network.Event("ClaimDailyRewardResult"), -- server -> client (success, slotIndex?)

	_tiles = {}, -- [day] = { Button, Claimed?, ClaimedScale?, BuxGradient? }
	_icon = nil, -- the top bar button
	_ready = false, -- whether the next day is unlocked, as the tiles were last drawn
	_claimedThisWeek = 0, -- how many tiles the board last drew stamped
	_stampDay = nil, -- a day just claimed, its stamp waiting for the panel to be on screen
	_claiming = false, -- the client half of the debounce; the server holds the authoritative one
}

-- Draws the week off the replicated count and stamp: every tile's reward and Claimed stamp, the unlocked day's rays and exclamation, and the top bar's badge.
function DailyRewardController:RefreshDailyRewards()
	local data = PlayerDataController:GetData()
	local claimedCount = data.DailyRewardStreak
	local ready = workspace:GetServerTimeNow() >= data.LastDailyRewardClaim + DailyRewards.CLAIM_INTERVAL

	local weekLength = #DailyRewards.Days
	local claimedThisWeek = claimedCount % weekLength

	-- A finished week stays on the board, stamped, until the next week's first day unlocks
	if claimedThisWeek == 0 and claimedCount > 0 and not ready then
		claimedThisWeek = weekLength
	end

	local weekStart = claimedCount - claimedThisWeek
	self._claimedThisWeek = claimedThisWeek

	for day, tile in self._tiles do
		local button = tile.Button
		local reward = DailyRewards.GetReward(LocalPlayer.UserId, weekStart + day - 1)
		local title, icon = DailyRewards.GetRewardDisplay(reward)

		button.Title.Text = title

		-- A reward whose config has no image keeps the one authored on the tile
		if icon then
			button.Icon.Image = icon
		end

		if tile.BuxGradient then
			tile.BuxGradient.Enabled = reward.Type == "Bux"
		end

		if tile.Claimed then
			tile.Claimed.Visible = day <= claimedThisWeek
		end

		-- The rays and their spin are authored in Studio, so only the exclamation marks the unlocked day
		button.Exclamation.Visible = ready and day == claimedThisWeek + 1
	end

	if ready == self._ready then
		return
	end
	self._ready = ready

	-- Cleared only by clearNotices: left to its default, the badge would go on the deselect oneClick fires every press
	if ready then
		self._icon:notify(self._icon.endNotices)
	else
		self._icon:clearNotices()
	end
end

-- Thumps a just-claimed day's Claimed stamp down, oversized to where it was authored, once the panel is on screen to show it.
function DailyRewardController:_stampClaimedDay()
	local day = self._stampDay
	if not day or not self.UI.Holder.Visible then
		return
	end
	self._stampDay = nil

	local stampScale = self._tiles[day].ClaimedScale
	if not stampScale then
		return
	end

	stampScale.Scale = STAMP_START_SCALE
	TweenService:Create(stampScale, STAMP_SCALE_TWEEN, { Scale = 1 }):Play()
end

-- Offers the SkipDay product while the next day is still counting down. Once it's unlocked there's nothing to skip.
function DailyRewardController:PromptSkipDailyRewardWait()
	if not self._ready then
		ShopController:PromptProductPurchaseFromId(SKIP_DAY_PRODUCT)
	end
end

-- Claims `day` if it's the one unlocked. A worker day puts its three cards up instead, and the pick is the claim; a day still locked offers the skip.
function DailyRewardController:RequestClaimDailyReward(day: number)
	if self._claiming then
		return
	end

	-- A stamped tile is spent, so only one still to come is worth skipping to
	if not self._ready then
		if day > self._claimedThisWeek then
			self:PromptSkipDailyRewardWait()
		end
		return
	end

	local claimedCount = PlayerDataController:GetKey("DailyRewardStreak")
	if day ~= DailyRewards.GetDay(claimedCount) then
		return
	end

	local reward = DailyRewards.GetReward(LocalPlayer.UserId, claimedCount)

	if reward.Type == "Worker" then
		local holder = self.UI.Holder
		local seed = DailyRewards.GetSeed(LocalPlayer.UserId, claimedCount)

		-- The cards hold their own debounce, and send only which of the three was picked
		FreeWorkersController:OpenOffer({
			Candidates = FreeWorkers.RollCandidates(seed, reward.Stars),
			PortraitFolder = DailyRewards.PORTRAIT_FOLDER,
			RequestHire = function(slot: number)
				self.ClaimDailyRewardEvent:FireServer(slot)
			end,
			-- Back to the week, where the day's Claimed stamp lands
			OnHired = function()
				UIController:OpenFrame(holder)
			end,
		})
		return
	end

	self._claiming = true
	self.ClaimDailyRewardEvent:FireServer()

	-- Cleared by the result; this is only the backstop for one the server never answered
	task.delay(REQUEST_TIMEOUT, function()
		self._claiming = false
	end)
end

-- Puts the week up once no other panel is in the way, if a day is waiting to be claimed.
function DailyRewardController:OpenDailyRewardsIfReady()
	if self._ready then
		UIController:OpenFrameWhenFree(self.UI.Holder)
	end
end

-- Counts down to the next day on the synced clock, redrawing the week the moment it unlocks.
function DailyRewardController:_runCountdown()
	local timer = self.UI.Holder.Timer

	while true do
		local data = PlayerDataController:GetData()
		local remaining = data.LastDailyRewardClaim + DailyRewards.CLAIM_INTERVAL - workspace:GetServerTimeNow()

		if (remaining <= 0) ~= self._ready then
			self:RefreshDailyRewards()
		end

		local dayText = GuiUtil.Colorize(`Day {DailyRewards.GetDay(data.DailyRewardStreak)}`, Keywords.NUMBER)

		if remaining <= 0 then
			timer.Text = `Claim your {dayText} Reward!`
		else
			-- Floored by the formatter rather than rounded up, so a fresh claim reads 23h 59m 59s rather than 1d
			local timeText = GuiUtil.Colorize(GuiUtil.ConvertSecondsToDHMS(remaining), Keywords.EMPHASIS)
			timer.Text = `Claim your {dayText} reward in {timeText}`
		end

		task.wait(TIMER_INTERVAL)
	end
end

function DailyRewardController:OnInit()
	-- Timed out rather than waited on, since the loader runs every OnInit on one thread
	self.UI = PlayerGui:WaitForChild(DailyRewards.UI_NAME, UI_TIMEOUT)

	if not self.UI then
		warn(`[DailyReward] PlayerGui.{DailyRewards.UI_NAME} is missing, so daily rewards can't be shown`)
	end
end

function DailyRewardController:OnStart()
	if not self.UI then
		return
	end

	local holder = self.UI.Holder
	holder.Visible = false
	holder.Timer.RichText = true

	-- oneClick keeps it momentary; autoDeselect is off, or pressing it would un-mute the game, as the Codes button notes
	local icon = TopbarPlus.new()
	icon:setLabel("Daily Rewards")
	icon:setImage(DailyRewards.TOPBAR_ICON)
	icon:autoDeselect(false)
	icon:oneClick(true)
	icon:setOrder(TOPBAR_ORDER)
	icon:align("Right")
	-- A red badge with a white count, as Stop-The-Timer's daily rewards wear it
	icon:modifyTheme({
		{ "Notice", "BackgroundColor3", NOTICE_COLOR },
		{ "NoticeLabel", "TextColor3", NOTICE_TEXT_COLOR },
	})
	-- Hidden until the tutorial is done, since no claim is taken before then
	icon:setEnabled(false)
	self._icon = icon

	icon.selected:Connect(function()
		UIController:OpenFrame(holder)
	end)

	for day in DailyRewards.Days do
		local button = holder.Container[tostring(day)]

		-- Day 7's tile has none, so a finished week shows its first six stamped
		local claimed = button:FindFirstChild("Claimed")
		local claimedScale = claimed and claimed:FindFirstChildOfClass("UIScale")
		if claimed and not claimedScale then
			claimedScale = Instance.new("UIScale")
			claimedScale.Parent = claimed
		end

		-- A worker day's rating is coloured in its title
		button.Title.RichText = true

		-- Pulses for good; it's only ever seen on the unlocked day, the rest being hidden
		button.Exclamation:AddTag(POP_TAG)

		self._tiles[day] = {
			Button = button,
			Claimed = claimed,
			ClaimedScale = claimedScale,
			-- Only the Bux tiles' titles carry one, and it only suits a Bux reward
			BuxGradient = button.Title:FindFirstChild("BuxGradient"),
		}

		UIController:BindButtonClick(button, function()
			self:RequestClaimDailyReward(day)
		end, true)
	end

	UIController:BindButtonClick(holder.Skip, function()
		self:PromptSkipDailyRewardWait()
	end, true)

	-- Recursive, since the exit sits in different places per panel. Warned rather than indexed, as the shop's is
	local exit = holder:FindFirstChild("Exit", true)
	if exit then
		UIController:BindButtonClick(exit, function()
			UIController:CloseFrame(holder)
		end, true)
	else
		warn("DailyRewardUI has no Exit button, so it can only be closed from the top bar or by opening another frame")
	end

	-- A claim off the worker cards lands while the week is shut, so its stamp waits for the week to come back up
	UIController.OnFrameOpened:Connect(function(frame)
		if frame == holder then
			self:_stampClaimedDay()
		end
	end)

	self.ClaimDailyRewardResultEvent:OnClientEvent(function(success: boolean, slot: number?)
		self._claiming = false

		-- A pick off the worker cards, which own the Hired stamp and the hand back to the week
		if slot then
			FreeWorkersController:ResolveClaim(success, slot)
		end
	end)

	-- Off the replica rather than a remote, so nothing is lost to a message landing before this was listening
	PlayerDataController:GetReplica()
		:andThen(function(replica)
			-- Whether this session began in the tutorial, which decides what puts the week up
			local startedInTutorial = not replica.Data.TutorialCompleted

			icon:setEnabled(not startedInTutorial)
			self:RefreshDailyRewards()

			PlayerDataController:ListenForChange("TutorialCompleted", function(completed: boolean)
				icon:setEnabled(completed)
			end)

			PlayerDataController:ListenForChange("LastDailyRewardClaim", function()
				self:RefreshDailyRewards()
			end)

			PlayerDataController:ListenForChange("DailyRewardStreak", function(claimedCount: number, previousCount: number)
				-- One more than it was is a claim landing, which stamps its tile rather than just showing it
				if claimedCount == previousCount + 1 then
					self._stampDay = DailyRewards.GetDay(previousCount)
				end

				self:RefreshDailyRewards()
				self:_stampClaimedDay()
			end)

			task.spawn(function()
				self:_runCountdown()
			end)

			if startedInTutorial then
				-- The crash takes the camera, so the week waits for the crate to settle rather than landing over it
				TutorialCrateController.OnCrateLanded:Once(function()
					task.delay(FIRST_OPEN_DELAY, function()
						self:OpenDailyRewardsIfReady()
					end)
				end)
				return
			end

			-- Stood on their base first, and behind the offline earnings panel, which goes up ahead of the week when there's one
			while LocalPlayer:GetAttribute("BaseId") == nil do
				LocalPlayer:GetAttributeChangedSignal("BaseId"):Wait()
			end

			OfflineEarningController:WaitForJoinClaim()
			self:OpenDailyRewardsIfReady()
		end)
		:catch(warn)
end

return DailyRewardController
