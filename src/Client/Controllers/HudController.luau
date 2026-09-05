-- Services
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Spr = require(Packages.Spr)

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

--
local UIController

--
local HIDE_HUD_FOR_UI = {
	IndexUI = {
		"Top",
		"Left",
		"Right",
		"BottomLeft",
		"BottomRight",
	},

	CodeUI = {
		"Top",
		"Left",
		"Right",
		"BottomLeft",
		"BottomRight",
	},

	GroupRewardUI = {
		"Top",
		"Left",
		"Right",
		"BottomLeft",
		"BottomRight",
	},

	ShopUI = {
		"Top",
		"Left",
		"Right",
		"BottomRight",
	},
}

-- Frames that come down on their own while a UI is open. The shop keeps Currency, which is what a Bux browser is watching
local HIDE_IN_BOTTOM_LEFT = {
	ShopUI = {
		"FriendBoost",
	},
}

-- Where a HUD frame sits and slides to. Unlisted frames infer both from where they were authored, which is why Right is left off
local HUD_FRAMES_POSITIONS = {
	Top = {
		Show = UDim2.fromScale(0.5, 0.08),
		Hide = UDim2.fromScale(0.5, -0.3),
	},

	Left = {
		Show = UDim2.fromScale(0.06, 0.5),
		Hide = UDim2.fromScale(-0.1, 0.5),
	},

	BottomLeft = {
		Show = UDim2.fromScale(0.185, 0.875),
		Hide = UDim2.fromScale(0.185, 1.25),
	},

	BottomRight = {
		Show = UDim2.fromScale(0.815, 0.875),
		Hide = UDim2.fromScale(0.815, 1.25),
	},
}

--
local HudController = {
	_hudFrameOriginalPositions = {},
	_hudFrameHideOwners = {},
	_bottomLeftFrameHideOwners = {},
	_hiddenUiFrames = {},
	_hiddenBottomLeftUiFrames = {},

	_uiHidden = false,
}

-- Forces every HUD frame onscreen and allows future restores.
function HudController:ShowHud()
	self._uiHidden = false

	local ui = self.UI

	for _, hudFrame in ui:GetChildren() do
		if not hudFrame:IsA("GuiObject") then
			continue
		end

		-- Keep frames hidden if an open UI still claims them
		local owners = self._hudFrameHideOwners[hudFrame]
		if owners and next(owners) then
			continue
		end

		self:_setHudFrameHidden(hudFrame, false, true)
	end
end

-- Forces every HUD frame offscreen and blocks normal restores; `keepFrames` stay up until ShowHud.
function HudController:HideHud(keepFrames: { string }?)
	self._uiHidden = true

	local keep = {}
	if keepFrames then
		for _, frameName in keepFrames do
			keep[frameName] = true
		end
	end

	local ui = self.UI

	for _, hudFrame in ui:GetChildren() do
		if not hudFrame:IsA("GuiObject") then
			continue
		end

		self:_setHudFrameHidden(hudFrame, not keep[hudFrame.Name], true)
	end
end

-- Registers a persistent hide claim that survives later ShowHud calls, cleared with ReleaseHud.
function HudController:KeepHudHidden(owner: any, keepFrames: { string }?)
	local keep = {}
	if keepFrames then
		for _, frameName in keepFrames do
			keep[frameName] = true
		end
	end

	for _, hudFrame in self.UI:GetChildren() do
		if not hudFrame:IsA("GuiObject") or keep[hudFrame.Name] then
			continue
		end

		local owners = self._hudFrameHideOwners[hudFrame]
		if not owners then
			owners = {}
			self._hudFrameHideOwners[hudFrame] = owners
		end

		owners[owner] = true
		self:_setHudFrameHidden(hudFrame, true, true)
	end
end

-- Drops `owner`'s claim, restoring any frame no longer claimed by another. Reverses KeepHudHidden.
function HudController:ReleaseHud(owner: any)
	for hudFrame, owners in self._hudFrameHideOwners do
		if not owners[owner] then
			continue
		end

		owners[owner] = nil
		if next(owners) then
			continue
		end

		self._hudFrameHideOwners[hudFrame] = nil
		self:_setHudFrameHidden(hudFrame, false, true)
	end
end

