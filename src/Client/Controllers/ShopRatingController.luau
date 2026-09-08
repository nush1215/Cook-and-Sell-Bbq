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
local UIController
local PlayerDataController

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- [frameName] = the profile key its Amount reads, and whether it reads as money
local STATS = {
	TotalEarnings = { Key = "TotalEarned", Money = true },
	BBQSold = { Key = "SkewersSold" },
	IngredientsBought = { Key = "IngredientsBought" },
	CustomersServed = { Key = "SalesCompleted" },
}

-- Where a count stops reading well with commas and switches to a suffix, matching the currency HUD
local SUFFIX_THRESHOLD = 10_000

-- How long a counter spends climbing to its figure when the panel opens
local STAT_COUNT_DURATION = 0.5

-- Where the board sits, matched to the other fixed props rather than the roomier NPC prompts
local PROMPT_DISTANCE = 10

-- Held rather than tapped, so brushing past the board doesn't throw the panel up
local PROMPT_HOLD = 0.3

local PROMPT_ACTION_TEXT = "View Stats"

-- Where the prompt's attachment hangs off the base's rating folder
local PROMPT_ATTACHMENT = "StatPromptAttachment"

-- Long enough for a base still being built, short enough that a model missing the parts gives up and says so
local PROMPT_WAIT_TIMEOUT = 10

-- A counter as its label reads it: commas while those stay readable, a suffix past them.
local function formatStat(amount: number, money: boolean?): string
	-- Held in a local first, since ConvertNumberWithCommas hands back gsub's replacement count beside the text
	local text = if amount >= SUFFIX_THRESHOLD
		then GuiUtil.ConvertNumberWithSuffix(amount)
		else GuiUtil.ConvertNumberWithCommas(amount)

	return if money then `${text}` else text
end

-- The player's star reputation and the counters behind it, drawn off the attributes RatingManager publishes. Nothing is requested from the server: the rating is derived there and mirrored onto the player.
local ShopRatingController = {
	StatsPanelOpenedEvent = Network.Event("StatsPanelOpened"), -- client -> server (no args)

	_promptCleaner = Trove.new(), -- the View Stats prompt on the base the local player owns
}

-- Opens the panel, or shuts it again if it's the frame already up -- OpenFrame toggles on a repeat.
function ShopRatingController:Open()
	self:_drawRating()

	-- Spawned, since GetKey awaits the replica; the count-up restarts so an opened panel always climbs
	task.spawn(function()
		for frameName, stat in STATS do
			self:_drawStat(frameName, PlayerDataController:GetKey(stat.Key), true)
		end
	end)

	UIController:OpenFrame(self.UI.Holder)
end

function ShopRatingController:Close()
	UIController:CloseFrame(self.UI.Holder)
end

-- Fills a star row. Only the X offset is ours, so a gradient inset in the place file stays inset.
function ShopRatingController:_drawStars(starsFrame: Frame, stars: number?)
	for index = 1, Rating.MAX_STARS do
		local gradient = starsFrame[tostring(index)].UIGradient
		gradient.Offset = Vector2.new(Rating.GetStarOffset(stars, index), gradient.Offset.Y)
	end
end

-- Redraws the headline and every trait row. An unrated trait draws empty stars and reads as pending.
function ShopRatingController:_drawRating()
	local holder = self.UI.Holder
	local overall = LocalPlayer:GetAttribute(Rating.OVERALL_ATTRIBUTE)

	holder.OverallRating.OverallRating.Text = Rating.FormatTitle(Rating.OVERALL_NAME, overall)
	self:_drawStars(holder.OverallRating.Stars, overall)

	for traitId, display in Rating.TraitDisplay do
		local row = holder.StarRatingImprovement.Container[display.Frame]
		local stars = LocalPlayer:GetAttribute(Rating.GetTraitAttribute(traitId))

		row.Title.Text = Rating.FormatTitle(display.Name, stars)
		self:_drawStars(row.Stars, stars)
	end
end

