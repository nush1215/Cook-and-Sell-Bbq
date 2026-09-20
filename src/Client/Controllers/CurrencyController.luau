-- Services
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Spring = require(Packages.Spring)
local Signal = require(Packages.Signal)
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)
local RandomUtil = require(Shared.RandomUtil)
local Colors = require(Shared.Colors)

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- Controllers
local HudController = require(script.Parent.HudController)

--
local Class = script.Parent.Parent.Class
local AnimatedNumber = require(Class.AnimatedNumber)

--
local PlayerDataController

local CURRENCY_POP_UPS = {
	Left = {
		X = NumberRange.new(0.1, 0.25),
		Y = NumberRange.new(0.125, 0.725),
	},

	Right = {
		X = NumberRange.new(0.615, 0.77),
		Y = NumberRange.new(0.125, 0.725),
	},
}

-- The HUD counters, Bux first: frame under BottomLeft, profile key, "+X" template under CurrencyUI, figure prefix, gain colour, and the lifetime key a counter stays hidden until
local COUNTERS = {
	{
		DataKey = "Currency",
		Frame = "Currency",
		PopupTemplate = "CurrencyAddTemplate",
		Prefix = "$",
		GainColor = Color3.fromRGB(116, 255, 51),
	},
	{
		DataKey = "Gems",
		Frame = "Gems",
		PopupTemplate = "GemAddTemplate",
		Prefix = "",
		GainColor = Colors.Gems,
		HideUntilEarned = "TotalGemsEarned",
	},
}

--
local CurrencyController = {
	_counters = {}, -- [dataKey] = { Settings, Amount, Spring, AnimatedNumber, PopupTemplate? } for each counter set up
}

-- A counter figure behind its prefix: suffixed from `threshold` up, comma'd below it.
local function formatAmount(value: number, threshold: number, prefix: string): string
	return if value >= threshold
		then `{prefix}{GuiUtil.ConvertNumberWithSuffix(value)}`
		else `{prefix}{GuiUtil.ConvertNumberWithCommas(value)}`
end

-- Moves a counter to `new`, bumping it and floating the change off it unless nothing moved.
function CurrencyController:_updateCounter(counter, old: number, new: number)
	local amount = counter.Amount

	counter.AnimatedNumber:UpdateNumber(new)
	local didLoseCurrency = old > new
	counter.Spring:Impulse(didLoseCurrency and -3 or 3)

	-- The seed passes the balance as both, so the load floats nothing while a real gain from 0 still does
	if old == new then
		return
	end

	local value = math.floor(math.abs(new - old))

	local changeAmountTemplate = amount.ChangeAmountTemplate:Clone()
	changeAmountTemplate.Name = HttpService:GenerateGUID()
	changeAmountTemplate.TextColor3 = didLoseCurrency and Color3.fromRGB(255, 43, 43) or counter.Settings.GainColor
	changeAmountTemplate.Text = formatAmount(value, 10_000, counter.Settings.Prefix)
	changeAmountTemplate.Visible = true
	changeAmountTemplate.Parent = amount

	Spr.target(changeAmountTemplate, 0.8, 3.5, { Position = UDim2.fromScale(0, -0.75) })
	TweenService:Create(changeAmountTemplate, TweenInfo.new(1.2), { TextTransparency = 1 }):Play()
	TweenService:Create(changeAmountTemplate.UIStroke, TweenInfo.new(1.2), { Transparency = 1 }):Play()

	task.delay(2, function()
		changeAmountTemplate:Destroy()
	end)
end

