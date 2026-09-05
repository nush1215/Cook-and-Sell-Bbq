-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Shared
local Shared = ReplicatedStorage.Shared
local Boosts = require(Shared.Config.Boosts)
local GuiUtil = require(Shared.GuiUtil)

-- Controllers
local PlayerDataController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- How often the countdowns redraw. Whole seconds are all they show, so anything finer is wasted work
local TIMER_INTERVAL = 0.5

-- Draws the HUD's boost column off replicated player data: one icon per live boost, biggest at the top.

--
local BoostController = {
	_icons = {}, -- [uid] = { Frame, ExpiresAt }
}

-- Redraws every icon's countdown. One pass over the column rather than a loop per icon.
function BoostController:_refreshTimers()
	local now = workspace:GetServerTimeNow()

	for _, icon in self._icons do
		icon.Frame.Timer.Text = GuiUtil.ConvertSecondsToDHMS(math.max(icon.ExpiresAt - now, 0))
	end
end

-- Reconciles the column against player data: builds what's new, drops what's gone, re-sorts the rest.
function BoostController:_refresh()
	local now = workspace:GetServerTimeNow()
	local live = {}

	for uid, boost in PlayerDataController:GetKey("Boosts") do
		-- Expired but not yet swept, or a type since dropped from the config -- neither should draw
		if boost.ExpiresAt > now and Boosts.GetBoostFromId(boost.Type) then
			table.insert(live, { Uid = uid, Boost = boost })
		end
	end

	-- Biggest first, so the icon at the top of the column is the one actually applying
	table.sort(live, function(a, b)
		if a.Boost.Amount == b.Boost.Amount then
			return a.Boost.ExpiresAt > b.Boost.ExpiresAt
		end

		return a.Boost.Amount > b.Boost.Amount
	end)

	local showing = {}

	for order, entry in live do
		showing[entry.Uid] = true
		local icon = self._icons[entry.Uid]

		-- Built once and then left alone, so a new grant can't restart an icon already on screen
		if not icon then
			local frame = self._template:Clone()
			frame.Name = entry.Uid
			frame.Image = Boosts.GetBoostFromId(entry.Boost.Type).Icon
			frame.Title.Text = Boosts.GetLabel(entry.Boost.Type, entry.Boost.Amount)
			frame.Visible = true
			frame.Parent = self._container

			icon = { Frame = frame, ExpiresAt = entry.Boost.ExpiresAt }
			self._icons[entry.Uid] = icon
		end

		icon.Frame.LayoutOrder = order
	end

	for uid, icon in self._icons do
		if not showing[uid] then
			icon.Frame:Destroy()
			self._icons[uid] = nil
		end
	end

	self:_refreshTimers()
end

function BoostController:OnInit()
	PlayerDataController = require(script.Parent.PlayerDataController)

	self.UI = PlayerGui:WaitForChild("HudUI")
	self._container = self.UI.BottomRight.Boosts

	-- Detached so the template never draws as an entry of its own
	self._template = self._container.BoostIcon
	self._template.Parent = nil
end

function BoostController:OnStart()
	task.spawn(function()
		while true do
			task.wait(TIMER_INTERVAL)
			self:_refreshTimers()
		end
	end)

	-- Data reads await the replica, so the first build and the binding stay off the loader thread
	task.spawn(function()
		self:_refresh()

		PlayerDataController:ListenForChange("Boosts", function()
			self:_refresh()
		end)
	end)
end

return BoostController
