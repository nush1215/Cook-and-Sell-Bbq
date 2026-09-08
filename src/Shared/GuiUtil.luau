-- Services
local TweenService = game:GetService("TweenService")

-- Constants
local TRANSPARENCY_PROPERTIES = {
	"Transparency",
	"TextTransparency",
	"BackgroundTransparency",
	"ImageTransparency",
	"ScrollBarImageTransparency",
}

local IGNORED_CLASSES = {
	UIGradient = true,
}

local NUMBER_SUFFIXES = {
	"K",
	"M",
	"B",
	"T",
	"Qa",
	"Qi",
	"Sx",
	"Sp",
	"Oc",
	"No",
	"Dc",
}

local CLEANUP_DELAY = 1
local PULSE_CLEANUP_DELAY = 0.5
local DEFAULT_COUNT_DURATION = 0.6

local GuiUtil = {}

-- The Robux glyph, so a price reads the way every other one in the app does
GuiUtil.ROBUX_ICON = utf8.char(0xE002)

local activeTextLabelNumberAnimations = setmetatable({}, { __mode = "k" })
local rememberedTextLabelNumbers = setmetatable({}, { __mode = "k" })

-- Animates a TextLabel number from its remembered value to a goal value.
function GuiUtil.AnimateTextLabelNumber(
	textLabel: TextLabel,
	goal: number,
	duration: number?,
	resetToZero: boolean?,
	onChanged: ((number, TextLabel) -> ())?
)
	local previousAnimation = activeTextLabelNumberAnimations[textLabel]
	local startValue = if resetToZero then 0 else rememberedTextLabelNumbers[textLabel] or 0

	if previousAnimation then
		if not resetToZero then
			startValue = previousAnimation.ValueObject.Value
		end

		previousAnimation.Cancelled = true
		previousAnimation.Tween:Cancel()
		previousAnimation.Connection:Disconnect()
		previousAnimation.ValueObject:Destroy()
	end

	local valueObject = Instance.new("IntValue")
	valueObject.Value = startValue

	local connection = valueObject:GetPropertyChangedSignal("Value"):Connect(function()
		rememberedTextLabelNumbers[textLabel] = valueObject.Value

		if onChanged then
			onChanged(valueObject.Value, textLabel)
		else
			textLabel.Text = tostring(valueObject.Value)
		end
	end)

	local tweenInfo = TweenInfo.new(duration or DEFAULT_COUNT_DURATION, Enum.EasingStyle.Linear)
	local tween = TweenService:Create(valueObject, tweenInfo, { Value = goal })
	local animation = {
		Cancelled = false,
		Connection = connection,
		Tween = tween,
		ValueObject = valueObject,
	}

	activeTextLabelNumberAnimations[textLabel] = animation

	tween.Completed:Once(function(playbackState)
		if animation.Cancelled or activeTextLabelNumberAnimations[textLabel] ~= animation then
			return
		end

		activeTextLabelNumberAnimations[textLabel] = nil
		connection:Disconnect()

		if playbackState == Enum.PlaybackState.Completed then
			rememberedTextLabelNumbers[textLabel] = goal
		end

		task.delay(CLEANUP_DELAY, function()
			valueObject:Destroy()
		end)
	end)

	tween:Play()
end

-- Pulses a text label by cloning it and animating its scale and transparency.
function GuiUtil.PulseText(textLabel: TextLabel, pulseScale: number, duration: number)
	local pulseText = textLabel:Clone()
	pulseText.Parent = textLabel.Parent
	pulseText.ZIndex = textLabel.ZIndex - 1

	-- Ensure UIScale exists
	local uiScale = pulseText:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = pulseText
	end

	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear)

	-- Animate scale and text transparency
	TweenService:Create(uiScale, tweenInfo, { Scale = pulseScale }):Play()
	TweenService:Create(pulseText, tweenInfo, { TextTransparency = 1 }):Play()

	-- Animate UIStroke if present
	local uiStroke = pulseText:FindFirstChildOfClass("UIStroke")
	if uiStroke then
		TweenService:Create(uiStroke, tweenInfo, { Transparency = 1 }):Play()
	end

	-- Clean up after animation
	task.delay(duration + PULSE_CLEANUP_DELAY, function()
		pulseText:Destroy()
	end)
end