-- Claims or releases one HUD frame, for a caller wanting it back without giving up its claim on the rest.
function HudController:SetHudFrameHiddenFor(owner: any, frameName: string, hidden: boolean)
	local hudFrame = self.UI:FindFirstChild(frameName)
	if not hudFrame then
		return
	end

	local owners = self._hudFrameHideOwners[hudFrame]

	if hidden then
		if not owners then
			owners = {}
			self._hudFrameHideOwners[hudFrame] = owners
		end

		owners[owner] = true
		self:_setHudFrameHidden(hudFrame, true, true)
		return
	end

	if not owners or not owners[owner] then
		return
	end

	owners[owner] = nil
	if next(owners) then
		return
	end

	self._hudFrameHideOwners[hudFrame] = nil
	self:_setHudFrameHidden(hudFrame, false, true)
end

-- The configured position for a HUD frame, or an inferred offscreen hide position.
function HudController:_getHudFramePosition(hudFrame: GuiObject, state: "Show" | "Hide"): UDim2
	local positions = HUD_FRAMES_POSITIONS[hudFrame.Name]
	if positions and positions[state] then
		return positions[state]
	end

	local showPosition = self._hudFrameOriginalPositions[hudFrame] or hudFrame.Position
	if state == "Show" then
		return showPosition
	end

	local xScale = showPosition.X.Scale <= 0.5 and -0.1 or 1.1
	return UDim2.new(xScale, showPosition.X.Offset, showPosition.Y.Scale, showPosition.Y.Offset)
end

-- Animates one HUD frame while preserving its original show position.
function HudController:_setHudFrameHidden(hudFrame: GuiObject, hidden: boolean, force: boolean?)
	if self._uiHidden and not hidden and not force then
		return
	end

	if not self._hudFrameOriginalPositions[hudFrame] then
		self._hudFrameOriginalPositions[hudFrame] = hudFrame.Position
	end

	Spr.target(hudFrame, 0.7, 2.5, {
		Position = self:_getHudFramePosition(hudFrame, hidden and "Hide" or "Show"),
	})
end

-- A HUD button's frame and the GuiButton inside it, or nil with a warning. The one place that knows how to find either.
function HudController:GetHudButton(buttonName: string): (GuiObject?, GuiButton?)
	local buttonFrame = self.UI:FindFirstChild(buttonName, true)
	if not buttonFrame then
		warn(`Button {buttonName} not found in HudUI`)
		return nil, nil
	end

	-- Looked up rather than indexed: binding is the first thing a UI setup does, so a throw takes it all down
	local button = if buttonFrame:IsA("GuiButton") then buttonFrame else buttonFrame:FindFirstChild("Button")
	if not button then
		warn(`Button {buttonName} in HudUI has no GuiButton inside it to take the click`)
		return nil, nil
	end

	return buttonFrame, button
end

-- Binds a HUD button, returning { Disconnect, Button, StartAlert, StopAlert }.
function HudController:BindHudButton(
	buttonName: string,
	callback: () -> (),
	soundName: string?
): {
	Disconnect: () -> (),
	Button: GuiObject,
	StartAlert: () -> (),
	StopAlert: () -> (),
}
	local buttonFrame, button = self:GetHudButton(buttonName)
	if not buttonFrame then
		return
	end

	local connection = UIController:BindButtonClick(
		button,
		function()
			if self._uiHidden then
				return
			end

			callback()
		end,
		true,
		false,
		{
			ShowFrame = buttonFrame,
			ClickSoundName = soundName,
		}
	)

	local alertFrame = buttonFrame:FindFirstChild("Alert")
	return {
		Disconnect = connection.Disconnect,
		StartAlert = function()
			if not alertFrame then
				return
			end

			Spr.target(alertFrame.UIScale, 0.35, 4, { Scale = 1 })
		end,

		StopAlert = function()
			if not alertFrame then
				return
			end

			Spr.target(alertFrame.UIScale, 0.7, 4, { Scale = 0 })
		end,

		IsAlerted = function()
			return alertFrame and alertFrame.UIScale.Scale > 0.01
		end,

		Button = buttonFrame,
	}
end

