-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local MathUtil = require(Shared.MathUtil)

--
local DEFAULT_TIME_TO_TAKE = 0.2

--[[
    Class to easily create an animated number for cool counting effect fr
]]

--
local AnimatedNumber = {}
AnimatedNumber.__index = AnimatedNumber

function AnimatedNumber.new(initialVal: number, timeToTake: number)
	--
	local cleaner = Trove.new()

	--
	local self = setmetatable({
		--
		OnChangedValue = cleaner:Construct(Signal),

		--
		_initialVal = initialVal,
		_timeToTake = timeToTake,
		_value = nil,

		--
		_cleaner = cleaner,
	}, AnimatedNumber)

	self:_init()
	return self
end

function AnimatedNumber:_init()
	--
	local value = self._cleaner:Construct(Instance, "NumberValue")
	self._value = value

	--
	value:GetPropertyChangedSignal("Value"):Connect(function()
		self.OnChangedValue:Fire(MathUtil.RoundUpTo2Dec(value.Value))
	end)

	--
	self:UpdateNumber(self._initialVal or 0)
end

function AnimatedNumber:UpdateNumber(amount: number)
	TweenService:Create(self._value, TweenInfo.new(self._timeToTake or DEFAULT_TIME_TO_TAKE), {
		Value = amount,
	}):Play()
end

function AnimatedNumber:Destroy()
	self._cleaner:Destroy()
	self = nil
end

return AnimatedNumber
