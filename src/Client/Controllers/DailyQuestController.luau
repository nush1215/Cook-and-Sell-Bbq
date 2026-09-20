-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local DailyQuests = require(Shared.Config.DailyQuests)
local DailyRewards = require(Shared.Config.DailyRewards)
local FreeWorkers = require(Shared.Config.FreeWorkers)

-- Controllers
local UIController = require(script.Parent.UIController)
local PlayerDataController = require(script.Parent.PlayerDataController)
local FreeWorkersController = require(script.Parent.FreeWorkersController)
local HudController = require(script.Parent.HudController)
local NotificationController = require(script.Parent.NotificationController)

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- The loader runs every OnInit on one thread, so this waits with a timeout rather than hanging the boot
local UI_TIMEOUT = 10

-- How long a claim stays locked after it's asked for, in case the server's answer never lands
local REQUEST_TIMEOUT = 3

-- Seconds between countdown redraws, read off the synced clock
local TIMER_INTERVAL = 0.5

-- The daily quest board, one tile a quest. The server counts and pays; this draws the board off the replicated key, counts down to the next one, alerts the HUD button while something's waiting, and puts a worker board reward's cards up once it's owed.

--
local DailyQuestController = {
	ClaimDailyQuestEvent = Network.Event("ClaimDailyQuest"), -- client -> server (questSlot)
	ClaimDailyQuestRewardEvent = Network.Event("ClaimDailyQuestReward"), -- client -> server (cardSlot)
	ClaimDailyQuestResultEvent = Network.Event("ClaimDailyQuestResult"), -- server -> client (success, cardSlot?)

	_tiles = {}, -- [slot] = { Frame, Fill, FillSize }
	_hudButton = nil, -- the HUD's Quests button, whose Alert says something's waiting
	_pickOwed = false, -- whether the board's worker reward was waiting on a pick, as the board was last drawn
	_drawn = false, -- whether the board has been drawn once, so an owed pick found on join doesn't throw the cards up
	_claiming = false, -- the client half of the debounce; the server holds the authoritative one
}

-- Draws the board off the replicated key: every tile's quest, bar and check, the board reward's icon, and the HUD alert. Puts the worker cards up the moment a claim leaves one owed.
function DailyQuestController:RefreshDailyQuests()
	local board = PlayerDataController:GetKey("DailyQuests")
	local waiting = false

	for slot, tile in self._tiles do
		local boardQuest = board.Quests[slot]
		local quest = boardQuest and DailyQuests.GetQuestFromId(boardQuest.Id)

		-- Empty until the tutorial rolls the first board, or naming a quest since taken out of the pool
		tile.Frame.Visible = quest ~= nil
		if not quest then
			continue
		end

		local progress, target = boardQuest.Progress, boardQuest.Target
		local complete = progress >= target

		tile.Frame.Title.Text = quest.Title
		tile.Frame.Description.Text = DailyQuests.GetDescription(quest, target)
		tile.Frame.Check.Visible = boardQuest.Claimed

		-- Only the X scale is ours, so a fill inset in the place file stays inset
		local fillSize = tile.FillSize
		tile.Fill.Size = UDim2.new(progress / target, fillSize.X.Offset, fillSize.Y.Scale, fillSize.Y.Offset)

		tile.Frame.Bar.ProgressAmount.Text = if boardQuest.Claimed
			then "Claimed"
			elseif complete then "Click to Claim!"
			else `{GuiUtil.ConvertNumberWithCommas(progress)}/{GuiUtil.ConvertNumberWithCommas(target)}`

		if complete and not boardQuest.Claimed then
			waiting = true
		end
	end

	local rewardIcon = self.UI.Holder.QuestDailyRewardIcon
	if board.Reward then
		-- The same title a daily reward tile reads, so a crate is "x1 Meat Crate" and a worker "4 Star Worker"
		self.UI.Holder.RewardName.Text = (DailyRewards.GetRewardDisplay(board.Reward))

		local icon = DailyQuests.GetRewardIcon(board.Reward)
		if not rewardIcon:IsA("ImageLabel") and not rewardIcon:IsA("ImageButton") then
			warn(`QuestsUI.Holder.QuestDailyRewardIcon is a {rewardIcon.ClassName}, so the board reward's image can't go on it`)
		elseif icon then
			rewardIcon.Image = icon
		end
	end

	local pickOwed = DailyQuests.IsWorkerPickOwed(board)

	if waiting or pickOwed then
		self._hudButton.StartAlert()
	else
		self._hudButton.StopAlert()
	end

	-- Only a claim of the last quest leaves a pick owed, so this is that claim landing
	if pickOwed and not self._pickOwed and self._drawn then
		self:OpenDailyQuestRewardOffer()
	end

	self._pickOwed = pickOwed
	self._drawn = true
end