-- Spawns one floating "+value" popup for a currency, Bux unless `dataKey` names another. Driven per arriving projectile (see CollectCash, CollectGems).
function CurrencyController:SpawnCurrencyPopup(value: number, dataKey: string?)
	local counter = self._counters[dataKey or "Currency"]
	if not (counter and counter.PopupTemplate) then
		return
	end

	-- Alternate sides each call so consecutive popups don't cluster on one edge.
	self._popupSide = not self._popupSide
	local side = self._popupSide and CURRENCY_POP_UPS.Left or CURRENCY_POP_UPS.Right

	local x = RandomUtil.GetRandomFromMinMax(side.X.Min, side.X.Max)
	local y = RandomUtil.GetRandomFromMinMax(side.Y.Min, side.Y.Max)

	local popup = counter.PopupTemplate:Clone()
	popup.Name = HttpService:GenerateGUID()
	popup.Amount.Text = `+{formatAmount(value, 1_000, counter.Settings.Prefix)}`
	popup.Position = UDim2.fromScale(x, y)
	popup.Visible = true
	popup.Parent = self.CurrencyUI

	Spr.target(popup, 0.8, 1, { Position = UDim2.fromScale(x, y - 0.1) })
	task.delay(0.5, function()
		TweenService:Create(popup, TweenInfo.new(1), { GroupTransparency = 1 }):Play()
		task.wait(3)
		popup:Destroy()
	end)
end

-- Builds one HUD counter off its Studio frame, seeded from the profile and following it from then on. A frame not built yet is warned about and skipped.
function CurrencyController:_setupCounter(settings)
	local frame = self.UI.BottomLeft:FindFirstChild(settings.Frame)
	if not frame then
		warn(`[Currency] HudUI.BottomLeft.{settings.Frame} is missing, so the {settings.DataKey} counter can't be shown`)
		return
	end

	local popupTemplate = self.CurrencyUI:FindFirstChild(settings.PopupTemplate)
	if not popupTemplate then
		warn(`[Currency] CurrencyUI.{settings.PopupTemplate} is missing, so {settings.DataKey} gains won't pop up`)
	end

	-- Setup spring for the counter
	local spring = Spring.new(0)
	spring.Speed = 25
	spring.Damper = 0.5

	local uiScale = frame.UIScale
	RunService.RenderStepped:Connect(function()
		uiScale.Scale = 1 + spring.Position
	end)

	local amount = frame.Amount
	local animatedNumber = AnimatedNumber.new(0, 0.5)
	animatedNumber.OnChangedValue:Connect(function(value)
		amount.Text = formatAmount(math.floor(value), 10_000, settings.Prefix)
	end)

	local counter = {
		Settings = settings,
		Amount = amount,
		Spring = spring,
		AnimatedNumber = animatedNumber,
		PopupTemplate = popupTemplate,
	}
	self._counters[settings.DataKey] = counter

	-- Setup listener for changes, seeded as a change to itself
	local current = PlayerDataController:GetKey(settings.DataKey)
	self:_updateCounter(counter, current, current)

	-- Held off the HUD until they've earned some: a currency they've never met is a number with nothing behind it
	local isLocked = settings.HideUntilEarned ~= nil and PlayerDataController:GetKey(settings.HideUntilEarned) == 0
	if isLocked then
		HudController:SetBottomLeftFrameHiddenFor(self, settings.Frame, true)
	end

	PlayerDataController:ListenForChange(settings.DataKey, function(new, old)
		self:_updateCounter(counter, old, new)

		-- Unlocked on the gain itself, so the counter springs in with their first rather than appearing cold
		if isLocked and new > 0 then
			isLocked = false
			HudController:SetBottomLeftFrameHiddenFor(self, settings.Frame, false)
		end
	end)
end

-- Sets up each HUD counter in turn.
function CurrencyController:_setupUI()
	for _, settings in COUNTERS do
		self:_setupCounter(settings)
	end
end

function CurrencyController:OnInit()
	self.UI = PlayerGui:WaitForChild("HudUI")
	self.CurrencyUI = PlayerGui:WaitForChild("CurrencyUI")

	PlayerDataController = require(script.Parent.PlayerDataController)
end

function CurrencyController:OnStart()
	task.spawn(CurrencyController._setupUI, self)
end

return CurrencyController
