-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local TopbarPlus = require(Packages.TopbarPlus)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

-- Controllers
local UIController
local NotificationController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- Matches CodeManager's own cooldown, so a spammed Claim never round-trips just to be rejected.
local CLAIM_COOLDOWN = 1

--[[
	Drives the Codes screen. A topbar button toggles the panel; the player types a code and hits
	Claim (or presses Enter) to send it to CodeManager. The server owns all validation and reports
	every outcome through its own notifications, so this side only guards empty input and spam.
]]
local CodeController = {
	ClaimCodeEvent = Network.Event("ClaimCode"),

	_lastClaimAt = 0,
}

-- Sends whatever is typed in the box to the server, then clears it ready for the next code.
function CodeController:ClaimCode()
	if time() - self._lastClaimAt < CLAIM_COOLDOWN then
		return
	end

	local textBox = self.UI.Holder.TextBox
	local code = textBox.Text:match("^%s*(.-)%s*$")

	if code == "" then
		NotificationController:NotifyNormal({
			Text = "Enter a code first",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return
	end

	self._lastClaimAt = time()
	self.ClaimCodeEvent:FireServer(code)
	textBox.Text = ""
end

function CodeController:OnInit()
	UIController = require(script.Parent.UIController)
	NotificationController = require(script.Parent.NotificationController)

	self.UI = PlayerGui:WaitForChild("CodeUI")
end

function CodeController:OnStart()
	local holder = self.UI.Holder
	holder.Visible = false

	-- Temporary entry point until a Codes button exists in HudUI. oneClick keeps the icon momentary,
	-- so each press just re-runs OpenFrame, which closes the panel when it's already the open frame.
	-- autoDeselect is off because TopbarPlus otherwise deselects every other icon when this one is
	-- pressed, which would silently un-mute the game for anyone playing with the mute button on.
	local codesButton = TopbarPlus.new()
	codesButton:setLabel("Codes")
	codesButton:autoDeselect(false)
	codesButton:oneClick(true)

	codesButton.selected:Connect(function()
		UIController:OpenFrame(holder)
	end)

	UIController:BindButtonClick(holder.Exit, function()
		UIController:CloseFrame(holder)
	end, true)

	UIController:BindButtonClick(holder.Claim, function()
		self:ClaimCode()
	end, true)

	holder.TextBox.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			self:ClaimCode()
		end
	end)
end

return CodeController
