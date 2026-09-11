-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Employees = require(Shared.Config.Employees)

-- Controllers
local UIController = require(script.Parent.UIController)

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- The loader runs every OnInit on one thread, so this waits with a timeout rather than hanging the boot
local UI_TIMEOUT = 10

-- The worker guide, opened off a worker's Info button. The panel it opens over is hidden rather than closed, and handed back when the guide shuts.
local WorkerGuideController = {
	_returnFrame = nil, -- the panel hidden under the guide, shown again when it closes
	_closedCallback = nil, -- the opener's own tidy-up, run once when the guide closes
}

-- Opens the guide on `role`, hiding whichever panel is up until the guide closes, then runs `onClosed` if one was given.
function WorkerGuideController:OpenRoleGuide(role: string, onClosed: (() -> ())?)
	if not self.UI then
		return
	end

	local holder = self.UI.Holder

	holder.Title.Text = `{Employees.ROLE_NAMES[role]} Guide`
	holder.Benefit.Text = Employees.ROLE_BENEFITS[role]

	for _, roleId in Employees.ROLE_ORDER do
		holder[roleId].Visible = roleId == role
	end

	-- Already up, so only the role changes: OpenFrame would toggle it shut or replay its entrance
	if holder.Visible then
		return
	end

	self._closedCallback = onClosed

	-- Hidden rather than closed, like the shop's gift picker: closing the hiring board would hand its camera back
	local returnFrame = UIController:GetOpenFrame()
	if returnFrame then
		self._returnFrame = returnFrame
		returnFrame.Visible = false
	end

	-- Independent over a hidden panel so that panel stays the open one; a normal panel when nothing's under it
	UIController:OpenFrame(holder, returnFrame ~= nil)
end

function WorkerGuideController:OnInit()
	-- Timed out rather than waited on, since the loader runs every OnInit on one thread
	self.UI = PlayerGui:WaitForChild(Employees.GUIDE_UI_NAME, UI_TIMEOUT)

	if not self.UI then
		warn(`[WorkerGuide] PlayerGui.{Employees.GUIDE_UI_NAME} is missing, so the Info buttons won't open anything`)
	end
end

function WorkerGuideController:OnStart()
	if not self.UI then
		return
	end

	local holder = self.UI.Holder
	holder.Visible = false

	-- Set here rather than trusted to the authored label, or the Stars colour prints as raw tags
	holder.Benefit.RichText = true

	UIController:BindButtonClick(holder.Exit, function()
		UIController:CloseFrame(holder)
	end, true)

	UIController.OnFrameClosed:Connect(function(frame)
		if frame == holder then
			-- Every way out lands here, Exit and the pad's B alike, so the hidden panel always comes back
			local returnFrame = self._returnFrame
			local closedCallback = self._closedCallback
			self._returnFrame = nil
			self._closedCallback = nil

			if returnFrame then
				returnFrame.Visible = true
			end

			if closedCallback then
				task.spawn(closedCallback)
			end
		elseif frame == self._returnFrame then
			-- The hidden panel was closed out from under the guide, so the guide goes with it instead of bringing it back
			self._returnFrame = nil
			UIController:CloseFrame(holder)
		end
	end)
end

return WorkerGuideController
