-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

--
local AFK_TIMEOUT = 15 * 60 -- seconds of no input before the player is sent to a fresh server
local CHECK_INTERVAL = 5 -- how often the idle deadline is polled; 15 minutes doesn't need frame accuracy

-- Detects the local player going idle and asks the server to move them on. Only a client can see input; the teleport is AfkManager's.
local AfkController = {
	ReportAfkEvent = Network.Event("ReportAfk"), -- client -> server (no args)

	_lastInputAt = 0,
}

-- Counts the player as present right now, pushing their idle deadline a full AFK_TIMEOUT out.
function AfkController:MarkActive()
	self._lastInputAt = os.clock()
end

-- Reports the player idle and restarts the timer, which doubles as the debounce and the retry.
function AfkController:_reportAfk()
	self.ReportAfkEvent:FireServer()
	self:MarkActive()
end

function AfkController:OnStart()
	self:MarkActive()

	-- InputBegan covers presses, InputChanged movement and axes -- together, every way of being present
	UserInputService.InputBegan:Connect(function()
		self:MarkActive()
	end)

	UserInputService.InputChanged:Connect(function()
		self:MarkActive()
	end)

	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)

			if os.clock() - self._lastInputAt >= AFK_TIMEOUT then
				self:_reportAfk()
			end
		end
	end)
end

return AfkController
