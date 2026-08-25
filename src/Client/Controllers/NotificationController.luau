-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Network = require(ReplicatedStorage.Shared.Network)
local GuiUtil = require(ReplicatedStorage.Shared.GuiUtil)
local Keywords = require(ReplicatedStorage.Shared.Config.Keywords)
local Spr = require(Packages.Spr)

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

--
local SoundController

--
local DEFAULT_DURATION = 5
local MAX_NOTIFICATIONS = 4
local MAX_PER_ITEM_UNLOCK_CONTAINER = 4

-- Error effect
local ERROR_COLOR = Color3.fromRGB(255, 0, 0)
local ERROR_FADE_TWEEN_INFO = TweenInfo.new(0.8, Enum.EasingStyle.Sine)
local ERROR_SHAKE_OFFSET = 15 -- px displacement on the X axis
local ERROR_SHAKE_DAMPING = 0.2 -- < 1 so the spring oscillates (shakes) instead of settling once
local ERROR_SHAKE_FREQUENCY = 12

--
local SUCCESS_COLOR = Color3.fromRGB(255, 255, 0)
local SUCCESS_FADE_TWEEN_INFO = TweenInfo.new(1.25, Enum.EasingStyle.Sine)

-- Counting value
local DEFAULT_COUNT_DURATION = 1
local COUNT_PLACEHOLDER = "{value}"
local COUNT_FORMATTERS = {
	Price = function(amount: number): string
		return `${GuiUtil.ConvertNumberWithSuffix(amount)}`
	end,
	Suffix = GuiUtil.ConvertNumberWithSuffix,
	Comma = GuiUtil.ConvertNumberWithCommas,
}

--
export type CountData = {
	Value: number,
	Duration: number?,
	Format: ("Price" | "Suffix" | "Comma")?,
	Color: Color3?,
}

export type NotificationData = {
	Text: string,
	Duration: number?,
	Sound: string?,
	Scale: number?,
	Effect: ("Error" | "Success")?,
	Count: CountData?,
}

export type ItemNotificationData = {
	Title: string,
	Description: string?,
	Duration: number?,
	Color: Color3,
	Icon: string,
}

--[[
	Builds the text a normal notification's title should show. Colours the words Config.Keywords names,
	substitutes `{value}` with `value` formatted (and coloured) per the notification's `Count` settings,
	and appends the "[N]" stack suffix once the same notification has fired more than once.
	@param data The notification data
	@param value The counting value to render, if the notification has a `Count`
	@param count How many times this notification has fired
	@return The title text
]]
local function renderNotificationText(data: NotificationData, value: number, count: number): string
	-- Highlight before substituting, so the scanner never walks into the value's own font tag. `{value}`
	-- itself is left alone -- there's nothing in a brace for it to match.
	local text = Keywords.Highlight(data.Text)

	if data.Count then
		local formatter = COUNT_FORMATTERS[data.Count.Format] or tostring
		local formattedValue = formatter(value)

		if data.Count.Color then
			formattedValue = GuiUtil.Colorize(formattedValue, data.Count.Color)
		end

		text = text:gsub(COUNT_PLACEHOLDER, formattedValue, 1)
	end

	if count > 1 then
		text ..= ` {GuiUtil.Colorize(`[{count}]`, Keywords.NUMBER)}`
	end

	return text
end

--[[
	Rolls a counting notification's value up from 0 to its target, re-rendering the title on every
	step. Replayed from the start whenever the notification is retriggered.
	@param notificationData The tracked notification
	@param data The notification data it was created from
]]
local function playCountAnimation(notificationData, data: NotificationData)
	local title = notificationData.Instance.Title
	title.Text = renderNotificationText(data, 0, notificationData.Count)

	GuiUtil.AnimateTextLabelNumber(
		title,
		data.Count.Value,
		data.Count.Duration or DEFAULT_COUNT_DURATION,
		true,
		function(value, textLabel)
			textLabel.Text = renderNotificationText(data, value, notificationData.Count)
		end
	)
end

-- Flashes the title red and shakes it on the X axis to signal an error.
local function playErrorEffect(notificationData)
	local title = notificationData.Instance.Title

	-- Flash red, then fade back to the default title color
	title.TextColor3 = ERROR_COLOR
	TweenService:Create(title, ERROR_FADE_TWEEN_INFO, { TextColor3 = notificationData.DefaultTitleColor }):Play()

	-- Shake on the X axis: displace, then let an underdamped spring oscillate back to rest
	local restPosition = notificationData.TitleRestPosition
	Spr.stop(title, "Position")
	title.Position = restPosition + UDim2.fromOffset(ERROR_SHAKE_OFFSET, 0)
	Spr.target(title, ERROR_SHAKE_DAMPING, ERROR_SHAKE_FREQUENCY, { Position = restPosition })