-- Claims the quest on `questSlot` if it's finished and not yet claimed.
function DailyQuestController:RequestClaimDailyQuest(questSlot: number)
	if self._claiming then
		return
	end

	local boardQuest = PlayerDataController:GetKey("DailyQuests").Quests[questSlot]
	if not boardQuest then
		return
	end

	if boardQuest.Claimed then
		NotificationController:NotifyNormal({
			Text = "You already claimed this quest",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return
	end

	if boardQuest.Progress < boardQuest.Target then
		NotificationController:NotifyNormal({
			Text = "Finish this quest first to claim its reward",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return
	end

	self._claiming = true
	self.ClaimDailyQuestEvent:FireServer(questSlot)

	-- Cleared by the result; this is only the backstop for one the server never answered
	task.delay(REQUEST_TIMEOUT, function()
		self._claiming = false
	end)
end

-- Puts the board's worker reward up as three cards, the pick being the claim. Back to the board once one's hired.
function DailyQuestController:OpenDailyQuestRewardOffer()
	local board = PlayerDataController:GetKey("DailyQuests")
	local holder = self.UI.Holder

	FreeWorkersController:OpenOffer({
		Candidates = FreeWorkers.RollCandidates(
			DailyQuests.GetSeed(LocalPlayer.UserId, board.Count),
			board.Reward.Stars
		),
		PortraitFolder = DailyQuests.PORTRAIT_FOLDER,
		RequestHire = function(cardSlot: number)
			self.ClaimDailyQuestRewardEvent:FireServer(cardSlot)
		end,
		OnHired = function()
			UIController:OpenFrame(holder)
		end,
	})
end

-- Opens the board, or the worker cards instead while a pick is owed, so a player who shut them can get back to them.
function DailyQuestController:OpenDailyQuests()
	if self._pickOwed then
		self:OpenDailyQuestRewardOffer()
		return
	end

	UIController:OpenFrame(self.UI.Holder)
end

-- Counts down to the next board on the synced clock.
function DailyQuestController:_runCountdown()
	local timer = self.UI.Holder.Timer

	while true do
		local board = PlayerDataController:GetKey("DailyQuests")
		local remaining = board.StartedAt + DailyQuests.RESET_INTERVAL - workspace:GetServerTimeNow()

		-- Hours rather than days, so a fresh board reads 23h 59m 59s rather than a day count
		timer.Text = GuiUtil.ConvertSecondsToHMS(math.max(remaining, 0))

		task.wait(TIMER_INTERVAL)
	end
end

function DailyQuestController:OnInit()
	-- Timed out rather than waited on, since the loader runs every OnInit on one thread
	self.UI = PlayerGui:WaitForChild(DailyQuests.UI_NAME, UI_TIMEOUT)

	if not self.UI then
		warn(`[DailyQuest] PlayerGui.{DailyQuests.UI_NAME} is missing, so daily quests can't be shown`)
	end
end

function DailyQuestController:OnStart()
	if not self.UI then
		return
	end

	local holder = self.UI.Holder
	holder.Visible = false

	-- A worker's rating is coloured in its name
	holder.RewardName.RichText = true

	self._hudButton = HudController:BindHudButton(DailyQuests.HUD_BUTTON, function()
		self:OpenDailyQuests()
	end)

	if not self._hudButton then
		return
	end

	for slot in DailyQuests.SLOT_DIFFICULTIES do
		local frame = holder.Container[tostring(slot)]
		local fill = frame.Bar.BarContainer.Bar

		-- The target's number is coloured in the objective line
		frame.Description.RichText = true
		frame.RewardAmount.Text = `${GuiUtil.ConvertNumberWithSuffix(DailyQuests.QUEST_REWARD)}`

		self._tiles[slot] = {
			Frame = frame,
			Fill = fill,
			FillSize = fill.Size,
		}

		-- The tile is the claim button, so a Frame authored in its place can't take the press
		if frame:IsA("GuiButton") then
			UIController:BindButtonClick(frame, function()
				self:RequestClaimDailyQuest(slot)
			end, true, false, { ButtonHoverscale = 1.05 })
		else
			warn(
				`QuestsUI.Holder.Container.{slot} is a {frame.ClassName}, not a GuiButton, so its quest can't be claimed`
			)
		end
	end

	UIController:BindButtonClick(holder.Exit, function()
		UIController:CloseFrame(holder)
	end, true)

	self.ClaimDailyQuestResultEvent:OnClientEvent(function(success: boolean, cardSlot: number?)
		self._claiming = false

		-- A pick off the worker cards, which own the Hired stamp and the hand back to the board
		if cardSlot then
			FreeWorkersController:ResolveClaim(success, cardSlot)
		end
	end)

	-- Off the replica rather than a remote, so nothing is lost to a message landing before this was listening
	PlayerDataController:GetReplica()
		:andThen(function()
			self:RefreshDailyQuests()

			PlayerDataController:ListenForChange("DailyQuests", function()
				self:RefreshDailyQuests()
			end)

			task.spawn(function()
				self:_runCountdown()
			end)
		end)
		:catch(warn)
end

return DailyQuestController
