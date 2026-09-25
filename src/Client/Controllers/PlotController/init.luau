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
local NotificationController = require(script.Parent.NotificationController)

-- Modules
local Plot = require(script.Plot)

--
local LocalPlayer = Players.LocalPlayer

-- How long a streamed-in base gets to finish replicating the plot folder _setupBase indexes.
local CHILD_TIMEOUT = 10

-- Drives every base's plot signs -- one Plot per plot, since signs must come down on bases the player doesn't own. What's buyable is the server's call; the price is read from data, so one purchase repaints them all.

--
local PlotController = {
	PurchasePlotEvent = Network.Event("PurchasePlot"),
	RequestPlotProductEvent = Network.Event("RequestPlotProduct"),

	_bases = {}, -- [baseModel: Model] = { Cleaner, Plots: { [plotModel: Model] = Plot } }
	_cleaner = Trove.new(),
}

-- Asks the server to buy this plot with currency; the price isn't the client's to send.
function PlotController:RequestPurchase(plotId: string)
	-- The server rejects it too; only the currency half is held, so the Robux button beside it still works
	if not PlayerDataController:GetKey("TutorialCompleted") then
		NotificationController:NotifyNormal({
			Text = "Finish the tutorial first!",
			Effect = "Error",
			Duration = 3,
			Sound = "Reject",
		})
		return
	end

	self.PurchasePlotEvent:FireServer(plotId)
end

-- Raises the Robux prompt server-side, which is where the chosen plot is remembered -- the receipt can't say.
function PlotController:RequestPlotProduct(plotId: string)
	self.RequestPlotProductEvent:FireServer(plotId)
end

-- Burns a bought plot's overgrowth back, as an effect since only the server knows a purchase happened.
function PlotController:PlayClearBurn(plotModel: Model)
	for _, base in self._bases do
		local plot = base.Plots[plotModel]
		if plot then
			plot:PlayClearBurn()
			return
		end
	end
end

-- Repaints every plot's sign. Cheap, and it depends on the local base and how many plots are owned.
function PlotController:RefreshSigns()
	for _, base in self._bases do
		for _, plot in base.Plots do
			plot:RefreshSign()
		end
	end
end

-- Builds and paints one plot's sign driver, skipping anything that isn't a plot or is already tracked.
function PlotController:_addPlot(base, plotModel: Instance, baseId: string)
	if not Plots.IsPlot(plotModel.Name) or base.Plots[plotModel] then
		return
	end

	local plot = base.Cleaner:Construct(Plot, plotModel, baseId)
	base.Plots[plotModel] = plot

	-- Painted on arrival: an atomic base lands whole, so no later child event would mount the sign
	plot:RefreshSign()
end

-- Drops one plot's sign driver, for a plot that's streamed out on its own.
function PlotController:_removePlot(base, plotModel: Instance)
	local plot = base.Plots[plotModel]
	if not plot then
		return
	end

	base.Cleaner:Remove(plot)
	base.Plots[plotModel] = nil
end

-- Tracks a base's plots once its folder and the player's data are in; the waits live here, so painting never yields.
function PlotController:_setupBase(baseModel: Model)
	if self._bases[baseModel] then
		return
	end

	local folder = baseModel:WaitForChild(Plots.FOLDER_NAME, CHILD_TIMEOUT)
	if not folder then
		warn(`[Plot] {baseModel.Name}'s plot folder never replicated, its signs won't render`)
		return
	end

	-- A sign's price reads player data, so it's awaited up front where a streamed-out base is still caught below
	PlayerDataController:GetReplica():await()

	-- Waiting above yields, so the base can have streamed out or been built by a racing thread
	if not baseModel.Parent or self._bases[baseModel] then
		return
	end

	local base = { Cleaner = self._cleaner:Construct(Trove), Plots = {} }
	self._bases[baseModel] = base

	-- Followed as well as swept, so a plot streaming in or out on its own is kept up with
	base.Cleaner:Connect(folder.ChildAdded, function(plotModel)
		self:_addPlot(base, plotModel, baseModel.Name)
	end)
	base.Cleaner:Connect(folder.ChildRemoved, function(plotModel)
		self:_removePlot(base, plotModel)
	end)

	for _, plotModel in folder:GetChildren() do
		self:_addPlot(base, plotModel, baseModel.Name)
	end
end

-- Drops the Plots for a base that's streamed out or been removed. Keyed by model, since its plots may already be torn off it.
function PlotController:_removeBase(baseModel: Model)
	local base = self._bases[baseModel]
	if not base then
		return
	end

	self._cleaner:Remove(base.Cleaner)
	self._bases[baseModel] = nil
end

function PlotController:OnStart()
	-- Watched rather than swept once, and off this thread since the loader runs every OnStart on one
	task.spawn(function()
		local baseFolder = workspace:WaitForChild("Base")

		self._cleaner:Connect(baseFolder.ChildAdded, function(baseModel)
			self:_setupBase(baseModel)
		end)
		self._cleaner:Connect(baseFolder.ChildRemoved, function(baseModel)
			self:_removeBase(baseModel)
		end)

		-- _setupBase waits on the base's plot folder, so keep the sweep off this thread too
		for _, baseModel in baseFolder:GetChildren() do
			task.spawn(function()
				self:_setupBase(baseModel)
			end)
		end
	end)

	-- BaseId lands after the plots are built and moves on assignment, so re-check which signs are up
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:RefreshSigns()
	end)

	-- One purchase repaints the whole set, all being priced off the same count. Listening yields, so keep it off the start thread
	task.spawn(function()
		self._cleaner:Add(PlayerDataController:ListenForChange("Plots", function()
			self:RefreshSigns()
		end))

		self:RefreshSigns()
	end)
end

return PlotController