-- Formats a number with comma separators (100000 -> "100,000").
function GuiUtil.ConvertNumberWithCommas(amount: number): string
	local amountStr = tostring(amount)
	-- Reverse, add commas every 3 digits, reverse back, remove leading comma
	return amountStr:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

-- Formats a number with short suffixes (1500 -> "1.5K", 1000000 -> "1M").
function GuiUtil.ConvertNumberWithSuffix(amount: number): string
	local absAmount = math.abs(amount)

	if absAmount < 1000 then
		return tostring(amount)
	end

	local suffixIndex = 0
	local shortenedAmount = absAmount

	while shortenedAmount >= 1000 and suffixIndex < #NUMBER_SUFFIXES do
		shortenedAmount /= 1000
		suffixIndex += 1
	end

	shortenedAmount = amount / (1000 ^ suffixIndex)

	-- Truncate to 2 decimals so 9.999M displays as "9.99M" rather than rounding up to "10M"
	if shortenedAmount >= 0 then
		shortenedAmount = math.floor(shortenedAmount * 100) / 100
	else
		shortenedAmount = math.ceil(shortenedAmount * 100) / 100
	end

	-- Format to 2 decimals, then strip trailing zeros: 1.00K -> "1K", 1.10K -> "1.1K"
	local formattedAmount = string.format("%.2f", shortenedAmount):gsub("%.?0+$", "")
	return `{formattedAmount}{NUMBER_SUFFIXES[suffixIndex]}`
end

-- Wraps text in a RichText colour tag, matching the markup Satchel renders with.
function GuiUtil.Colorize(text: string, color: Color3): string
	return string.format(
		'<font color="rgb(%d,%d,%d)">%s</font>',
		math.round(color.R * 255),
		math.round(color.G * 255),
		math.round(color.B * 255),
		text
	)
end

-- Converts seconds to MM:SS (125 -> "02:05").
function GuiUtil.ConvertSecondsToMMSS(totalSeconds: number): string
	local minutes = math.floor(totalSeconds / 60)
	local seconds = math.floor(totalSeconds % 60)
	return string.format("%02d:%02d", minutes, seconds)
end

-- Converts seconds to a compact "d h m s", showing only non-zero units, or "0s".
function GuiUtil.ConvertSecondsToDHMS(totalSeconds: number): string
	local days = math.floor(totalSeconds / 86400)
	local hours = math.floor((totalSeconds % 86400) / 3600)
	local minutes = math.floor((totalSeconds % 3600) / 60)
	local seconds = math.floor(totalSeconds % 60)

	local parts = {}

	if days > 0 then
		table.insert(parts, string.format("%dd", days))
	end
	if hours > 0 then
		table.insert(parts, string.format("%dh", hours))
	end
	if minutes > 0 then
		table.insert(parts, string.format("%dm", minutes))
	end
	if seconds > 0 then
		table.insert(parts, string.format("%ds", seconds))
	end

	-- All units zero: still show something.
	if #parts == 0 then
		return "0s"
	end

	return table.concat(parts, " ")
end

-- Converts seconds to a live countdown: units above a minute, ticking SS.hh below it. Redraw per frame.
function GuiUtil.ConvertSecondsToCountdown(totalSeconds: number): string
	if totalSeconds >= 60 then
		return GuiUtil.ConvertSecondsToDHMS(totalSeconds)
	end

	return string.format("%05.2f", math.max(totalSeconds, 0))
end

-- Converts seconds to HH:MM:SS (3665 -> "01:01:05").
function GuiUtil.ConvertSecondsToHHMMSS(totalSeconds: number): string
	local hours = math.floor(totalSeconds / 3600)
	local minutes = math.floor((totalSeconds % 3600) / 60)
	local seconds = math.floor(totalSeconds % 60)
	return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

-- Converts seconds to a human-readable string, showing only non-zero units ("5 Mins, 30 Secs").
function GuiUtil.ConvertSecondsToHumanReadable(totalSeconds: number): string
	local days = math.floor(totalSeconds / 86400)
	local hours = math.floor((totalSeconds % 86400) / 3600)
	local minutes = math.floor((totalSeconds % 3600) / 60)
	local seconds = math.floor(totalSeconds % 60)

	local parts = {}

	if days > 0 then
		table.insert(parts, string.format("%d Days", days))
	end
	if hours > 0 then
		table.insert(parts, string.format("%02d Hrs", hours))
	end
	if minutes > 0 then
		table.insert(parts, string.format("%02d Mins", minutes))
	end
	if seconds > 0 then
		table.insert(parts, string.format("%02d Secs", seconds))
	end

	-- If all units are zero, show "0 Secs"
	if #parts == 0 then
		return "0 Secs"
	end

	return table.concat(parts, ", ")
