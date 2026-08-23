-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

--
local AFK_TIMEOUT = 15 * 60 -- seconds of no input before the player is sent to a fresh server
local CHECK_INTERVAL = 5 -- how often the idle deadline is polled; 15 minutes doesn't need frame accuracy

-- Detects that the local player has stopped interacting and asks the server to move them into a fresh
-- server. Only the client can see input, so the detection lives here; the teleport itself is the
-- server's call (AfkManager).
local AfkController = {
	ReportAfkEvent = Network.Event("ReportAfk"), -- client -> server (no args)

	_lastInputAt = 0,
}

-- Counts the player as present right now, pushing their idle deadline a full AFK_TIMEOUT out.
function AfkController:MarkActive()
	self._lastInputAt = os.clock()
end

-- Tells the server the player has gone idle, then restarts the idle timer. The reset doubles as the
-- client debounce, and means a teleport that fails server-side just gets retried a timeout later
-- instead of needing a failure reply.
function AfkController:_reportAfk()
	self.ReportAfkEvent:FireServer()
	self:MarkActive()
end

function AfkController:OnStart()
	self:MarkActive()

	-- InputBegan covers clicks, keys, touch taps and gamepad buttons; InputChanged covers mouse
	-- movement, scroll and gamepad axes. Together they catch every way a player can be present.
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
