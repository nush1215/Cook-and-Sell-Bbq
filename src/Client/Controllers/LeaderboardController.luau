-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Teams = game:GetService("Teams")

-- Packages
local Packages = ReplicatedStorage.Packages
local Replica = require(Packages.Replica)
local Trove = require(Packages.Trove)

-- Modules
local Shared = ReplicatedStorage.Shared
local MathUtil = require(Shared.MathUtil)
local GuiUtil = require(Shared.GuiUtil)

-- Controllers
local PlayerDataController = require(script.Parent.PlayerDataController)

-- Assets
local Assets = ReplicatedStorage.Assets
local UI = Assets.UI

-- Leaderboards
local Leaderboards = workspace:WaitForChild("Leaderboards")

--
local LocalPlayer = Players.LocalPlayer

--
local RANK_COLORS = {
	[1] = Color3.fromRGB(255, 170, 0),
	[2] = Color3.fromRGB(170, 255, 255),
	[3] = Color3.fromRGB(170, 85, 0),
}

local DEFAULT_COLOR = Color3.fromRGB(255, 255, 255)

-- Only the server's TOTAL_LEADERBOARD_ENTRIES top entries replicate, so a player below that page has
-- no rank to read anywhere -- they're shown as sitting past the end of it instead.
local UNRANKED_TEXT = "#100+"

local FORMAT_LEADERBOARD_DATA = {
	Default = function(amount)
		return GuiUtil.ConvertNumberWithSuffix(amount)
	end,

	TotalPlaytime = function(amount)
		return GuiUtil.ConvertSecondsToDHMS(amount)
	end,
}

--
local LeaderboardController = {
	--
	_cachedNames = {},
	_cachedThumbnails = {},

	--
	_hasSetup = false,
	_refreshTime = 0,

	-- The local player's own board standing beside each leaderboard. Cloned once and kept for the
	-- session -- deliberately outside _cleaner, which is wiped on every refresh.
	_playerRankBoards = {}, -- [leaderboardKey] = the PlayerRankBoard UI mounted on that board
	-- Last pages the server replicated, kept so a rank board mounting after the replica has already
	-- landed can still paint its rank rather than waiting out the next refresh.
	_leaderboardData = {},

	--
	_cleaner = Trove.new(),
}

-- Resolves the LeaderboardUI for a board, creating it once if it doesn't exist yet.
-- The UI is cloned persistently (not via _cleaner) so periodic refreshes only rebuild the rows.
function LeaderboardController:GetLeaderboardUI(leaderboardKey: string): Instance?
	local leaderboard = Leaderboards:WaitForChild(leaderboardKey, 10)
	local board = leaderboard and leaderboard:WaitForChild("Board", 10)
	if not board then
		return nil
	end

	local leaderboardUI = board:FindFirstChild("LeaderboardUI")
	if not leaderboardUI then
		leaderboardUI = UI.LeaderboardUI:Clone()
		leaderboardUI.Parent = board
	end

	return leaderboardUI
end

-- Writes the local player's own value for a stat onto their rank board. Read live off their player
-- data rather than the leaderboard page, so it's right the moment it changes and right for everyone,
-- not just whoever made the top 100.
function LeaderboardController:RefreshPlayerRankBoardValue(leaderboardKey: string)
	local rankBoardUI = self._playerRankBoards[leaderboardKey]
	if not rankBoardUI then
		return
	end

	local formatFunc = FORMAT_LEADERBOARD_DATA[leaderboardKey] or FORMAT_LEADERBOARD_DATA.Default
	rankBoardUI.Value.Text = formatFunc(PlayerDataController:GetKey(leaderboardKey) or 0)
end

-- Writes the local player's standing onto their rank board, found by their userId in the page the
-- server last loaded -- so it only moves when the leaderboard itself refreshes, and reads as
-- UNRANKED_TEXT for anyone the page doesn't reach.
function LeaderboardController:RefreshPlayerRankBoardRank(leaderboardKey: string)
	local rankBoardUI = self._playerRankBoards[leaderboardKey]
	if not rankBoardUI then
		return
	end

	local localUserId = tostring(LocalPlayer.UserId)
	local rank

	for entryRank, data in self._leaderboardData[leaderboardKey] or {} do
		if data.key == localUserId then
			rank = entryRank
			break
		end
	end

	local rankText = if rank then `#{rank}` else UNRANKED_TEXT

	rankBoardUI.PlayerName.Text = `{rankText} {LocalPlayer.Name:upper()}`
	rankBoardUI.PlayerName.TextColor3 = (rank and RANK_COLORS[rank]) or DEFAULT_COLOR
end

