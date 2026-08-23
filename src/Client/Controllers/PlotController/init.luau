-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Plots = require(Shared.Config.Plots)

-- Controllers
local PlayerDataController = require(script.Parent.PlayerDataController)

-- Modules
local Plot = require(script.Plot)

--
local LocalPlayer = Players.LocalPlayer

--[[
    Drives the unlock signs on every base's plots.

    One Plot instance per plot, across every base, because the signs have to come down on bases the
    local player doesn't own as well as go up on the one they do -- the server plants them for
    everyone (it has one world to replicate) and hiding them is the client's half.

    Which plots are buyable is entirely the server's call: it parents a sign in only while the plot is
    reachable, so nothing here decides what's on offer. What the class reads from data is the price,
    which comes off how many plots the player has bought rather than which plot the sign stands on --
    so one purchase repaints every remaining sign, and that's what the Plots listener below is for.
]]

--
local PlotController = {
	PurchasePlotEvent = Network.Event("PurchasePlot"),
	RequestPlotProductEvent = Network.Event("RequestPlotProduct"),

	_plots = {}, -- [model: Model] = Plot
	_cleaner = Trove.new(),
}

-- Asks the server to buy this plot with currency. Which plot is the player's choice; what it costs
-- isn't, so nothing about the price goes over with it.
function PlotController:RequestPurchase(plotId: string)
	self.PurchasePlotEvent:FireServer(plotId)
end

-- Asks the server to raise the Robux prompt for this plot. Opened server-side rather than through
-- ShopController so the plot it was raised from is remembered there: the product is priced by how
-- many plots the player owns, and its receipt says nothing about which one they picked.
function PlotController:RequestPlotProduct(plotId: string)
	self.RequestPlotProductEvent:FireServer(plotId)
end

-- Burns the overgrowth back on a plot that was just bought (fired by the PlotCleared effect). Only
-- the server knows a purchase happened, which is why this comes in as an effect rather than off the
-- plot's own replicated state -- see Plot:PlayClearBurn.
function PlotController:PlayClearBurn(plotModel: Model)
	local plot = self._plots[plotModel]
	if not plot then
		return
	end

	plot:PlayClearBurn()
end

-- Repaints every plot's sign. Cheap, and it depends on both which base is the local player's and how
-- many plots they've bought, so it runs whenever either changes.
function PlotController:RefreshSigns()
	for _, plot in self._plots do
		plot:RefreshSign()
	end
end

-- Tracks a base's plots. They're authored into the place file and never come or go, so a one-off
-- sweep covers them -- it's the signs on them that move, and each Plot follows its own.
function PlotController:_setupBase(baseModel: Model)
	local folder = baseModel:FindFirstChild(Plots.FOLDER_NAME)
	if not folder then
		return
	end

	for _, plotModel in folder:GetChildren() do
		-- Anything in the folder the grid doesn't know about isn't ours to drive.
		if not Plots.IsPlot(plotModel.Name) then
			continue
		end

		local plot = Plot.new(plotModel, baseModel.Name)
		self._plots[plotModel] = plot
		self._cleaner:Add(plot)
	end
end

function PlotController:OnStart()
	-- Bases are fixed in the place file, so sweep them once. Each base drives its own plots.
	for _, baseModel in workspace.Base:GetChildren() do
		self:_setupBase(baseModel)
	end

	-- BaseId lands after the plots are already built, and changes when the local player is assigned or
	-- loses a base -- re-check which signs should be up and which should come down.
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:RefreshSigns()
	end)

	-- Buying one plot changes what every other sign on the base says, since they're all priced off the
	-- same count -- so the whole set repaints rather than just the one that was bought.
	--
	-- Listening yields on the replica, so keep it off the start thread.
	task.spawn(function()
		self._cleaner:Add(PlayerDataController:ListenForChange("Plots", function()
			self:RefreshSigns()
		end))

		self:RefreshSigns()
	end)
end

return PlotController
