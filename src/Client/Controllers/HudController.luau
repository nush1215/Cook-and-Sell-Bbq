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
	},

	CodeUI = {
		"Top",
		"Left",
		"Right",
		"BottomLeft",
	},

	GroupRewardUI = {
		"Top",
		"Left",
		"Right",
		"BottomLeft",
	},

	ShopUI = {
		"Top",
		"Left",
		"Right",
	},
}

-- Frames inside BottomLeft that come down on their own while a UI is open, leaving the rest of the
-- frame up. The shop keeps Currency on screen deliberately: its More button is what opened the panel,
-- and the Bux total is what a player browsing Bux packs is watching.
local HIDE_IN_BOTTOM_LEFT = {
	ShopUI = {
		"FriendBoost",
	},
}

-- Where a HUD frame sits onscreen and where it slides to when something hides it. A frame doesn't have
-- to be listed here -- _getHudFramePosition infers both from where it was authored, which is the better
-- answer for anything whose layout isn't pinned by this table. Right is deliberately left off for that
-- reason: a Show written here would drag it off whatever position it was built at.
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

-- Forces every HUD frame onscreen and allows future HUD restores.
function HudController:ShowHud()
	self._uiHidden = false

	local ui = self.UI

	for _, hudFrame in ui:GetChildren() do
		if not hudFrame:IsA("GuiObject") then
			continue
		end

		-- Keep frames hidden if an open UI still claims them.
		local owners = self._hudFrameHideOwners[hudFrame]
		if owners and next(owners) then
			continue
		end

		self:_setHudFrameHidden(hudFrame, false, true)
	end
end

-- Forces every HUD frame offscreen and blocks normal HUD restores. Frames named
-- in keepFrames are forced onscreen instead and stay put until ShowHud is called.
-- @param keepFrames: optional list of HUD frame names to leave visible
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

-- Registers `owner` as a persistent hide claim on every HUD frame except those named
-- in keepFrames. Unlike HideHud these frames stay hidden through later ShowHud calls
-- (ShowHud skips owner-claimed frames), so a transient HUD restore elsewhere -- e.g.
-- the tame minigame ending -- can't reveal them. Cleared with ReleaseHud(owner).
-- @param owner: any unique key identifying the caller's claim
-- @param keepFrames: optional list of HUD frame names to leave visible
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

-- Drops `owner`'s persistent hide claim from every HUD frame, restoring any frame no
-- longer claimed by another owner. Reverses KeepHudHidden.
-- @param owner: the same key passed to KeepHudHidden
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

-- Adds or drops `owner`'s hide claim on a single HUD frame -- the per-frame counterpart to the two above,
-- for a caller that wants one frame back for a moment without giving up its claim on the rest. Releasing
-- only brings the frame up if nobody else is still holding it down.
-- @param owner: the same key passed to KeepHudHidden
-- @param frameName: the HUD frame to claim or release
-- @param hidden: true to hold it down, false to let it back up
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

-- Gets the configured position for a HUD frame, or infers a matching offscreen hide position.
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

-- Returns a HUD button's frame and the clickable button inside it, or nil (with a warning) if the HUD
-- has no such button. Named buttons sit at varying depths under HudUI and some are the GuiButton
-- themselves while others wrap one, so this is the one place that knows how to find either -- anything
-- that wants to point at a button, or listen to one already bound, reads it from here.
-- @param buttonName: string - The name of the button's frame in HudUI
-- @return: the frame to position against, and the GuiButton that takes the click
function HudController:GetHudButton(buttonName: string): (GuiObject?, GuiButton?)
	local buttonFrame = self.UI:FindFirstChild(buttonName, true)
	if not buttonFrame then
		warn(`Button {buttonName} not found in HudUI`)
		return nil, nil
	end

	-- A wrapper frame is looked up rather than indexed so a half-authored button -- the frame built but
	-- the GuiButton inside it not -- warns like a missing one instead of erroring. It's the caller that
	-- pays for that: binding a HUD button is the first thing a controller's UI setup does, so a throw
	-- here takes down everything that controller was about to build, not just its button.
	local button = if buttonFrame:IsA("GuiButton") then buttonFrame else buttonFrame:FindFirstChild("Button")
	if not button then
		warn(`Button {buttonName} in HudUI has no GuiButton inside it to take the click`)
		return nil, nil
	end

	return buttonFrame, button
end

-- Binds a button to the hud and returns a table with the button, start alert and stop alert functions
-- @param buttonName: string - The name of the button to bind
-- @param callback: () -> () - The callback to call when the button is clicked
-- @return: { Disconnect: () -> (), Button: GuiObject, StartAlert: () -> (), StopAlert: () -> () }
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

	--
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

	--
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

-- Listens for frame changes and hides the hud if the frame is in the HIDE_UI_FOR_FRAMES table
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

				-- Delay restore so UI frame swaps can claim the same HUD before it animates back.
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
end

function HudController:OnStart()
	task.spawn(HudController._listenForFrameChanges, self)
end

return HudController