-- Listens for frame changes and hides the HUD for frames in HIDE_UI_FOR_FRAMES
function HudController:_listenForFrameChanges()
	UIController.OnFrameOpened:Connect(function(frame)
		local screenGui = frame:FindFirstAncestorOfClass("ScreenGui")
		if not screenGui then
			return
		end

		local hudFrameNames = HIDE_HUD_FOR_UI[screenGui.Name]
		if hudFrameNames then
			self._hiddenUiFrames[frame] = hudFrameNames

			for _, hudFrameName in hudFrameNames do
				local hudFrame = self.UI:FindFirstChild(hudFrameName)
				if not hudFrame or not hudFrame:IsA("GuiObject") then
					warn(`Hud frame {hudFrameName} not found in HudUI`)
					continue
				end

				local owners = self._hudFrameHideOwners[hudFrame]
				if not owners then
					owners = {}
					self._hudFrameHideOwners[hudFrame] = owners
				end

				owners[frame] = true
				self:_setHudFrameHidden(hudFrame, true)
			end
		end

		local bottomLeftFrameNames = HIDE_IN_BOTTOM_LEFT[screenGui.Name]
		if not bottomLeftFrameNames then
			return
		end

		local bottomLeft = self.UI:FindFirstChild("BottomLeft")
		if not bottomLeft or not bottomLeft:IsA("GuiObject") then
			warn("BottomLeft not found in HudUI")
			return
		end

		self._hiddenBottomLeftUiFrames[frame] = bottomLeftFrameNames

		for _, bottomLeftFrameName in bottomLeftFrameNames do
			local bottomLeftFrame = bottomLeft:FindFirstChild(bottomLeftFrameName)
			if not bottomLeftFrame or not bottomLeftFrame:IsA("GuiObject") then
				warn(`BottomLeft frame {bottomLeftFrameName} not found in HudUI`)
				continue
			end

			local owners = self._bottomLeftFrameHideOwners[bottomLeftFrame]
			if not owners then
				owners = {}
				self._bottomLeftFrameHideOwners[bottomLeftFrame] = owners
			end

			owners[frame] = true
			bottomLeftFrame.Visible = false
		end
	end)

	UIController.OnFrameClosed:Connect(function(frame)
		local hudFrameNames = self._hiddenUiFrames[frame]
		if hudFrameNames then
			self._hiddenUiFrames[frame] = nil

			for _, hudFrameName in hudFrameNames do
				local hudFrame = self.UI:FindFirstChild(hudFrameName)
				if not hudFrame or not hudFrame:IsA("GuiObject") then
					continue
				end

				local owners = self._hudFrameHideOwners[hudFrame]
				if not owners then
					continue
				end

				owners[frame] = nil

				if next(owners) then
					continue
				end

				self._hudFrameHideOwners[hudFrame] = nil

				-- Delay the restore so a UI frame swap can claim the same HUD before it animates back
				task.defer(function()
					local currentOwners = self._hudFrameHideOwners[hudFrame]
					if currentOwners and next(currentOwners) then
						return
					end

					self:_setHudFrameHidden(hudFrame, false)
				end)
			end
		end

		local bottomLeftFrameNames = self._hiddenBottomLeftUiFrames[frame]
		if not bottomLeftFrameNames then
			return
		end

		self._hiddenBottomLeftUiFrames[frame] = nil

		local bottomLeft = self.UI:FindFirstChild("BottomLeft")
		if not bottomLeft or not bottomLeft:IsA("GuiObject") then
			return
		end

		for _, bottomLeftFrameName in bottomLeftFrameNames do
			local bottomLeftFrame = bottomLeft:FindFirstChild(bottomLeftFrameName)
			if not bottomLeftFrame or not bottomLeftFrame:IsA("GuiObject") then
				continue
			end

			local owners = self._bottomLeftFrameHideOwners[bottomLeftFrame]
			if not owners then
				continue
			end

			owners[frame] = nil

			if next(owners) then
				continue
			end

			self._bottomLeftFrameHideOwners[bottomLeftFrame] = nil

			task.defer(function()
				local currentOwners = self._bottomLeftFrameHideOwners[bottomLeftFrame]
				if currentOwners and next(currentOwners) then
					return
				end

				bottomLeftFrame.Visible = true
			end)
		end
	end)
end

function HudController:OnInit()
	self.UI = PlayerGui:WaitForChild("HudUI")
	UIController = require(script.Parent.UIController)

	-- Adjust the top HUD frame position for touch devices
	if UserInputService.TouchEnabled then
		HUD_FRAMES_POSITIONS.Top.Hide = UDim2.fromScale(0.5, -0.5)
		HUD_FRAMES_POSITIONS.Top.Show = UDim2.fromScale(0.5, 0.22)
	end

	-- Snapped up front: a frame otherwise sits wrong until something opens, which on touch is every join
	for _, hudFrame in self.UI:GetChildren() do
		if not hudFrame:IsA("GuiObject") then
			continue
		end

		hudFrame.Position = self:_getHudFramePosition(hudFrame, "Show")
	end
end

function HudController:OnStart()
	task.spawn(HudController._listenForFrameChanges, self)
end

return HudController
