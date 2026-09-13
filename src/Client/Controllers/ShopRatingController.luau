-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local Rating = require(Shared.Config.Rating)

-- Controllers
local UIController = require(script.Parent.UIController)

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- Where a count stops reading well with commas and switches to a suffix, matching the currency HUD
local SUFFIX_THRESHOLD = 10_000

-- How long a counter spends climbing to its figure when the panel opens
local STAT_COUNT_DURATION = 0.5

-- Every attribute the rating publishes, so a trait landing while the panel's up redraws it
local RATING_ATTRIBUTES = { Rating.OVERALL_ATTRIBUTE }
for _, traitId in Rating.TRAITS do
	table.insert(RATING_ATTRIBUTES, Rating.GetTraitAttribute(traitId))
end

table.freeze(RATING_ATTRIBUTES)

-- A counter as its label reads it: commas while those stay readable, a suffix past them.
local function formatStat(amount: number, money: boolean?): string
	-- Held in a local first, since ConvertNumberWithCommas hands back gsub's replacement count beside the text
	local text = if amount >= SUFFIX_THRESHOLD
		then GuiUtil.ConvertNumberWithSuffix(amount)
		else GuiUtil.ConvertNumberWithCommas(amount)

	return if money then `${text}` else text
end

-- A player's star reputation and the counters behind it, drawn off the attributes RatingManager publishes onto them. Nothing is requested from the server, so a visitor's panel reads exactly what the owner's does.
local ShopRatingController = {
	StatsPanelOpenedEvent = Network.Event("StatsPanelOpened"), -- client -> server (viewedPlayer)

	_viewedPlayer = nil, -- whose figures the panel is showing; nil while it's closed
	_viewCleaner = Trove.new(), -- the viewed player's attribute listeners
}

-- Opens the panel on `player`'s rating and stats. A repeat press on the same player shuts it; one on another player repaints it in place.
function ShopRatingController:OpenPlayerStats(player: Player)
	local holder = self.UI.Holder

	if holder.Visible and self._viewedPlayer == player then
		self:Close()
		return
	end

	self._viewCleaner:Clean()
	self._viewedPlayer = player

	-- Per attribute rather than AttributeChanged, so everything else stamped on a player can't churn the redraw
	for _, attribute in RATING_ATTRIBUTES do
		self._viewCleaner:Connect(player:GetAttributeChangedSignal(attribute), function()
			self:_drawRating()
		end)
	end

	self:_drawRating()

	for dataKey in Rating.StatDisplay do
		self._viewCleaner:Connect(player:GetAttributeChangedSignal(Rating.GetStatAttribute(dataKey)), function()
			self:_drawStat(dataKey)
		end)

		-- From zero, so an opened panel always climbs
		self:_drawStat(dataKey, true)
	end

	-- Fired here rather than off OnFrameOpened, so moving an open panel onto another player still counts
	self.StatsPanelOpenedEvent:FireServer(player)

	-- Already up on someone else, so only whose figures changed: OpenFrame would toggle it shut
	if not holder.Visible then
		UIController:OpenFrame(holder)
	end
end

function ShopRatingController:Close()
	UIController:CloseFrame(self.UI.Holder)
end

-- Redraws the headline and every trait row off the viewed player. An unrated trait draws empty stars and reads as pending.
function ShopRatingController:_drawRating()
	local holder = self.UI.Holder
	local overall = self._viewedPlayer:GetAttribute(Rating.OVERALL_ATTRIBUTE)

	holder.OverallRating.OverallRating.Text = Rating.FormatTitle(Rating.OVERALL_NAME, overall)
	Rating.DrawStars(holder.OverallRating.Stars, overall)

	for traitId, display in Rating.TraitDisplay do
		local row = holder.StarRatingImprovement.Container[display.Frame]
		local stars = self._viewedPlayer:GetAttribute(Rating.GetTraitAttribute(traitId))

		row.Title.Text = Rating.FormatTitle(display.Name, stars)
		Rating.DrawStars(row.Stars, stars)
	end
end

-- Writes one counter off the viewed player. `fromZero` climbs from nothing rather than from where the label was left.
function ShopRatingController:_drawStat(dataKey: string, fromZero: boolean?)
	local display = Rating.StatDisplay[dataKey]
	local label = self.UI.Holder.Stats[display.Frame].Amount

	-- Nil until the server seeds a player who's only just joined, and the count-up can't climb to nil
	local amount = self._viewedPlayer:GetAttribute(Rating.GetStatAttribute(dataKey)) or 0

	GuiUtil.AnimateTextLabelNumber(label, amount, STAT_COUNT_DURATION, fromZero, function(current, textLabel)
		textLabel.Text = formatStat(current, display.Money)
	end)
end

function ShopRatingController:OnInit()
	self.UI = PlayerGui:WaitForChild("ShopRatingUI")
end

function ShopRatingController:OnStart()
	local holder = self.UI.Holder
	holder.Visible = false

	UIController:BindButtonClick(holder.Exit, function()
		self:Close()
	end, true)

	-- However it closes, the listeners go with it, so a shut panel isn't redrawing for anyone
	UIController.OnFrameClosed:Connect(function(frame)
		if frame == holder then
			self._viewCleaner:Clean()
			self._viewedPlayer = nil
		end
	end)

	-- Only ever set while the panel is up, so this can't spring the camera on a closed one
	Players.PlayerRemoving:Connect(function(player: Player)
		if player == self._viewedPlayer then
			self:Close()
		end
	end)
end

return ShopRatingController