end

local function playSuccessEffect(notificationData)
	local title = notificationData.Instance.Title

	-- Flash green, then fade back to the default title color
	title.TextColor3 = SUCCESS_COLOR
	TweenService:Create(title, SUCCESS_FADE_TWEEN_INFO, { TextColor3 = notificationData.DefaultTitleColor }):Play()
end

-- Entrance/feedback handlers for normal notifications, keyed by the `Effect` field.
-- `Spawn` runs when a notification first appears; `Retrigger` (optional) runs when an
-- identical notification fires again. A missing `Effect` uses `Default`.
local NORMAL_NOTIFICATION_EFFECTS = {
	-- Pop the notification in, scaling up to its target size.
	Default = {
		Spawn = function(notificationData)
			local uiScale = notificationData.Instance.UIScale
			uiScale.Scale = 0.5
			Spr.target(uiScale, 0.5, 4, { Scale = notificationData.Scale })
		end,
	},

	-- No pop-out: appear at full size, then flash red and shake; replayed on repeat.
	Error = {
		Spawn = function(notificationData)
			notificationData.Instance.UIScale.Scale = notificationData.Scale
			playErrorEffect(notificationData)
		end,
		Retrigger = playErrorEffect,
	},
	Success = {
		Spawn = function(notificationData)
			local uiScale = notificationData.Instance.UIScale
			uiScale.Scale = 0.5
			Spr.target(uiScale, 0.5, 4, { Scale = notificationData.Scale })
			playSuccessEffect(notificationData)
		end,
		Retrigger = playSuccessEffect,
	},
}

-- Resolves the effect handlers for a notification, falling back to the default entrance.
local function getNormalEffect(effectName: string?)
	return NORMAL_NOTIFICATION_EFFECTS[effectName or "Default"] or NORMAL_NOTIFICATION_EFFECTS.Default
end

--
local NotificationController = {
	NotifyItemEvent = Network.Event("NotifyItem"),
	NotifyNormalEvent = Network.Event("NotifyNormal"),
	NotifyChatEvent = Network.Event("NotifyChat"),

	_activeNotifications = {},
	_notificationOrder = {},
	_itemUnlockFrames = {},
	_itemUnlockContainer = nil,
	_legendaryChannel = nil,
}

