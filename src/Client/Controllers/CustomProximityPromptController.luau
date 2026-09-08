-- Services
local ReplicationStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local UserInputService = game:GetService("UserInputService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicationStorage.Packages
local Spr = require(Packages.Spr)
local Trove = require(Packages.Trove)

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- Assets
local Assets = ReplicationStorage.Assets
local UIAssets = Assets.UI

--
local SoundController

--
local GamepadButtonImage = {
	[Enum.KeyCode.ButtonX] = "rbxasset://textures/ui/Controls/xboxX.png",
	[Enum.KeyCode.ButtonY] = "rbxasset://textures/ui/Controls/xboxY.png",
	[Enum.KeyCode.ButtonA] = "rbxasset://textures/ui/Controls/xboxA.png",
	[Enum.KeyCode.ButtonB] = "rbxasset://textures/ui/Controls/xboxB.png",
	[Enum.KeyCode.DPadLeft] = "rbxasset://textures/ui/Controls/dpadLeft.png",
	[Enum.KeyCode.DPadRight] = "rbxasset://textures/ui/Controls/dpadRight.png",
	[Enum.KeyCode.DPadUp] = "rbxasset://textures/ui/Controls/dpadUp.png",
	[Enum.KeyCode.DPadDown] = "rbxasset://textures/ui/Controls/dpadDown.png",
	[Enum.KeyCode.ButtonSelect] = "rbxasset://textures/ui/Controls/xboxmenu.png",
	[Enum.KeyCode.ButtonL1] = "rbxasset://textures/ui/Controls/xboxLS.png",
	[Enum.KeyCode.ButtonR1] = "rbxasset://textures/ui/Controls/xboxRS.png",
}

local KeyboardButtonImage = {
	[Enum.KeyCode.Backspace] = "rbxasset://textures/ui/Controls/backspace.png",
	[Enum.KeyCode.Return] = "rbxasset://textures/ui/Controls/return.png",
	[Enum.KeyCode.LeftShift] = "rbxasset://textures/ui/Controls/shift.png",
	[Enum.KeyCode.RightShift] = "rbxasset://textures/ui/Controls/shift.png",
	[Enum.KeyCode.Tab] = "rbxasset://textures/ui/Controls/tab.png",
}

local KeyboardButtonIconMapping = {
	["'"] = "rbxasset://textures/ui/Controls/apostrophe.png",
	[","] = "rbxasset://textures/ui/Controls/comma.png",
	["`"] = "rbxasset://textures/ui/Controls/graveaccent.png",
	["."] = "rbxasset://textures/ui/Controls/period.png",
	[" "] = "rbxasset://textures/ui/Controls/spacebar.png",
}

local KeyCodeToTextMapping = {
	[Enum.KeyCode.LeftControl] = "Ctrl",
	[Enum.KeyCode.RightControl] = "Ctrl",
	[Enum.KeyCode.LeftAlt] = "Alt",
	[Enum.KeyCode.RightAlt] = "Alt",
	[Enum.KeyCode.F1] = "F1",
	[Enum.KeyCode.F2] = "F2",
	[Enum.KeyCode.F3] = "F3",
	[Enum.KeyCode.F4] = "F4",
	[Enum.KeyCode.F5] = "F5",
	[Enum.KeyCode.F6] = "F6",
	[Enum.KeyCode.F7] = "F7",
	[Enum.KeyCode.F8] = "F8",
	[Enum.KeyCode.F9] = "F9",
	[Enum.KeyCode.F10] = "F10",
	[Enum.KeyCode.F11] = "F11",
	[Enum.KeyCode.F12] = "F12",
}

--
local CustomProximityPromptController = {
	-- The teardown per shown prompt, so whichever signal gets there first drives the hide
	_shown = {}, -- [prompt] = finish
}

local function getScreenGui()
	local screenGui = PlayerGui:FindFirstChild("ProximityPrompts")
	if screenGui == nil then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "ProximityPrompts"
		screenGui.ResetOnSpawn = false
		screenGui.Parent = PlayerGui
	end
	return screenGui
end

local function setUpCircularProgressBar(bar)
	local leftGradient = bar.LeftGradient.ProgressBarImage.UIGradient
	local rightGradient = bar.RightGradient.ProgressBarImage.UIGradient

	local progress = bar.Progress
	progress.Changed:Connect(function(value)
		local angle = math.clamp(value * 360, 0, 360)
		leftGradient.Rotation = math.clamp(angle, 180, 360)
		rightGradient.Rotation = math.clamp(angle, 0, 180)
	end)
end

function CustomProximityPromptController:_createPrompt(prompt, inputType, gui)
	local tweensForButtonHoldBegin = {}
	local tweensForButtonHoldEnd = {}
	local tweensForFadeOut = {}
	local tweensForFadeIn = {}
	local tweenInfoOutHalfSecond = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tweenInfoFast = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tweenInfoQuick = TweenInfo.new(0.06, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

	local promptUI = UIAssets.Prompt:Clone()
	promptUI.Enabled = true

	local frame = promptUI.PromptFrame
	local inputFrame = frame.InputFrame
	local actionText = frame.ActionText
	local objectText = frame.ObjectText

	-- Tweens for Frame and children
	local backgroundTransparency = frame.BackgroundTransparency
	local imageTransparency = frame.ImageTransparency
	frame.BackgroundTransparency = 1
	frame.ImageTransparency = 1
	-- TODO: consolidate with the other image-label tweens, and share the property tables
	table.insert(
		tweensForButtonHoldBegin,
		TweenService:Create(
			frame,
			tweenInfoFast,
			{ Size = UDim2.fromScale(0.5, 1), BackgroundTransparency = 1, ImageTransparency = 1 }
		)
	)
	table.insert(
		tweensForButtonHoldEnd,
		TweenService:Create(frame, tweenInfoFast, {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = backgroundTransparency,
			ImageTransparency = imageTransparency,
		})
	)
	table.insert(
		tweensForFadeOut,
		TweenService:Create(frame, tweenInfoFast, { BackgroundTransparency = 1, ImageTransparency = 1 })
	)
	table.insert(
		tweensForFadeIn,
		TweenService:Create(frame, tweenInfoFast, {
			BackgroundTransparency = backgroundTransparency,
			ImageTransparency = imageTransparency,
		})
	)

	local function setupUIStrokeTweens(uiStroke)
		local transparency = uiStroke.Transparency
		uiStroke.Transparency = 1
		table.insert(tweensForButtonHoldBegin, TweenService:Create(uiStroke, tweenInfoFast, { Transparency = 1 }))
		table.insert(
			tweensForButtonHoldEnd,
			TweenService:Create(uiStroke, tweenInfoFast, { Transparency = transparency })
		)
		table.insert(tweensForFadeOut, TweenService:Create(uiStroke, tweenInfoFast, { Transparency = 1 }))
		table.insert(tweensForFadeIn, TweenService:Create(uiStroke, tweenInfoFast, { Transparency = transparency }))
	end

	local function setupGUIObjectTweens(guiObject)
		local guiObjectBackgroundTransparency = guiObject.BackgroundTransparency
		guiObject.BackgroundTransparency = 1
		table.insert(
			tweensForButtonHoldBegin,
			TweenService:Create(guiObject, tweenInfoFast, { BackgroundTransparency = 1 })
		)
		table.insert(
			tweensForButtonHoldEnd,
			TweenService:Create(guiObject, tweenInfoFast, { BackgroundTransparency = guiObjectBackgroundTransparency })
		)
		table.insert(tweensForFadeOut, TweenService:Create(guiObject, tweenInfoFast, { BackgroundTransparency = 1 }))
		table.insert(
			tweensForFadeIn,
			TweenService:Create(guiObject, tweenInfoFast, { BackgroundTransparency = guiObjectBackgroundTransparency })
		)
	end

	local function setupTextLabelTweens(textLabel)
		local textTransparency = textLabel.TextTransparency
		local textStrokeTransparency = textLabel.TextStrokeTransparency
		textLabel.TextTransparency = 1
		textLabel.TextStrokeTransparency = 1
		table.insert(
			tweensForButtonHoldBegin,
			TweenService:Create(textLabel, tweenInfoFast, { TextTransparency = 1, TextStrokeTransparency = 1 })
		)
		table.insert(
			tweensForButtonHoldEnd,
			TweenService:Create(
				textLabel,
				tweenInfoFast,
				{ TextTransparency = textTransparency, TextStrokeTransparency = textStrokeTransparency }
			)
		)
		table.insert(
			tweensForFadeOut,
			TweenService:Create(textLabel, tweenInfoFast, { TextTransparency = 1, TextStrokeTransparency = 1 })
		)
		table.insert(
			tweensForFadeIn,
			TweenService:Create(
				textLabel,
				tweenInfoFast,
				{ TextTransparency = textTransparency, TextStrokeTransparency = textStrokeTransparency }
			)
		)
	end

	local function setupImageLabelTweens(imageLabel)
		local imageTransparency = imageLabel.ImageTransparency
		imageLabel.ImageTransparency = 1
		table.insert(
			tweensForButtonHoldBegin,
			TweenService:Create(imageLabel, tweenInfoFast, { ImageTransparency = 1 })
		)
		table.insert(
			tweensForButtonHoldEnd,
			TweenService:Create(imageLabel, tweenInfoFast, { ImageTransparency = imageTransparency })
		)
		table.insert(tweensForFadeOut, TweenService:Create(imageLabel, tweenInfoFast, { ImageTransparency = 1 }))
		table.insert(
			tweensForFadeIn,
			TweenService:Create(imageLabel, tweenInfoFast, { ImageTransparency = imageTransparency })
		)
	end

	local function setupUnexpectedChildTweens(child)
		if child:IsA("UIStroke") then
			setupUIStrokeTweens(child)
		elseif child:IsA("UIGradient") then
			-- The Transparency property of UIGradients is not tweenable
		elseif child:IsA("GuiObject") then
			setupGUIObjectTweens(child)

			if child:IsA("TextLabel") then
				setupTextLabelTweens(child)
			elseif child:IsA("ImageLabel") then
				setupImageLabelTweens(child)
			end
		end

		for _, grandChild in pairs(child:GetChildren()) do
			setupUnexpectedChildTweens(grandChild)
		end
	end

	-- Key is UI object, value is whether or not we should tween out the children of it in the same manner
	local expectedFrameChildren = { [inputFrame] = false, [actionText] = true, [objectText] = true }
	for _, child in pairs(frame:GetChildren()) do
		if expectedFrameChildren[child] == nil then
			-- Unexpected child of the frame, and its direct children
			setupUnexpectedChildTweens(child)
		elseif expectedFrameChildren[child] == true then
			for _, grandChild in pairs(child:GetChildren()) do
				-- All children of ActionText or ObjectText
				setupUnexpectedChildTweens(grandChild)
			end
		end
	end

	-- Tweens for InputFrame
	local resizeableInputFrame = inputFrame.Frame
	local inputFrameScaler = resizeableInputFrame.UIScale
	local inputFrameScaleFactor = inputType == Enum.ProximityPromptInputType.Touch and 1.6 or 1.33
	table.insert(
		tweensForButtonHoldBegin,
		TweenService:Create(inputFrameScaler, tweenInfoFast, { Scale = inputFrameScaleFactor })
	)
	table.insert(tweensForButtonHoldEnd, TweenService:Create(inputFrameScaler, tweenInfoFast, { Scale = 1 }))

	-- Tweens for ActionText and ObjectText
	setupTextLabelTweens(actionText)
	setupTextLabelTweens(objectText)

	local buttonFrame = resizeableInputFrame.ButtonFrame

	local function setupButtonFrameTweens()
		local buttonFrameBackgroundTransparency = buttonFrame.BackgroundTransparency
		local buttonFrameImageTransparency = buttonFrame.ImageTransparency

		table.insert(
			tweensForFadeOut,
			TweenService:Create(buttonFrame, tweenInfoQuick, { BackgroundTransparency = 1, ImageTransparency = 1 })
		)
		table.insert(
			tweensForFadeIn,
			TweenService:Create(buttonFrame, tweenInfoQuick, {
				BackgroundTransparency = buttonFrameBackgroundTransparency,
				ImageTransparency = buttonFrameImageTransparency,
			})
		)

		for _, child in pairs(buttonFrame:getChildren()) do
			if child:IsA("UIStroke") then
				local transparency = child.Transparency
				table.insert(tweensForFadeOut, TweenService:Create(child, tweenInfoQuick, { Transparency = 1 }))
				table.insert(
					tweensForFadeIn,
					TweenService:Create(child, tweenInfoQuick, { Transparency = transparency })
				)
			end
			-- Currently not supporting any other children other than UIStroke
		end
	end
	setupButtonFrameTweens()

	local buttonImage = resizeableInputFrame.ButtonImage
	local buttonText = resizeableInputFrame.ButtonText
	local icon = resizeableInputFrame.ButtonTextImage

	local function setupButtonTextTweens()
		local textTransparency = buttonText.TextTransparency
		local textStrokeTransparency = buttonText.TextStrokeTransparency
		local textBackgroundTransparency = buttonText.BackgroundTransparency
		buttonText.BackgroundTransparency = 1
		buttonText.TextStrokeTransparency = 1
		buttonText.TextTransparency = 1
		table.insert(
			tweensForFadeOut,
			TweenService:Create(
				buttonText,
				tweenInfoQuick,
				{ TextTransparency = 1, TextStrokeTransparency = 1, BackgroundTransparency = 1 }
			)
		)
		table.insert(
			tweensForFadeIn,
			TweenService:Create(buttonText, tweenInfoQuick, {
				TextTransparency = textTransparency,
				TextStrokeTransparency = textStrokeTransparency,
				BackgroundTransparency = textBackgroundTransparency,
			})
		)

		for _, child in pairs(buttonText:getChildren()) do
			if child:IsA("UIStroke") then
				local transparency = child.Transparency
				table.insert(tweensForFadeOut, TweenService:Create(child, tweenInfoQuick, { Transparency = 1 }))
				table.insert(
					tweensForFadeIn,
					TweenService:Create(child, tweenInfoQuick, { Transparency = transparency })
				)
			end
			-- Currently not supporting any other children other than UIStroke
		end
	end

	local function setupButtonImageTweens()
		local buttonImageTransparency = buttonImage.ImageTransparency
		local buttonImageBackgroundTransparency = buttonImage.BackgroundTransparency
		buttonImage.BackgroundTransparency = 1
		buttonImage.ImageTransparency = 1
		table.insert(
			tweensForFadeOut,
			TweenService:Create(buttonImage, tweenInfoQuick, { ImageTransparency = 1, BackgroundTransparency = 1 })
		)
		table.insert(
			tweensForFadeIn,
			TweenService:Create(buttonImage, tweenInfoQuick, {
				ImageTransparency = buttonImageTransparency,
				BackgroundTransparency = buttonImageBackgroundTransparency,
			})
		)
	end

	local function setupIconTweens()
		local iconBackgroundTransparency = icon.BackgroundTransparency
		local iconImageTransparency = icon.ImageTransparency
		icon.BackgroundTransparency = 1
		icon.ImageTransparency = 1
		table.insert(
			tweensForFadeOut,
			TweenService:Create(icon, tweenInfoQuick, { ImageTransparency = 1, BackgroundTransparency = 1 })
		)
		table.insert(
			tweensForFadeIn,
			TweenService:Create(
				icon,
				tweenInfoQuick,
				{ ImageTransparency = iconImageTransparency, BackgroundTransparency = iconBackgroundTransparency }
			)
		)
	end

	if inputType == Enum.ProximityPromptInputType.Gamepad then
		if GamepadButtonImage[prompt.GamepadKeyCode] then
			setupIconTweens()
			icon.Image = GamepadButtonImage[prompt.GamepadKeyCode]

			-- Hide ButtonText and ButtonImage, show ButtonTextImage
			buttonText.Visible = false
			buttonImage.Visible = false
			icon.Visible = true
		end
	elseif inputType == Enum.ProximityPromptInputType.Touch then
		setupButtonImageTweens()
		buttonImage.Image = "rbxasset://textures/ui/Controls/TouchTapIcon.png"

		-- Hide ButtonText and ButtonTextImage, show ButtonImage
		buttonText.Visible = false
		icon.Visible = false
		buttonImage.Visible = true
	else
		setupButtonImageTweens()

		-- Show ButtonImage
		buttonImage.Visible = true

		local buttonTextString = UserInputService:GetStringForKeyCode(prompt.KeyboardKeyCode)

		local buttonTextImage = KeyboardButtonImage[prompt.KeyboardKeyCode]
		if buttonTextImage == nil then
			buttonTextImage = KeyboardButtonIconMapping[buttonTextString]
		end

		if buttonTextImage == nil then
			local keyCodeMappedText = KeyCodeToTextMapping[prompt.KeyboardKeyCode]
			if keyCodeMappedText then
				buttonTextString = keyCodeMappedText
			end
		end

		if buttonTextImage then
			setupIconTweens()
			icon.Image = buttonTextImage

			--  Hide ButtonText, show ButtonTextImage
			buttonText.Visible = false
			icon.Visible = true
		elseif buttonTextString ~= nil and buttonTextString ~= "" then
			if string.len(buttonTextString) > 2 then
				buttonText.TextSize = math.round(buttonText.TextSize * 6 / 7)
			end
			setupButtonTextTweens()
			buttonText.Text = buttonTextString

			-- Hide ButtonTextImage, show ButtonText
			icon.Visible = false
			buttonText.Visible = true
		else
			error(
				"ProximityPrompt '"
					.. prompt.Name
					.. "' has an unsupported keycode for rendering UI: "
					.. tostring(prompt.KeyboardKeyCode)
			)
		end
	end

	if inputType == Enum.ProximityPromptInputType.Touch or prompt.ClickablePrompt then
		local button = promptUI.TextButton

		local buttonDown = false

		button.InputBegan:Connect(function(input)
			if
				(
					input.UserInputType == Enum.UserInputType.Touch
					or input.UserInputType == Enum.UserInputType.MouseButton1
				) and input.UserInputState ~= Enum.UserInputState.Change
			then
				prompt:InputHoldBegin()
				buttonDown = true
			end
		end)
		button.InputEnded:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				if buttonDown then
					buttonDown = false
					prompt:InputHoldEnd()
				end
			end
		end)

		promptUI.Active = true
	end

	local circleBar = resizeableInputFrame.ProgressBar
	setUpCircularProgressBar(circleBar)

	local holdBeganConnection
	local holdEndedConnection
	local triggeredConnection
	local triggerEndedConnection

	-- Timed per hold, since HoldDuration can change while the prompt is up. Costs nothing on a press-to-fire one
	local holdTween

	holdBeganConnection = prompt.PromptButtonHoldBegan:Connect(function()
		for _, tween in ipairs(tweensForButtonHoldBegin) do
			tween:Play()
		end

		holdTween = TweenService:Create(
			circleBar.Progress,
			TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
			{ Value = 1 }
		)
		holdTween:Play()
	end)

	holdEndedConnection = prompt.PromptButtonHoldEnded:Connect(function()
		-- Written straight back, not tweened: the ring must be empty on the frame the hold lets go
		if holdTween then
			holdTween:Cancel()
			holdTween = nil
		end
		circleBar.Progress.Value = 0

		for _, tween in ipairs(tweensForButtonHoldEnd) do
			tween:Play()
		end
	end)

	triggeredConnection = prompt.Triggered:Connect(function()
		for _, tween in ipairs(tweensForFadeOut) do
			tween:Play()
		end
	end)

	triggerEndedConnection = prompt.TriggerEnded:Connect(function()
		if not prompt.Enabled then
			return
		end

		for _, tween in ipairs(tweensForFadeIn) do
			tween:Play()
		end
	end)

	local enabledConnection = prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
		if prompt.Enabled then
			return
		end

		for _, tween in ipairs(tweensForFadeOut) do
			tween:Play()
		end
	end)

	local function updateUIFromPrompt()
		if not prompt.Enabled then
			return
		end
		-- todo: Use AutomaticSize instead of GetTextSize when that feature becomes available
		local actionTextParams = Instance.new("GetTextBoundsParams")
		actionTextParams.Text = prompt.ActionText
		actionTextParams.Font = actionText.FontFace
		actionTextParams.Size = actionText.TextSize
		actionTextParams.Width = 1000
		local actionTextSize = TextService:GetTextBoundsAsync(actionTextParams)

		local objectTextParams = Instance.new("GetTextBoundsParams")
		objectTextParams.Text = prompt.ObjectText
		objectTextParams.Font = objectText.FontFace
		objectTextParams.Size = objectText.TextSize
		objectTextParams.Width = 1000
		local objectTextSize = TextService:GetTextBoundsAsync(objectTextParams)

		local maxTextWidth = math.max(actionTextSize.X, objectTextSize.X)
		local promptHeight = 72
		local promptWidth = 72
		local textPaddingLeft = 72

		if
			(prompt.ActionText ~= nil and prompt.ActionText ~= "")
			or (prompt.ObjectText ~= nil and prompt.ObjectText ~= "")
		then
			promptWidth = maxTextWidth + textPaddingLeft + 24
		end

		local actionTextYOffset = 0
		if prompt.ObjectText ~= nil and prompt.ObjectText ~= "" then
			actionTextYOffset = 9
		end
		actionText.Position = UDim2.new(0.5, textPaddingLeft - promptWidth / 2, 0, actionTextYOffset)
		objectText.Position = UDim2.new(0.5, textPaddingLeft - promptWidth / 2, 0, -15)

		actionText.Text = prompt.ActionText
		objectText.Text = prompt.ObjectText
		actionText.AutoLocalize = prompt.AutoLocalize
		actionText.RootLocalizationTable = prompt.RootLocalizationTable

		objectText.AutoLocalize = prompt.AutoLocalize
		objectText.RootLocalizationTable = prompt.RootLocalizationTable

		promptUI.Size = UDim2.fromOffset(promptWidth, promptHeight)
		promptUI.SizeOffset =
			Vector2.new(prompt.UIOffset.X / promptUI.Size.Width.Offset, prompt.UIOffset.Y / promptUI.Size.Height.Offset)
	end

	local changedConnection = prompt.Changed:Connect(updateUIFromPrompt)
	updateUIFromPrompt()

	promptUI.StudsOffset = Vector3.new(0, -1, 0)
	promptUI.Adornee = prompt.Parent
	promptUI.Parent = gui

	Spr.target(promptUI, 0.5, 4, { StudsOffset = Vector3.new(0, 0, 0) })

	for _, tween in ipairs(tweensForFadeIn) do
		tween:Play()
	end

	local function cleanup()
		if holdBeganConnection then
			holdBeganConnection:Disconnect()
		end

		if holdEndedConnection then
			holdEndedConnection:Disconnect()
		end

		triggeredConnection:Disconnect()
		triggerEndedConnection:Disconnect()
		enabledConnection:Disconnect()
		changedConnection:Disconnect()

		for _, tween in ipairs(tweensForFadeOut) do
			tween:Play()
		end

		task.wait(0.2)

		-- Destroyed, not unparented -- the connections live on the UI's own descendants
		promptUI:Destroy()
	end

	return cleanup
