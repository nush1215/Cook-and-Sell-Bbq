-- Services
local SocialService = game:GetService("SocialService")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

--
local UIController

--
local SHOW_RANDOM_FRIEND_INVITE_FREQUENCE = 5 * 60 -- every 5 minutes

--
local FriendController = {}

-- Prompts the friend invite UI
function FriendController:OpenFriendInvitePrompt()
	local success, canInvite = pcall(function()
		return SocialService:CanSendGameInviteAsync(LocalPlayer)
	end)

	if not success or not canInvite then
		return
	end

	SocialService:PromptGameInvite(LocalPlayer)
end

-- Invites a specific friend
function FriendController:InviteFriend(friendUserId: number)
	local experienceInviteOption = Instance.new("ExperienceInviteOptions")
	experienceInviteOption.InviteUser = friendUserId

	SocialService:PromptGameInvite(LocalPlayer, experienceInviteOption)
end

-- Sends a random friend request
function FriendController:SendRandomFriendRequest()
	local attempt = 0
	local function getPlayer(): Player?
		local players = Players:GetPlayers()
		local randomIndex = math.random(1, #players)

		attempt = attempt + 1
		if attempt > 5 then
			return nil
		end

		if players[randomIndex] == LocalPlayer then
			return getPlayer()
		end

		return players[randomIndex]
	end

	local randomPlayer = getPlayer()
	if not randomPlayer then
		return
	end

	StarterGui:SetCore("PromptSendFriendRequest", randomPlayer)
end

-- Starts the bottom-left random friend invite. Not running by default -- spawn it from OnStart.
function FriendController:_runRandomInviteFriend()
	local currentRandomFriendId
	local clickBindable = Instance.new("BindableFunction")
	clickBindable.OnInvoke = function(response)
		if response == "Yes!" then
			self:InviteFriend(currentRandomFriendId)
		end
	end

	while true do
		task.wait(SHOW_RANDOM_FRIEND_INVITE_FREQUENCE)

		local success, onlineFriends = pcall(function()
			return LocalPlayer:GetFriendsOnlineAsync()
		end)

		if not success or not onlineFriends or #onlineFriends == 0 then
			continue
		end

		local randomFriend = onlineFriends[math.random(1, #onlineFriends)]

		local iconSuccess, friendIcon = pcall(function()
			return Players:GetUserThumbnailAsync(
				randomFriend.VisitorId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size420x420
			)
		end)

		if not iconSuccess then
			continue
		end

		currentRandomFriendId = randomFriend.VisitorId
		StarterGui:SetCore("SendNotification", {
			Title = randomFriend.DisplayName,
			Icon = friendIcon,
			Text = "Your friend wants to play with you! Want to invite them?",
			Duration = 10,
			Button1 = "Yes!",
			Button2 = "No",
			Callback = clickBindable,
		})
	end
end

-- Binds the invite button and keeps the boost label in sync with the server's friend count.
function FriendController:_setupUI()
	local ui = self.UI
	local friendBoost = ui.BottomLeft.FriendBoost

	UIController:BindButtonClick(friendBoost.Invite, function()
		self:OpenFriendInvitePrompt()
	end, true)

	local friendsAmount = LocalPlayer:GetAttribute("FriendsAmount") or 0
	friendBoost.Title.Text = `Friend Boost: +{friendsAmount * 10}%`
	LocalPlayer:GetAttributeChangedSignal("FriendsAmount"):Connect(function()
		local newFriendsAmount = LocalPlayer:GetAttribute("FriendsAmount") or 0
		friendBoost.Title.Text = `Friend Boost: +{newFriendsAmount * 10}%`
	end)
end

--
function FriendController:OnInit()
	UIController = require(script.Parent.UIController)
	self.UI = PlayerGui:WaitForChild("HudUI")
end

function FriendController:OnStart()
	task.spawn(FriendController._setupUI, self)
end

return FriendController
