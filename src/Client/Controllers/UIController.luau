-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local GamepadService = game:GetService("GamepadService")
local StarterGui = game:GetService("StarterGui")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Player
local LPlayer = Players.LocalPlayer
local PlayerGui = LPlayer.PlayerGui

-- Camera
local Camera = workspace.CurrentCamera

-- Controllers
local InputController = require(script.Parent.InputController)

-- Frames with nothing to press, like the tutorial banner: no pad cursor comes up for them and B leaves them alone
local PASSIVE_FRAME_TAG = "PassiveFrame"

-- B closes the top menu. Bound above default, so it beats the backpack's own B while its inventory is open
local CLOSE_FRAME_ACTION = "UICloseFrame"
local CLOSE_FRAME_KEY = Enum.KeyCode.ButtonB
local CLOSE_FRAME_PRIORITY = Enum.ContextActionPriority.High.Value

--
local SoundController

--
local UIController = {
	PASSIVE_FRAME_TAG = PASSIVE_FRAME_TAG,

	OnFrameOpened = Signal.new(),
	OnFrameClosed = Signal.new(),

	_currentOpenedFrame = nil,
	_openFrames = {}, -- every frame up through OpenFrame, oldest first; the last is what B closes and the cursor sits on
	_cursorOwned = false, -- whether the pad cursor up now is one this put up, rather than the player's own
	_closeBound = false,
}

-- Opens `frame`, closing any other open frame unless `independent`.
function UIController:OpenFrame(frame: Frame, independent: boolean?)
	local uiScale = frame:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = frame
	end

	if not frame:GetAttribute("OrigPosition") then
		frame:SetAttribute("OrigPosition", frame.Position)
	end

	-- Close if already opened
	if self._currentOpenedFrame == frame then
		self:CloseFrame(frame)
		return
	end

	SoundController:PlaySound("FrameOpen")

	-- Setup the effect
	frame.Position = frame:GetAttribute("OrigPosition") + UDim2.fromScale(0, 0.07)
	uiScale.Scale = 0.95

	-- Start the effect
	Spr.target(uiScale, 0.7, 3.5, { Scale = 1 })
	Spr.target(frame, 0.5, 3.5, { Position = frame:GetAttribute("OrigPosition") })
	frame.Visible = true

	-- To the top, not pushed twice (an independent frame can reopen over itself); ahead of the swap, so the cursor never blinks
	if not frame:HasTag(PASSIVE_FRAME_TAG) then
		local index = table.find(self._openFrames, frame)
		if index then
			table.remove(self._openFrames, index)
		end
		table.insert(self._openFrames, frame)
	end

	if not independent then
		if self._currentOpenedFrame and self._currentOpenedFrame ~= frame then
			self:CloseFrame(self._currentOpenedFrame)
		end

		Spr.target(Camera, 0.7, 2.5, { FieldOfView = 77 })
		self._currentOpenedFrame = frame
	else
		frame:AddTag("IndependentFrame")
	end

	self:_refreshGamepadMenu(frame)

	self.OnFrameOpened:Fire(frame)
end

-- Closes `frame`.
function UIController:CloseFrame(frame: Frame)
	frame.Visible = false

	if self._currentOpenedFrame == frame then
		self._currentOpenedFrame = nil
	end

	-- Absent is normal: zone exits and passive frames close through here without ever having been on the stack
	local index = table.find(self._openFrames, frame)
	if index then
		table.remove(self._openFrames, index)
	end

	if not frame:HasTag("IndependentFrame") then
		Spr.target(Camera, 0.7, 2.5, { FieldOfView = 70 })
	end

	frame:RemoveTag("IndependentFrame")

	self:_refreshGamepadMenu()

	self.OnFrameClosed:Fire(frame)
end

-- Closes whatever frame is open, for callers needing the screen clear without knowing what's on it.
function UIController:CloseOpenFrame()
	if self._currentOpenedFrame then
		self:CloseFrame(self._currentOpenedFrame)
	end
end

-- The frame open as the main panel, or nil. Independent frames never count, since they don't replace it.
function UIController:GetOpenFrame(): Frame?
	return self._currentOpenedFrame
end

