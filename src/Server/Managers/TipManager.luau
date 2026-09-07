-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Config
local Tips = require(ReplicatedStorage.Shared.Config.Tips)

-- Managers
local NotificationManager = require(script.Parent.NotificationManager)

--
local TipManager = {
	_sessions = {}, -- [player] = { Order = the player's shuffled tips, Index = the next one to post }
}

-- A fresh shuffle of the tip list, so two players in a server aren't reading the same line at the same time.
local function shuffleTips(): { string }
	local order = table.clone(Tips.Data)

	for index = #order, 2, -1 do
		local swap = math.random(index)
		order[index], order[swap] = order[swap], order[index]
	end

	return order
end

-- Posts the player's next tip and advances their rotation, reshuffling once the list runs out.
function TipManager:ShowNextTip(player: Player)
	local session = self._sessions[player]

	NotificationManager:NotifyChat(player, Tips.PREFIX .. session.Order[session.Index])

	session.Index += 1

	if session.Index > #session.Order then
		session.Order = shuffleTips()
		session.Index = 1
	end
end

-- Starts a player's rotation on its own timer, so someone joining a running server still gets the list from the top.
function TipManager:StartTipsForPlayer(player: Player)
	if self._sessions[player] then
		return
	end

	self._sessions[player] = { Order = shuffleTips(), Index = 1 }

	task.spawn(function()
		task.wait(Tips.INITIAL_DELAY)

		-- PlayerRemoving clears the session, which is what ends this loop
		while self._sessions[player] do
			self:ShowNextTip(player)
			task.wait(Tips.INTERVAL)
		end
	end)
end

function TipManager:OnInit()
	Players.PlayerAdded:Connect(function(player: Player)
		self:StartTipsForPlayer(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._sessions[player] = nil
	end)
end

function TipManager:OnStart()
	-- Players already present, since in Studio the first one can join before this connects
	for _, player in Players:GetPlayers() do
		self:StartTipsForPlayer(player)
	end
end

return TipManager
