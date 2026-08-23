-- Services
local Players = game:GetService("Players")

--
-- Join/leave keeps the counts current on its own, so the rescan only exists to catch friendships
-- formed mid-session (accepting a request in-game) -- Roblox fires no server event for those.
local FRIEND_RESCAN_INTERVAL = 60

-- Caps the boost at +100%. CurrencyManager divides by this same 10 when paying out, and
-- FriendController multiplies by 10 for the label -- keep all three in step.
local MAX_BOOST_FRIENDS = 10

--
local FriendManager = {
	-- [Player] = { [Player]: true } -- mutual, so a leave can decrement both sides without a web call
	_friendsInServer = {},
}

-- Writes a player's in-server friend count to the FriendsAmount attribute, which replicates to the
-- client for the boost label and is read back by CurrencyManager when paying out.
function FriendManager:_applyFriendsAmount(player: Player)
	local friendsAmount = 0
	for _ in self._friendsInServer[player] do
		friendsAmount += 1
	end

	player:SetAttribute("FriendsAmount", math.clamp(friendsAmount, 0, MAX_BOOST_FRIENDS))
end

-- Rebuilds every pair from scratch. O(n^2) web calls, so it's the startup and periodic path only --
-- joins and leaves go through the cheaper methods below.
function FriendManager:RefreshAllFriendPairs()
	local players = Players:GetPlayers()

	table.clear(self._friendsInServer)
	for _, player in players do
		self._friendsInServer[player] = {}
	end

	-- Friendship is mutual, so only the upper triangle is checked and both sides are recorded.
	for i, player in players do
		for j = i + 1, #players do
			local otherPlayer = players[j]

			local success, isFriend = pcall(function()
				return player:IsFriendsWithAsync(otherPlayer.UserId)
			end)

			-- Either player may have left while the call above was yielding.
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

-- Checks a joining player against everyone already here -- one pass rather than a full rescan -- and
-- updates the count for the joiner and each friend it finds.
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

	-- The joiner may have left again while the checks above were yielding on the web calls.
	if self._friendsInServer[joiningPlayer] then
		self:_applyFriendsAmount(joiningPlayer)
	end
end

-- Drops a leaving player out of their friends' counts. Costs no web calls -- the pairs are already
-- recorded on both sides.
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
		-- Catches anyone who joined while the loader was still starting up.
		self:RefreshAllFriendPairs()

		while true do
			task.wait(FRIEND_RESCAN_INTERVAL)
			self:RefreshAllFriendPairs()
		end
	end)
end

return FriendManager
