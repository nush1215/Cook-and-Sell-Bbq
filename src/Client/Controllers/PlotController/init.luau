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

	_plots = {}, -- [model: Model] = Plot
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
	local plot = self._plots[plotModel]
	if not plot then
		return
	end

	plot:PlayClearBurn()
end

-- Repaints every plot's sign. Cheap, and it depends on the local base and how many plots are owned.
function PlotController:RefreshSigns()
	for _, plot in self._plots do
		plot:RefreshSign()
	end
end

-- Tracks a base's plots once its folder has replicated; the wait lives here, and each Plot follows its own sign.
function PlotController:_setupBase(baseModel: Model)
	local folder = baseModel:WaitForChild(Plots.FOLDER_NAME, CHILD_TIMEOUT)
	if not folder then
		warn(`[Plot] {baseModel.Name}'s plot folder never replicated, its signs won't render`)
		return
	end

	-- Waiting above yields, so the base can have streamed back out in the meantime
	if not baseModel.Parent then
		return
	end

	for _, plotModel in folder:GetChildren() do
		-- Anything in the folder the grid doesn't know about isn't ours to drive
		if not Plots.IsPlot(plotModel.Name) then
			continue
		end

		-- A racing thread can have built this plot while the folder wait yielded
		if self._plots[plotModel] then
			continue
		end

		local plot = Plot.new(plotModel, baseModel.Name)
		self._plots[plotModel] = plot
		self._cleaner:Add(plot)
	end
end

-- Drops the Plots for a base that's streamed out or been removed.
function PlotController:_removeBase(baseModel: Model)
	for plotModel, plot in self._plots do
		if plotModel:IsDescendantOf(baseModel) then
			self._cleaner:Remove(plot)
			self._plots[plotModel] = nil
		end
	end
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