-- Puts the pad's cursor and B on the menus while any is up, and takes both off when none is. `openedFrame` is where the cursor lands.
function UIController:_refreshGamepadMenu(openedFrame: Frame?)
	local topFrame = self._openFrames[#self._openFrames]

	if topFrame and InputController:IsGamepad() then
		-- A cursor the player summoned themselves is left alone, so closing a menu doesn't take it away
		if self._cursorOwned or not GamepadService.GamepadCursorEnabled then
			-- Cleared first: a topbar icon left selected has the stick navigating instead of moving the cursor
			GuiService.SelectedObject = nil
			self._cursorOwned = true
			GamepadService:EnableGamepadCursor(openedFrame or topFrame)
		end
	elseif self._cursorOwned then
		self._cursorOwned = false
		GamepadService:DisableGamepadCursor()
	end

	local menuOpen = topFrame ~= nil
	if menuOpen == self._closeBound then
		return
	end
	self._closeBound = menuOpen

	if not menuOpen then
		ContextActionService:UnbindAction(CLOSE_FRAME_ACTION)
		return
	end

	ContextActionService:BindActionAtPriority(CLOSE_FRAME_ACTION, function(_, inputState: Enum.UserInputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end

		self:CloseFrame(self._openFrames[#self._openFrames])
		return Enum.ContextActionResult.Sink
	end, false, CLOSE_FRAME_PRIORITY, CLOSE_FRAME_KEY)
end

-- `activateOnPress` answers on the press, for buttons that move under the finger -- a billboard on an animated NPC loses every touch otherwise.
function UIController:BindButtonClick(
	button: GuiButton,
	clickCallback: () -> (),
	bindEffect: boolean?,
	disconnectAfter: boolean?,
	bindEffectProperties: {
		ShowFrame: Frame?,
		ButtonDownScale: number?,
		ButtonHoverscale: number?,
		OnHoverCallback: () -> ()?,
		OnHoverEndCallback: () -> ()?,
		ClickSoundName: string?,
		ButtonNormalScale: number?,
	}?,
	activateOnPress: boolean?
): { Disconnect: () -> () }
	local cleaner = Trove.new()

	-- MouseButton1Down covers touch as well as the mouse, so there's no separate tap path to bind.
	local clickSignal = if activateOnPress then button.MouseButton1Down else button.Activated

	cleaner:Add(clickSignal:Connect(function()
		if clickCallback then
			task.spawn(clickCallback)
		end

		if disconnectAfter then
			cleaner:Destroy()
		end
	end))

	if bindEffect then
		bindEffectProperties = bindEffectProperties or {}
		cleaner:Add(self:BindButtonEffect(button, bindEffectProperties, activateOnPress))
	end

	return {
		Disconnect = function()
			cleaner:Destroy()
		end,
	}
end

function UIController:BindButtonEffect(
	button: GuiButton,
	properties: {
		ShowFrame: Frame?,
		ButtonDownScale: number?,
		ButtonHoverscale: number?,
		OnHoverCallback: () -> ()?,
		OnHoverEndCallback: () -> ()?,
		ClickSoundName: string?,
		ButtonNormalScale: number?,
	}?,
	activateOnPress: boolean?
)
	local cleaner = Trove.new()

	properties = properties or {}
	local showFrame = properties.ShowFrame or button
	local buttonDownScale = properties.ButtonDownScale
	local buttonHoverscale = properties.ButtonHoverscale
	local onHoverCallback = properties.OnHoverCallback
	local OnHoverEndCallback = properties.OnHoverEndCallback
	local clickSoundName = properties.ClickSoundName
	local buttonNormalScale = properties.ButtonNormalScale

	local uiScale = showFrame:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = showFrame
	end

	local damping = 0.45
	local frequency = 6

	local buttonSprings = {
		Press = function()
			Spr.target(uiScale, damping, frequency, {
				Scale = buttonDownScale or 0.93,
			})
		end,

		Hover = function()
			Spr.target(uiScale, damping, frequency, {
				Scale = buttonHoverscale or 1.06,
			})
		end,

		Normal = function()
			Spr.target(uiScale, damping, frequency, {
				Scale = buttonNormalScale or 1,
			})
		end,
	}

	-- Tracked so dragging a handle under the cursor keeps the pressed spring instead of flickering to hover
	local isPressed = false

	cleaner:Add(button.MouseButton1Down:Connect(function()
		isPressed = true
		buttonSprings.Press()
	end))

	-- On the same edge as the callback, so only a click that landed is heard. The press spring stays on the way down
	local soundSignal = if activateOnPress then button.MouseButton1Down else button.Activated

	cleaner:Add(soundSignal:Connect(function()
		SoundController:PlaySound(clickSoundName or "ButtonClick")
	end))

	-- ButtonA too: the pad cursor's click presses like a mouse, but its release arrives as a pad input
	cleaner:Add(UserInputService.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
			and input.KeyCode ~= Enum.KeyCode.ButtonA
		then
			return
		end

		if not isPressed then
			return
		end

		isPressed = false
		buttonSprings.Normal()
	end))

	cleaner:Add(button.MouseEnter:Connect(function()
		if onHoverCallback then
			onHoverCallback()
		end

		if isPressed then
			return
		end

		SoundController:PlaySound("ButtonHover")
		buttonSprings.Hover()
	end))

	cleaner:Add(button.MouseLeave:Connect(function()
		if OnHoverEndCallback then
			OnHoverEndCallback()
		end

		if isPressed then
			return
		end

		buttonSprings.Normal()
	end))

	cleaner:Add(buttonSprings.Normal)

	return {
		Disconnect = function()
			cleaner:Destroy()
		end,
	}
end

function UIController:OnInit()
	SoundController = require(script.Parent.SoundController)

	-- A pad picked up mid-menu gets the cursor; a mouse touched mid-menu loses it
	InputController.OnPreferredInputChanged:Connect(function()
		self:_refreshGamepadMenu()
	end)

	-- TopbarPlus drops the cursor a beat after an icon is pressed, which would leave the Codes panel without one
	GamepadService:GetPropertyChangedSignal("GamepadCursorEnabled"):Connect(function()
		if self._cursorOwned and not GamepadService.GamepadCursorEnabled then
			self._cursorOwned = false
			self:_refreshGamepadMenu()
		end
	end)

	for _, v in PlayerGui:GetDescendants() do
		if not v:IsA("UIStroke") then
			continue
		end

		v:AddTag("UIStroke")
	end

	PlayerGui.DescendantAdded:Connect(function(v)
		if v:IsA("UIStroke") then
			v:AddTag("UIStroke")
		end
	end)

	-- Disable Reset Button
	task.spawn(function()
		repeat
			local success = pcall(function()
				StarterGui:SetCore("ResetButtonCallback", false)
			end)
			task.wait(1)
		until success
	end)
end

function UIController:OnStart() end

return UIController
