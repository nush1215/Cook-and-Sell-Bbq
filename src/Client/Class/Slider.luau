-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

-- A draggable horizontal slider: dragging Arrow.Button drives a 0-1 alpha (optionally snapped) onto a value range.

--
local Slider = {}
Slider.__index = Slider

function Slider.new(slider: Frame, startValue: number, endValue: number, increment: number?)
	local cleaner = Trove.new()

	local self = setmetatable({
		Changed = cleaner:Construct(Signal),
		DragEnded = cleaner:Construct(Signal),

		_slider = slider,
		_arrow = slider.Arrow,
		_button = slider.Arrow.Button,
		_bar = slider.Bar,

		_startValue = startValue,
		_endValue = endValue,
		_increment = increment or 0,
		_alpha = 1,

		_cleaner = cleaner,
		_dragCleaner = cleaner:Construct(Trove),
	}, Slider)

	self:_init()
	return self
end

function Slider:_init()
	self:_render()

	local button: TextButton = self._button

	self._cleaner:Add(button.MouseButton1Down:Connect(function()
		self:_beginDrag()
	end))

	-- Clicking anywhere on the track jumps the handle to that spot and starts a drag.
	self._cleaner:Add(self._slider.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		local alpha = (input.Position.X - self._slider.AbsolutePosition.X) / self._slider.AbsoluteSize.X
		self:_setAlpha(alpha)
		self:_beginDrag()
	end))
end

-- Snaps an alpha to the [0, 1] range and the configured increment.
function Slider:_snap(alpha: number): number
	alpha = math.clamp(alpha, 0, 1)

	if self._increment > 0 then
		alpha = math.clamp(math.round(alpha / self._increment) * self._increment, 0, 1)
	end

	return alpha
end

-- Applies an alpha, updates the visuals, and signals listeners when it changes.
function Slider:_setAlpha(alpha: number)
	alpha = self:_snap(alpha)
	if alpha == self._alpha then
		return
	end

	self._alpha = alpha
	self:_render()
	self.Changed:Fire(self._alpha, self:GetValue())
end

-- Pushes the current alpha onto the Arrow position and Bar fill.
function Slider:_render()
	local arrowPosition = self._arrow.Position
	self._arrow.Position = UDim2.fromScale(self._alpha, arrowPosition.Y.Scale)

	local barSize = self._bar.Size
	self._bar.Size = UDim2.fromScale(self._alpha, barSize.Y.Scale)
end

-- Tracks pointer movement until the drag is released.
function Slider:_beginDrag()
	self._dragCleaner:Clean()

	self._dragCleaner:Connect(UserInputService.InputChanged, function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		local alpha = (input.Position.X - self._slider.AbsolutePosition.X) / self._slider.AbsoluteSize.X
		self:_setAlpha(alpha)
	end)

	-- End the drag on a global release so letting go off the handle still stops it.
	self._dragCleaner:Connect(UserInputService.InputEnded, function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		self.DragEnded:Fire(self._alpha, self:GetValue())
		self._dragCleaner:Clean()
	end)
end

-- Sets the value that the slider represents at alpha 0.
function Slider:SetStartValue(value: number)
	self._startValue = value
	self.Changed:Fire(self._alpha, self:GetValue())
end

-- Sets the value that the slider represents at alpha 1.
function Slider:SetEndValue(value: number)
	self._endValue = value
	self.Changed:Fire(self._alpha, self:GetValue())
end

function Slider:SetValue(value: number)
	local range = self._endValue - self._startValue
	local alpha = if range == 0 then 0 else (value - self._startValue) / range
	self:_setAlpha(alpha)
end

-- Sets the slider position programmatically from a normalized alpha.
function Slider:SetAlpha(alpha: number)
	self:_setAlpha(alpha)
end

-- Returns the current normalized 0-1 alpha.
function Slider:GetAlpha(): number
	return self._alpha
end

-- Returns the alpha mapped onto the [startValue, endValue] range.
function Slider:GetValue(): number
	return self._startValue + (self._endValue - self._startValue) * self._alpha
end

function Slider:Destroy()
	self._cleaner:Destroy()
	self = nil
end

return Slider