-- Mounts the local player's rank board on one leaderboard, if that leaderboard has a PlayerRankBoard
-- part to hang it on -- so putting one on another board is a studio change rather than a code one.
-- Cloned the same persistent way as the board UI above, since the player it shows never changes.
function LeaderboardController:SetupPlayerRankBoard(leaderboard: Instance)
	local leaderboardKey = leaderboard.Name
	local board = leaderboard:FindFirstChild("PlayerRankBoard")

	-- Reached from both the startup sweep and ChildAdded, so a board that came in on the race between
	-- them must not be mounted twice.
	if not board or self._playerRankBoards[leaderboardKey] then
		return
	end

	local rankBoardUI = board:FindFirstChild("PlayerRankBoard")
	if not rankBoardUI then
		rankBoardUI = UI.PlayerRankBoard:Clone()
		rankBoardUI.Parent = board
	end

	self._playerRankBoards[leaderboardKey] = rankBoardUI

	self:RefreshPlayerRankBoardValue(leaderboardKey)
	self:RefreshPlayerRankBoardRank(leaderboardKey)

	PlayerDataController:ListenForChange(leaderboardKey, function()
		self:RefreshPlayerRankBoardValue(leaderboardKey)
	end)
end

function LeaderboardController:RefreshLeaderboard(updatedLeaderboardData: {})
	--
	self._cleaner:Clean()

	--
	self._leaderboardData = updatedLeaderboardData

	--
	for leaderboardKey, leaderboardData in updatedLeaderboardData do
		-- Cheap synchronous scan of the page we already have, so it stays off the per-board thread.
		self:RefreshPlayerRankBoardRank(leaderboardKey)

		self._cleaner:Add(task.spawn(function()
			--
			local leaderboardUI = self:GetLeaderboardUI(leaderboardKey)
			if not leaderboardUI then
				return
			end

			-- Remove old leaderboard data
			local container = leaderboardUI.Holder.Container

			--
			for rank, data in leaderboardData do
				local userId = tonumber(data.key)
				if not userId or userId < 1 then
					continue
				end

				--
				local playerName = self._cachedNames[data.key]
				if not playerName then
					local success, name = pcall(function()
						return Players:GetNameFromUserIdAsync(userId)
					end)

					if success then
						playerName = name
						self._cachedNames[data.key] = name
					else
						playerName = ""
					end
				end

				local formatFunc = FORMAT_LEADERBOARD_DATA[leaderboardKey] or FORMAT_LEADERBOARD_DATA.Default

				--
				local template: Frame = self._cleaner:Clone(container.Template)
				template.Amount.Text = formatFunc(data.value)
				template.LayoutOrder = rank
				template.PlayerName.Text = playerName:upper() or ""
				template.PlayerName.TextColor3 = RANK_COLORS[rank] or DEFAULT_COLOR
				template.Rank.Text = `#{rank}`
				template.Rank.TextColor3 = RANK_COLORS[rank] or DEFAULT_COLOR
				template.Visible = true
				template.Parent = container

				self._cleaner:Add(task.spawn(function()
					local playerThumbnail = self._cachedThumbnails[data.key]

					if not playerThumbnail then
						local success, thumbnail = pcall(function()
							return Players:GetUserThumbnailAsync(
								userId,
								Enum.ThumbnailType.HeadShot,
								Enum.ThumbnailSize.Size48x48
							)
						end)

						if success then
							playerThumbnail = thumbnail
							self._cachedThumbnails[data.key] = thumbnail
						end
					end

					if template then
						template.PlayerIcon.Image = playerThumbnail
					end
				end))
			end
		end))
	end

	self._hasSetup = true
end

function LeaderboardController:OnInit()
	--
	Replica.OnNew("Leaderboard", function(replica)
		--
		self._refreshTime = replica.Data.RefreshTime
		replica:OnSet({ "RefreshTime" }, function(newTime)
			self._refreshTime = newTime
		end)

		--
		self:RefreshLeaderboard(replica.Data.LeaderboardData)
		replica:OnSet({ "LeaderboardData" }, function(leaderboardData)
			self:RefreshLeaderboard(leaderboardData)
		end)
	end)
end

function LeaderboardController:OnStart()
	-- The boards replicate in on their own schedule, so catch any that land after this point.
	Leaderboards.ChildAdded:Connect(function(leaderboard: Instance)
		self:SetupPlayerRankBoard(leaderboard)
	end)

	-- Sweep once, since the boards may already be here by now. Spawned because GetKey and
	-- ListenForChange both await the player data replica.
	task.spawn(function()
		for _, leaderboard in Leaderboards:GetChildren() do
			self:SetupPlayerRankBoard(leaderboard)
		end
	end)
end

--

return LeaderboardController
