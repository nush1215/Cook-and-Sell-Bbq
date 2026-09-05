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

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

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

--
local CurrencyController = {}

function CurrencyController:_updateCurrency(old, new)
	local ui = self.UI
	local currency = ui.BottomLeft.Currency
	local amount = currency.Amount

	self._animatedNumber:UpdateNumber(new)
	local didLoseCurrency = old > new
	self._spring:Impulse(didLoseCurrency and -3 or 3)

	if old == 0 then
		return
	end

	local value = math.floor(math.abs(new - old))

	local changeAmountTemplate = amount.ChangeAmountTemplate:Clone()
	changeAmountTemplate.Name = HttpService:GenerateGUID()
	changeAmountTemplate.TextColor3 = didLoseCurrency and Color3.fromRGB(255, 43, 43) or Color3.fromRGB(116, 255, 51)
	changeAmountTemplate.Text = value >= 10_000 and `${GuiUtil.ConvertNumberWithSuffix(value)}`
		or `${GuiUtil.ConvertNumberWithCommas(value)}`
	changeAmountTemplate.Visible = true
	changeAmountTemplate.Parent = amount

	Spr.target(changeAmountTemplate, 0.8, 3.5, { Position = UDim2.fromScale(0, -0.75) })
	TweenService:Create(changeAmountTemplate, TweenInfo.new(1.2), { TextTransparency = 1 }):Play()
	TweenService:Create(changeAmountTemplate.UIStroke, TweenInfo.new(1.2), { Transparency = 1 }):Play()

	task.delay(2, function()
		changeAmountTemplate:Destroy()
	end)
end

-- Spawns one floating "+value" popup, driven per arriving cash projectile (see CollectCash).
function CurrencyController:SpawnCurrencyPopup(value: number)
	local currencyUI = self.CurrencyUI
	local currencyAddTemplate = currencyUI.CurrencyAddTemplate

	-- Alternate sides each call so consecutive popups don't cluster on one edge.
	self._popupSide = not self._popupSide
	local side = self._popupSide and CURRENCY_POP_UPS.Left or CURRENCY_POP_UPS.Right

	local x = RandomUtil.GetRandomFromMinMax(side.X.Min, side.X.Max)
	local y = RandomUtil.GetRandomFromMinMax(side.Y.Min, side.Y.Max)

	local popup = currencyAddTemplate:Clone()
	popup.Name = HttpService:GenerateGUID()
	popup.Amount.Text = value >= 1_000 and `+${GuiUtil.ConvertNumberWithSuffix(value)}`
		or `+${GuiUtil.ConvertNumberWithCommas(value)}`
	popup.Position = UDim2.fromScale(x, y)
	popup.Visible = true
	popup.Parent = currencyUI

	Spr.target(popup, 0.8, 1, { Position = UDim2.fromScale(x, y - 0.1) })
	task.delay(0.5, function()
		TweenService:Create(popup, TweenInfo.new(1), { GroupTransparency = 1 }):Play()
		task.wait(3)
		popup:Destroy()
	end)
end

function CurrencyController:_setupUI()
	local ui = self.UI
	local currency = ui.BottomLeft.Currency

	-- Setup spring for currency UI
	local spring = Spring.new(0)
	spring.Speed = 25
	spring.Damper = 0.5
	self._spring = spring

	RunService.RenderStepped:Connect(function(deltaTime)
		currency.UIScale.Scale = 1 + spring.Position
	end)

	local animatedNumber = AnimatedNumber.new(0, 0.5)
	animatedNumber.OnChangedValue:Connect(function(value)
		value = math.floor(value)
		currency.Amount.Text = value >= 10_000 and `${GuiUtil.ConvertNumberWithSuffix(value)}`
			or `${GuiUtil.ConvertNumberWithCommas(value)}`
	end)
	self._animatedNumber = animatedNumber

	--  Setup listener for currency changes
	local currentCurrency = PlayerDataController:GetKey("Currency")
	self:_updateCurrency(0, currentCurrency)

	PlayerDataController:ListenForChange("Currency", function(new, old)
		self:_updateCurrency(old, new)
	end)
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