-- Writes one counter. `fromZero` climbs from nothing rather than from where the label was left.
function ShopRatingController:_drawStat(frameName: string, amount: number, fromZero: boolean?)
	local label = self.UI.Holder.Stats[frameName].Amount

	GuiUtil.AnimateTextLabelNumber(label, amount, STAT_COUNT_DURATION, fromZero, function(current, textLabel)
		textLabel.Text = formatStat(current, STATS[frameName].Money)
	end)
end

-- Puts the View Stats prompt on the base the local player owns, so a visitor isn't offered their own figures.
function ShopRatingController:_mountStatPrompt()
	self._promptCleaner:Clean()

	local baseId = LocalPlayer:GetAttribute("BaseId")
	if not baseId then
		return
	end

	-- Waited on, since a base's parts are built as it's claimed
	task.spawn(function()
		local base = workspace:WaitForChild("Base"):WaitForChild(baseId)

		-- Timed out rather than waited on forever, so a base model missing the parts says so instead of hanging
		local ratingFolder = base:WaitForChild(Rating.BASE_FOLDER, PROMPT_WAIT_TIMEOUT)
		local attachment = ratingFolder and ratingFolder:WaitForChild(PROMPT_ATTACHMENT, PROMPT_WAIT_TIMEOUT)

		-- The waits yield, so the base can have been handed over in the meantime
		if LocalPlayer:GetAttribute("BaseId") ~= baseId then
			return
		end

		if not attachment then
			warn(`Base {baseId} has no {Rating.BASE_FOLDER}.{PROMPT_ATTACHMENT}, so it gets no {PROMPT_ACTION_TEXT} prompt`)
			return
		end

		-- On the attachment rather than the model, since a prompt parented to a Model never fires at all
		local prompt = self._promptCleaner:Add(Instance.new("ProximityPrompt"))
		prompt.ActionText = PROMPT_ACTION_TEXT
		prompt.HoldDuration = PROMPT_HOLD
		prompt.MaxActivationDistance = PROMPT_DISTANCE
		prompt.RequiresLineOfSight = false
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.Parent = attachment

		self._promptCleaner:Connect(prompt.Triggered, function()
			self:Open()
		end)
	end)
end

function ShopRatingController:OnInit()
	UIController = require(script.Parent.UIController)
	PlayerDataController = require(script.Parent.PlayerDataController)

	self.UI = PlayerGui:WaitForChild("ShopRatingUI")
end

function ShopRatingController:OnStart()
	local holder = self.UI.Holder
	holder.Visible = false

	UIController:BindButtonClick(holder.Exit, function()
		UIController:CloseFrame(holder)
	end, true)

	-- Reported off the signal rather than Open, which toggles -- calling it on an open panel shuts it
	UIController.OnFrameOpened:Connect(function(frame)
		if frame == holder then
			self.StatsPanelOpenedEvent:FireServer()
		end
	end)

	-- Every attribute the rating publishes, fanned into one redraw so a trait landing mid-session shows up
	local attributes = { Rating.OVERALL_ATTRIBUTE }
	for _, traitId in Rating.TRAITS do
		table.insert(attributes, Rating.GetTraitAttribute(traitId))
	end

	for _, attribute in attributes do
		LocalPlayer:GetAttributeChangedSignal(attribute):Connect(function()
			self:_drawRating()
		end)
	end

	self:_drawRating()

	-- BaseId lands after the controllers start and moves on assignment, so re-mount onto whichever base is theirs
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:_mountStatPrompt()
	end)

	-- Swept once, since BaseId may already be set by the time we start
	self:_mountStatPrompt()

	-- Spawned, since GetKey and ListenForChange both await the replica
	task.spawn(function()
		for frameName, stat in STATS do
			self:_drawStat(frameName, PlayerDataController:GetKey(stat.Key))

			PlayerDataController:ListenForChange(stat.Key, function(newValue: number)
				self:_drawStat(frameName, newValue)
			end)
		end
	end)
end

return ShopRatingController