end

-- Puts the custom UI up and arms its teardown on every way the prompt can go. Parking on PromptHidden stranded UIs, since Destroy drops the waiting thread with it.
function CustomProximityPromptController:_showPrompt(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
	if prompt.Style == Enum.ProximityPromptStyle.Default then
		return
	end

	-- Shown again without a hide: take the last UI down before putting the next one up
	self:_hidePrompt(prompt)

	local cleanup = self:_createPrompt(prompt, inputType, getScreenGui())
	local signalCleaner = Trove.new()

	local function finish()
		-- Already taken down by another of the signals below, or by the service-level hide
		if self._shown[prompt] ~= finish then
			return
		end

		self._shown[prompt] = nil
		signalCleaner:Destroy()

		-- On its own thread: the fade-out waits before destroying, and no signal should be held up by it
		task.spawn(cleanup)
	end

	self._shown[prompt] = finish

	-- Hidden, destroyed, or reparented out of the world -- whichever lands first wins
	signalCleaner:Connect(prompt.PromptHidden, finish)
	signalCleaner:Connect(prompt.Destroying, finish)
	signalCleaner:Connect(prompt.AncestryChanged, function(_, parent)
		if not parent then
			finish()
		end
	end)
end

-- Takes a prompt's custom UI down. Also off the service-level PromptHidden, which survives the prompt being destroyed.
function CustomProximityPromptController:_hidePrompt(prompt: ProximityPrompt)
	local finish = self._shown[prompt]
	if finish then
		finish()
	end
end

function CustomProximityPromptController:OnInit()
	SoundController = require(script.Parent.SoundController)

	ProximityPromptService.PromptTriggered:Connect(function()
		SoundController:PlaySound("ButtonClick")
	end)

	-- Recorded on the prompt so a component attaching mid-show can read the state rather than await the next event
	ProximityPromptService.PromptShown:Connect(function(prompt, inputType)
		prompt:SetAttribute("Shown", true)
		self:_showPrompt(prompt, inputType)
	end)

	ProximityPromptService.PromptHidden:Connect(function(prompt)
		prompt:SetAttribute("Shown", nil)
		self:_hidePrompt(prompt)
	end)
end

return CustomProximityPromptController