-- Shows a notification on the screen of the player
function NotificationController:NotifyNormal(data: NotificationData)
	--
	local ui = self.UI
	local notificationContainer = ui.NotificationContainer
	local notificationDuration = data.Duration or DEFAULT_DURATION

	-- Counting notifications are keyed on the text they end up showing, so two sales of different
	-- amounts stay separate notifications while two of the same amount still stack with "[N]".
	local countValue = if data.Count then data.Count.Value else 0
	local notification = renderNotificationText(data, countValue, 1)

	-- If already active
	if self._activeNotifications[notification] then
		local notificationData = self._activeNotifications[notification]
		notificationData.Count = notificationData.Count + 1
		notificationData.ExpiresAt = time() + notificationDuration
		notificationData.Generation = notificationData.Generation + 1

		if notificationData.FadeTweens then
			for _, tween in notificationData.FadeTweens do
				tween:Cancel()
			end

			notificationData.FadeTweens = nil
			notificationData.Instance.Title.TextTransparency = notificationData.TextTransparency
			notificationData.Instance.Title.UIStroke.Transparency = notificationData.StrokeTransparency
		end

		local orderIndex = table.find(self._notificationOrder, notificationData)
		table.remove(self._notificationOrder, orderIndex)
		table.insert(self._notificationOrder, notificationData)

		-- Update label with [N], replaying the count-up when there's a value to roll
		if data.Count then
			playCountAnimation(notificationData, data)
		else
			notificationData.Instance.Title.Text = renderNotificationText(data, 0, notificationData.Count)
		end

		-- Limited: notifications routinely arrive together -- both shops restock on the same second, grill
		-- slots finish together -- and the network layer batches a frame's worth into one dispatch, so
		-- without this the same chime plays N times stacked on itself. Only ever collapses an identical
		-- sound inside PlaySound's 0.05s window, which is never something anyone wanted to hear twice.
		SoundController:PlaySound(data.Sound or "Notify", nil, nil, true)

		local retrigger = getNormalEffect(data.Effect).Retrigger
		if retrigger then
			retrigger(notificationData)
		end

		return
	end

	-- Remove the oldest notification when all slots are occupied
	if #self._notificationOrder >= MAX_NOTIFICATIONS then
		local oldestNotification = table.remove(self._notificationOrder, 1)
		oldestNotification.Active = false

		if oldestNotification.FadeTweens then
			for _, tween in oldestNotification.FadeTweens do
				tween:Cancel()
			end
		end

		if self._activeNotifications[oldestNotification.Text] == oldestNotification then
			self._activeNotifications[oldestNotification.Text] = nil
		end

		oldestNotification.Instance:Destroy()
	end

	-- Create new notification
	local normalNotificationTemplate = ui.Templates.NormalNotificationTemplate:Clone()
	normalNotificationTemplate.Title.Text = notification
	normalNotificationTemplate.Visible = true
	normalNotificationTemplate.Parent = notificationContainer

	-- Track the notification
	local notificationData = {
		Text = notification,
		Count = 1,
		Scale = data.Scale or 1,
		ExpiresAt = time() + notificationDuration,
		Instance = normalNotificationTemplate,
		Active = true,
		Generation = 0,
		FadeTweens = nil,
		TextTransparency = normalNotificationTemplate.Title.TextTransparency,
		StrokeTransparency = normalNotificationTemplate.Title.UIStroke.Transparency,
		DefaultTitleColor = normalNotificationTemplate.Title.TextColor3,
		TitleRestPosition = normalNotificationTemplate.Title.Position,
	}
	self._activeNotifications[notification] = notificationData
	table.insert(self._notificationOrder, notificationData)

	-- Play the entrance effect (default pop-out, or a named one like "Error")
	getNormalEffect(data.Effect).Spawn(notificationData)

	if data.Count then
		playCountAnimation(notificationData, data)
	end

	-- Limited for the same reason as the retrigger path above: one chime per batch of notifications.
	SoundController:PlaySound(data.Sound or "Notify", nil, nil, true)

	-- Timer loop
	task.spawn(function()
		while notificationData.Active do
			while notificationData.Active and time() < notificationData.ExpiresAt do
				task.wait()
			end

			if not notificationData.Active then
				return
			end

			local fadeGeneration = notificationData.Generation
			local strokeTween = TweenService:Create(
				normalNotificationTemplate.Title.UIStroke,
				TweenInfo.new(0.5, Enum.EasingStyle.Sine),
				{ Transparency = 1 }
			)
			local textTween = TweenService:Create(
				normalNotificationTemplate.Title,
				TweenInfo.new(0.5, Enum.EasingStyle.Sine),
				{ TextTransparency = 1 }
			)
			notificationData.FadeTweens = { strokeTween, textTween }
			strokeTween:Play()
			textTween:Play()

			task.wait(0.5)

			if not notificationData.Active then
				return
			end

			if notificationData.Generation == fadeGeneration then
				notificationData.Active = false
				normalNotificationTemplate:Destroy()

				if self._activeNotifications[notification] == notificationData then
					self._activeNotifications[notification] = nil
				end

				local orderIndex = table.find(self._notificationOrder, notificationData)
				if orderIndex then
					table.remove(self._notificationOrder, orderIndex)
				end
			end
		end
	end)
end

-- Shows an item unlock notification on the screen of the player
function NotificationController:NotifyItem(data: ItemNotificationData)
	--
	local ui = self.UI
	local templates = ui.Templates
	local itemUnlockDuration = data.Duration or DEFAULT_DURATION

	if #self._itemUnlockFrames >= MAX_PER_ITEM_UNLOCK_CONTAINER then
		self:_despawnItemUnlockFrame(self._itemUnlockFrames[1])
	end

	local itemUnlockTemplate = templates.ItemUnlockTemplate
	local itemUnlockFrame = itemUnlockTemplate:Clone()

	--
	table.insert(self._itemUnlockFrames, itemUnlockFrame)
	self:_syncItemUnlockParents()
	self:_playItemUnlockSpawnEffect(itemUnlockFrame, data)

	task.delay(itemUnlockDuration, function()
		if table.find(self._itemUnlockFrames, itemUnlockFrame) then
			self:_despawnItemUnlockFrame(itemUnlockFrame)
		end
	end)

	return itemUnlockFrame
