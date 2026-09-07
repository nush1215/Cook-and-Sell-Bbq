-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Assets
local UI = ReplicatedStorage.Assets.UI

-- Shared
local Shared = ReplicatedStorage.Shared
local Rating = require(Shared.Config.Rating)

-- Local Player
local LocalPlayer = Players.LocalPlayer

-- How long a streamed-in base gets to finish replicating the folder its sign sits in
local CHILD_TIMEOUT = 10

local SIGN_TEMPLATE = "SignRatingUI"

-- The signs' ScreenGui. In PlayerGui adorned back onto the world board, the way the upgrade boards mount.
local function getScreenGui(): ScreenGui
	local playerGui = LocalPlayer.PlayerGui
	local screenGui = playerGui:FindFirstChild("RatingSigns")

	if screenGui == nil then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "RatingSigns"
		screenGui.ResetOnSpawn = false
		screenGui.Parent = playerGui
	end

	return screenGui
end

-- The star sign on every base, showing that base owner's overall rating rather than the local player's -- a visitor walking past a stall sees how good it is.
local RatingSignController = {
	-- [baseModel] = { Board, Ui?, Cleaner? }; the sign is built only while the base has an owner
	_signs = {},
	_cleaner = Trove.new(),
}

-- The player who owns this base, if any. BaseId lives on the player, so the reverse lookup is a scan.
function RatingSignController:GetBaseOwner(baseId: string): Player?
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("BaseId") == baseId then
			return player
		end
	end

	return nil
end

-- Repaints every sign: builds one on a base that has an owner, drops one on a base that doesn't.
function RatingSignController:RefreshSigns()
	for baseModel, sign in self._signs do
		self:_refreshSign(baseModel, sign)
	end
end

-- Fills a star row. Only the X offset is ours, so a gradient inset in the place file stays inset.
function RatingSignController:_drawStars(starsFrame: Frame, stars: number?)
	for index = 1, Rating.MAX_STARS do
		local gradient = starsFrame[tostring(index)].UIGradient
		gradient.Offset = Vector2.new(Rating.GetStarOffset(stars, index), gradient.Offset.Y)
	end
end

-- Builds, repaints or drops one base's sign against who owns it now.
function RatingSignController:_refreshSign(baseModel: Model, sign)
	local owner = self:GetBaseOwner(baseModel.Name)

	-- An unowned base shouldn't advertise a rating, so the sign comes down rather than reading empty
	if not owner then
		if sign.Cleaner then
			self._cleaner:Remove(sign.Cleaner)
			sign.Cleaner = nil
			sign.Ui = nil
		end

		return
	end

	if not sign.Ui then
		local signCleaner = self._cleaner:Construct(Trove)
		local ui = UI[SIGN_TEMPLATE]:Clone()
		ui.Adornee = sign.Board
		ui.Active = true
		ui.Parent = getScreenGui()
		signCleaner:Add(ui)

		sign.Ui = ui
		sign.Cleaner = signCleaner
	end

	-- Nil while they're too new to be scored, which reads as an empty row rather than no sign at all
	local stars = owner:GetAttribute(Rating.OVERALL_ATTRIBUTE)

	sign.Ui.Title.Text = Rating.FormatTitle(Rating.SIGN_TITLE, stars)
	self:_drawStars(sign.Ui.Stars, stars)
end

-- Registers a base once its sign board has replicated, and paints it against whoever owns it.
function RatingSignController:_setupBase(baseModel: Model)
	if self._signs[baseModel] then
		return
	end

	-- Walked a level at a time, each guarded, so a base missing any of them gives up rather than erroring
	local board: Instance? = baseModel:WaitForChild(Rating.BASE_FOLDER, CHILD_TIMEOUT)
	for _, childName in Rating.SIGN_PATH do
		board = board and board:WaitForChild(childName, CHILD_TIMEOUT)
	end

	if not board then
		warn(`[RatingSign] {baseModel.Name} has no {Rating.BASE_FOLDER} sign board, its rating won't show`)
		return
	end

	-- Waiting above yields, so the base can have streamed out or been built by a racing thread
	if not baseModel.Parent or self._signs[baseModel] then
		return
	end

	local sign = { Board = board }
	self._signs[baseModel] = sign
	self:_refreshSign(baseModel, sign)
end

-- Drops the sign for a base that's streamed out or been removed; the clone lives in PlayerGui, so nothing else would.
function RatingSignController:_removeBase(baseModel: Model)
	local sign = self._signs[baseModel]
	if not sign then
		return
	end

	if sign.Cleaner then
		self._cleaner:Remove(sign.Cleaner)
	end

	self._signs[baseModel] = nil
end

-- Watches the two attributes that move a sign: which base they own, and what they're rated.
function RatingSignController:_watchPlayer(player: Player)
	-- Left out of the cleaner deliberately: these die with the player, where a trove would hoard them all session
	player:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:RefreshSigns()
	end)

	player:GetAttributeChangedSignal(Rating.OVERALL_ATTRIBUTE):Connect(function()
		self:RefreshSigns()
	end)
end

function RatingSignController:OnStart()
	-- Watched rather than swept once, and off this thread since the loader runs every OnStart on one
	task.spawn(function()
		local baseFolder = workspace:WaitForChild("Base")

		self._cleaner:Connect(baseFolder.ChildAdded, function(baseModel)
			self:_setupBase(baseModel)
		end)
		self._cleaner:Connect(baseFolder.ChildRemoved, function(baseModel)
			self:_removeBase(baseModel)
		end)

		-- _setupBase waits on the base's sign board, so keep the sweep off this thread too
		for _, baseModel in baseFolder:GetChildren() do
			task.spawn(function()
				self:_setupBase(baseModel)
			end)
		end
	end)

	-- Ownership and the rating both sit on players, so any of them moving can change what a sign reads
	self._cleaner:Connect(Players.PlayerAdded, function(player: Player)
		self:_watchPlayer(player)
		self:RefreshSigns()
	end)

	-- Deferred, since PlayerRemoving fires while they're still in GetPlayers and the scan would keep their sign up
	self._cleaner:Connect(Players.PlayerRemoving, function()
		task.defer(function()
			self:RefreshSigns()
		end)
	end)

	for _, player in Players:GetPlayers() do
		self:_watchPlayer(player)
	end
end

return RatingSignController
