----- MADE BY NUSH ME ME NUSH
-- Cool lil global sync timer that gives out a seed to use for random shi

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)
local Trove = require(Packages.Trove)

export type Clock = {
	--
	OnTimeChanged: typeof(Signal.new()),
	Reached: typeof(Signal.new()),

	--
	CurrentSeed: number,
	CurrentTime: number,

	--
	Destroy: (self: Clock) -> (),

	--
	_cleaner: typeof(Trove.new()),
	_timeInterval: number,
	_init: (self: Clock) -> (),
}

local Clock = {}
Clock.__index = Clock

function Clock.new(timeInterval: number): Clock
	--
	local self = setmetatable({
		--
		OnTimeChanged = Signal.new(),
		Reached = Signal.new(),

		--
		CurrentSeed = math.floor(DateTime.now().UnixTimestamp / timeInterval),
		CurrentTime = 0,

		--
		_cleaner = Trove.new(),
		_timeInterval = timeInterval,
	}, Clock)

	self:_init()
	return self
end

function Clock:_init()
	--
	local intervalTime = self._timeInterval

	--
	self._cleaner:Add(task.spawn(function()
		while true do
			--
			task.wait(1)

			-- Update the time left every second
			local timeLeft = intervalTime - (DateTime.now().UnixTimestamp % intervalTime)
			self.CurrentTime = timeLeft
			self.OnTimeChanged:Fire(timeLeft)

			--
			local seed = math.floor(DateTime.now().UnixTimestamp / intervalTime)

			if seed == self.CurrentSeed then
				continue
			end

			self.Reached:Fire(seed)
			self.CurrentSeed = seed
		end
	end))
end

function Clock:Destroy()
	self._cleaner:Destroy()
end

return Clock