end

-- Every GUI object in `container` whose transparency can be changed, mapped to its properties.
function GuiUtil.GetCanGroupTransparent(container: GuiObject): { [GuiObject]: { string } }
	local result = {}

	-- The transparency properties that exist on a GUI object.
	local function getTransparencyProperties(guiObject: GuiObject): { string }
		if IGNORED_CLASSES[guiObject.ClassName] then
			return {}
		end

		local properties = {}
		for _, propertyName in TRANSPARENCY_PROPERTIES do
			local success = pcall(function()
				return guiObject[propertyName]
			end)

			if success then
				table.insert(properties, propertyName)
			end
		end

		return properties
	end

	-- The transparency properties worth changing on a GUI object, cached and skipping fully-transparent ones.
	local function getChangeableTransparencyProperties(guiObject: GuiObject): { string }
		local availableProperties = getTransparencyProperties(guiObject)
		local changeableProperties = {}

		for _, propertyName in availableProperties do
			local ignoreAttribute = `Ignore{propertyName}`
			local canChangeAttribute = `CanChange{propertyName}`
			local setAttribute = `Set{propertyName}Transparency`
			local originalAttribute = `Original{propertyName}`

			-- Skip if property is locked
			if guiObject:GetAttribute(ignoreAttribute) then
				continue
			end

			-- Get current or previously set transparency
			local currentTransparency = guiObject:GetAttribute(setAttribute) or guiObject[propertyName]

			-- If already fully transparent and not marked as changeable, lock it
			if currentTransparency == 1 and not guiObject:GetAttribute(canChangeAttribute) then
				guiObject:SetAttribute(ignoreAttribute, true)
				continue
			end

			-- Mark as changeable and store original value if needed
			table.insert(changeableProperties, propertyName)
			guiObject:SetAttribute(canChangeAttribute, true)

			-- Store original transparency value if it's partially transparent
			if
				currentTransparency > 0
				and currentTransparency < 1
				and not guiObject:GetAttribute(originalAttribute)
			then
				guiObject:SetAttribute(originalAttribute, guiObject[propertyName])
			end
		end

		return changeableProperties
	end

	-- Process container itself
	result[container] = getChangeableTransparencyProperties(container)

	-- Process all descendants
	for _, descendant in container:GetDescendants() do
		if not descendant:IsA("GuiObject") then
			continue
		end

		local transparencyProperties = getTransparencyProperties(descendant)
		if #transparencyProperties == 0 then
			continue
		end

		result[descendant] = getChangeableTransparencyProperties(descendant)
	end

	return result
end

-- Fades a container and every descendant that supports transparency to `transparency`.
function GuiUtil.SetGroupTransparency(container: GuiObject, transparency: number, timeToTake: number)
	local changeableObjects = GuiUtil.GetCanGroupTransparent(container)
	local tweenInfo = TweenInfo.new(timeToTake, Enum.EasingStyle.Linear)

	for guiObject, transparencyProperties in changeableObjects do
		-- Handle GuiButton visibility based on transparency
		if guiObject:IsA("GuiButton") and not guiObject:GetAttribute("VisibleConnection") then
			local propertyName = if guiObject:IsA("TextButton")
				then "BackgroundTransparency"
				elseif guiObject:IsA("ImageButton") then "ImageTransparency"
				else nil

			if propertyName then
				guiObject:SetAttribute("VisibleConnection", true)
				guiObject:GetPropertyChangedSignal(propertyName):Connect(function()
					guiObject.Visible = guiObject[propertyName] < 1
				end)
			end
		end

		-- Tween each transparency property
		for _, propertyName in transparencyProperties do
			local targetTransparency = if transparency < 1 and guiObject:GetAttribute(`Original{propertyName}`)
				then guiObject:GetAttribute(`Original{propertyName}`)
				else transparency

			TweenService:Create(guiObject, tweenInfo, { [propertyName] = targetTransparency }):Play()
			guiObject:SetAttribute(`Set{propertyName}Transparency`, targetTransparency)
		end
	end
end

return GuiUtil
