-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local OfflineEarnings = require(Shared.Config.OfflineEarnings)

-- Controllers
local UIController = require(script.Parent.UIController)
local ConfettiController = require(script.Parent.ConfettiController)
local SoundController = require(script.Parent.SoundController)

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- The loader runs every OnInit on one thread, so this waits with a timeout rather than hanging the boot
local UI_TIMEOUT = 10

-- How long a claim stays locked after it's asked for, in case the server's answer never lands
local REQUEST_TIMEOUT = 3

-- What the claim's confetti rains, one per currency the claim paid out
local BUX_CONFETTI_IMAGE = "rbxassetid://105333895679693"
local GEMS_CONFETTI_IMAGE = "rbxassetid://74924203378693"

-- The welcome-back panel: what the workers sold while the player was away, paid out on Claim. The server holds the claim itself; this only shows it and asks for it.

--
local OfflineEarningController = {
	ShowOfflineEarningsEvent = Network.Event("ShowOfflineEarnings"),
	GetOfflineEarningsFunction = Network.Function("GetOfflineEarnings"),
	ClaimOfflineEarningsEvent = Network.Event("ClaimOfflineEarnings"),
	OfflineEarningsClaimResultEvent = Network.Event("OfflineEarningsClaimResult"),

	OnJoinClaimResolved = Signal.new(), -- () once the join's ask has been answered, panel up or not

	_joinClaimResolved = false, -- whether the join's ask has been answered, so a later waiter doesn't hang
	_claiming = false, -- the client half of the debounce; the server holds the authoritative one
}

-- Yields until the join's ask has been answered, so a panel that should sit behind this one can wait its turn.
function OfflineEarningController:WaitForJoinClaim()
	if not self._joinClaimResolved then
		self.OnJoinClaimResolved:Wait()
	end
end

-- Fills the panel with what the workers did and opens it.
function OfflineEarningController:ShowOfflineEarnings(data)
	if not self.UI then
		return
	end

	local holder = self.UI.Holder
	local container = holder.Container
	local amount = data.Amount

	-- Suffixed past the threshold, so a big number stays legible rather than running off the label
	container.BuxEarned.BuxAmount.Text = if amount > OfflineEarnings.SUFFIX_THRESHOLD
		then `${GuiUtil.ConvertNumberWithSuffix(amount)}`
		else `${GuiUtil.ConvertNumberWithCommas(amount)}`
	container.BbqSold.BbqSoldAmount.Text = GuiUtil.ConvertNumberWithCommas(data.BbqSold)
	container.TipsEarned.TipsAmount.Text = GuiUtil.ConvertNumberWithCommas(data.Gems)
	holder.Timer.Text = `You were gone for {GuiUtil.ConvertSecondsToHMS(data.SecondsAway)}`

	-- Queued behind a panel already up, as the daily rewards' is, so neither join panel closes the other unclaimed
	UIController:OpenFrameWhenFree(holder)
end

-- Asks the server to pay the claim out. Freed by its answer, or by the timeout if none comes.
function OfflineEarningController:RequestClaim()
	if self._claiming then
		return
	end
	self._claiming = true

	self.ClaimOfflineEarningsEvent:FireServer()

	task.delay(REQUEST_TIMEOUT, function()
		self._claiming = false
	end)
end

function OfflineEarningController:OnInit()
	-- Timed out rather than waited on, since the loader runs every OnInit on one thread
	self.UI = PlayerGui:WaitForChild(OfflineEarnings.UI_NAME, UI_TIMEOUT)

	if not self.UI then
		warn(`[OfflineEarning] PlayerGui.{OfflineEarnings.UI_NAME} is missing, so offline earnings can't be shown`)
	end
end

function OfflineEarningController:OnStart()
	if self.UI then
		local holder = self.UI.Holder
		holder.Visible = false

		UIController:BindButtonClick(holder.Claim, function()
			self:RequestClaim()
		end, true)

		-- Closing still pays: the money is theirs either way, and a dismissed panel shouldn't cost it
		UIController:BindButtonClick(holder.Exit, function()
			UIController:CloseFrame(holder)
			self:RequestClaim()
		end, true)
	end

	self.ShowOfflineEarningsEvent:OnClientEvent(function(data)
		self:ShowOfflineEarnings(data)
	end)

	-- Asked for once stood on the base, since a push on assign landed before the handler above existed and was dropped
	task.spawn(function()
		while LocalPlayer:GetAttribute("BaseId") == nil do
			LocalPlayer:GetAttributeChangedSignal("BaseId"):Wait()
		end

		-- A timed-out ask still resolves, so the panels waiting behind this one aren't held for it
		local ok, payload = pcall(function()
			return self.GetOfflineEarningsFunction:Invoke()
		end)

		if ok and payload then
			self:ShowOfflineEarnings(payload)
		elseif not ok then
			warn(`[OfflineEarning] {payload}`)
		end

		self._joinClaimResolved = true
		self.OnJoinClaimResolved:Fire()
	end)

	self.OfflineEarningsClaimResultEvent:OnClientEvent(function(data)
		self._claiming = false

		if not data.Success then
			return
		end

		if self.UI then
			UIController:CloseFrame(self.UI.Holder)
		end

		-- The same celebration a Bux purchase gets, the balance ticking up being easy to miss. Each piece picks
		-- its image at random, so a claim with tips rains about half Bux and half Gems
		local images = { BUX_CONFETTI_IMAGE }
		if data.Gems > 0 then
			table.insert(images, GEMS_CONFETTI_IMAGE)
		end

		ConfettiController:FireConfettiRain({
			Images = images,

			Colors = {
				Color3.fromRGB(255, 255, 255),
			},

			Scale = 2,
			Gravity = 0.6,
			Duration = 1.5,
			Spin = false,
		})

		SoundController:PlaySound("BuxPurchased")
	end)
end

return OfflineEarningController