end

-- Adds a notification to the chat
function NotificationController:NotifyChat(notificationText: string)
	local rbxSystemTextChannel = TextChatService.TextChannels.RBXSystem
	rbxSystemTextChannel:DisplaySystemMessage(`<font color="#ffffff">{notificationText}</font>`)
end

-- Displays a global rare-tame announcement in the dedicated chat tab.
function NotificationController:NotifyGlobalAnnouncement(text: string)
	if self._legendaryChannel then
		self._legendaryChannel:DisplaySystemMessage(text)
	end
end

-- Keeps item unlock frames packed into visible container rows.
function NotificationController:_syncItemUnlockParents()
	--
	local ui = self.UI
	local notificationContainer = ui.NotificationContainer
	local itemUnlockContainerTemplate = ui.Templates.ItemUnlockContainer

	if #self._itemUnlockFrames <= 0 then
		if self._itemUnlockContainer then
			self._itemUnlockContainer:Destroy()
			self._itemUnlockContainer = nil
		end

		return
	end

	if not self._itemUnlockContainer then
		local itemUnlockContainer = itemUnlockContainerTemplate:Clone()
		itemUnlockContainer.Visible = true
		itemUnlockContainer.Parent = notificationContainer
		self._itemUnlockContainer = itemUnlockContainer
	end

	for i, itemUnlockFrame in self._itemUnlockFrames do
		itemUnlockFrame.LayoutOrder = i
		itemUnlockFrame.Parent = self._itemUnlockContainer
	end
end

-- Hook for the future item unlock spawn animation.
function NotificationController:_playItemUnlockSpawnEffect(itemUnlockFrame: GuiObject, data: ItemNotificationData)
	local holder = itemUnlockFrame.Holder
	local glows = itemUnlockFrame.Glows

	-- Setup for effect
	holder.Position = UDim2.fromScale(0.5, 1)
	holder.UIScale.Scale = 0.5
	glows.GroupTransparency = 1

	-- Setup the data
	holder.Icon.Image = data.Icon
	holder.Description.Text = data.Description
	holder.Title.Text = data.Title
	holder.InnerStroke.Color = data.Color
	holder.InnerGlow.ImageColor3 = data.Color
	glows.Glow.ImageColor3 = data.Color

	-- Do the effect
	Spr.target(holder.UIScale, 0.5, 3.5, { Scale = 1 })
	Spr.target(holder, 0.5, 3, { Position = UDim2.fromScale(0.5, 0.5) })
	TweenService:Create(glows, TweenInfo.new(0.5), { GroupTransparency = 0 }):Play()
	itemUnlockFrame.Visible = true
end

-- Hook for the future item unlock despawn animation.
function NotificationController:_playItemUnlockDespawnEffect(itemUnlockFrame: GuiObject, onComplete: () -> ())
	local holder = itemUnlockFrame.Holder
	local glows = itemUnlockFrame.Glows

	Spr.target(holder, 0.7, 3.5, { Position = UDim2.fromScale(0.5, 1) })
	Spr.target(holder.UIScale, 0.7, 3.5, { Scale = 0 })
	TweenService:Create(glows, TweenInfo.new(0.1), { GroupTransparency = 1 }):Play()

	task.delay(0.3, function()
		onComplete()
	end)
end

-- Removes one item unlock frame and reflows the remaining frames.
function NotificationController:_despawnItemUnlockFrame(itemUnlockFrame: GuiObject)
	--
	local itemUnlockFrameIndex = table.find(self._itemUnlockFrames, itemUnlockFrame)
	if not itemUnlockFrameIndex then
		return
	end

	table.remove(self._itemUnlockFrames, itemUnlockFrameIndex)

	self:_playItemUnlockDespawnEffect(itemUnlockFrame, function()
		itemUnlockFrame:Destroy()
		self:_syncItemUnlockParents()
	end)
end

function NotificationController:OnInit()
	--
	SoundController = require(script.Parent.SoundController)

	--
	self.UI = PlayerGui:WaitForChild("NotificationUI")
end

function NotificationController:OnStart()
	self.NotifyNormalEvent:OnClientEvent(function(data)
		self:NotifyNormal(data)
	end)

	self.NotifyChatEvent:OnClientEvent(function(notificationText)
		self:NotifyChat(notificationText)
	end)

	self.NotifyItemEvent:OnClientEvent(function(data)
		self:NotifyItem(data)
	end)
end

return NotificationController
