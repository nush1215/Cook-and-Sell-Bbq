-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- The verb copy uses for pressing something, per device: a mouse clicks, a phone taps, a pad presses
local ACTIVATION_VERBS = {
	[Enum.PreferredInput.KeyboardAndMouse] = "Click",
	[Enum.PreferredInput.Touch] = "Tap",
	[Enum.PreferredInput.Gamepad] = "Press",
}

-- The one owner of which device the player is on. Requires nothing else, so anything can require it at load without a cycle.

--
local InputController = {
	-- (Enum.PreferredInput) whenever the player switches device, such as picking up a pad mid-menu
	OnPreferredInputChanged = Signal.new(),
}

-- The device the player last used. Read live rather than cached, so it answers before OnInit has run.
function InputController:GetPreferredInput(): Enum.PreferredInput
	return UserInputService.PreferredInput
end

-- Whether the player is on a controller.
function InputController:IsGamepad(): boolean
	return UserInputService.PreferredInput == Enum.PreferredInput.Gamepad
end

-- Whether there's no pointer to aim a tool with. TouchEnabled rather than the preference, so the touch path's trigger is unchanged.
function InputController:IsCursorless(): boolean
	return UserInputService.TouchEnabled or self:IsGamepad()
end

-- "Click", "Tap" or "Press", for copy that names the action.
function InputController:GetActivationVerb(): string
	return ACTIVATION_VERBS[UserInputService.PreferredInput]
end

function InputController:OnInit()
	UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(function()
		self.OnPreferredInputChanged:Fire(UserInputService.PreferredInput)
	end)
end

function InputController:OnStart() end

return InputController
