-- Services
local Players = game:GetService("Players")

--
-- The rescan only catches friendships formed mid-session, which Roblox fires no server event for
local FRIEND_RESCAN_INTERVAL = 60

-- Caps the boost at +100%. CurrencyManager and FriendController use the same 10 -- keep all three in step
local MAX_BOOST_FRIENDS = 10

--
local FriendManager = {
	-- [Player] = { [Player]: true } -- mutual, so a leave can decrement both sides without a web call
	_friendsInServer = {},
}

-- Writes a player's in-server friend count to FriendsAmount, read by the boost label and CurrencyManager.
function FriendManager:_applyFriendsAmount(player: Player)
	local friendsAmount = 0
	for _ in self._friendsInServer[player] do
		friendsAmount += 1
	end

	player:SetAttribute("FriendsAmount", math.clamp(friendsAmount, 0, MAX_BOOST_FRIENDS))
end

-- Rebuilds every pair. O(n^2) web calls, so it's the startup and periodic path only.
function FriendManager:RefreshAllFriendPairs()
	local players = Players:GetPlayers()

	table.clear(self._friendsInServer)
	for _, player in players do
		self._friendsInServer[player] = {}
	end

	-- Friendship is mutual, so only the upper triangle is checked and both sides are recorded
	for i, player in players do
		for j = i + 1, #players do
			local otherPlayer = players[j]

			local success, isFriend = pcall(function()
				return player:IsFriendsWithAsync(otherPlayer.UserId)
			end)

			-- Either player may have left while the call above was yielding
			local playerPairs = self._friendsInServer[player]
			local otherPairs = self._friendsInServer[otherPlayer]
			if success and isFriend and playerPairs and otherPairs then
				playerPairs[otherPlayer] = true
				otherPairs[player] = true
			end
		end
	end

	for _, player in players do
		if self._friendsInServer[player] then
			self:_applyFriendsAmount(player)
		end
	end
end

-- Checks a joiner against everyone here in one pass, updating their count and each friend's.
function FriendManager:AddPlayerFriendPairs(joiningPlayer: Player)
	self._friendsInServer[joiningPlayer] = {}

	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer == joiningPlayer or not self._friendsInServer[otherPlayer] then
			continue
		end

		local success, isFriend = pcall(function()
			return joiningPlayer:IsFriendsWithAsync(otherPlayer.UserId)
		end)

		if success and isFriend then
			self._friendsInServer[joiningPlayer][otherPlayer] = true
			self._friendsInServer[otherPlayer][joiningPlayer] = true
			self:_applyFriendsAmount(otherPlayer)
		end
	end

	-- The joiner may have left again while the checks above were yielding on the web calls
	if self._friendsInServer[joiningPlayer] then
		self:_applyFriendsAmount(joiningPlayer)
	end
end

-- Drops a leaver out of their friends' counts. No web calls -- the pairs are recorded on both sides.
function FriendManager:RemovePlayerFriendPairs(leavingPlayer: Player)
	local friends = self._friendsInServer[leavingPlayer]
	if not friends then
		return
	end

	self._friendsInServer[leavingPlayer] = nil

	for friend in friends do
		local friendPairs = self._friendsInServer[friend]
		if not friendPairs then
			continue
		end

		friendPairs[leavingPlayer] = nil
		self:_applyFriendsAmount(friend)
	end
end

function FriendManager:OnStart()
	Players.PlayerAdded:Connect(function(player: Player)
		self:AddPlayerFriendPairs(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:RemovePlayerFriendPairs(player)
	end)

	task.spawn(function()
		-- Catches anyone who joined while the loader was still starting up
		self:RefreshAllFriendPairs()

		while true do
			task.wait(FRIEND_RESCAN_INTERVAL)
			self:RefreshAllFriendPairs()
		end
	end)
end

return FriendManager
