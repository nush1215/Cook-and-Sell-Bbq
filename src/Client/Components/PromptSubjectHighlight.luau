-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

-- Constants
local TWEEN_INFO = TweenInfo.new(0.5)

-- Outlines whatever a ProximityPrompt hangs off for as long as it's on screen -- "you're in range", where BreathingHighlight says "you can act". Never share an adornee with it.
local PromptSubjectHighlight = Component.new({
	Tag = script.Name,
})

function PromptSubjectHighlight:Construct()
	self._cleaner = Trove.new()
end

function PromptSubjectHighlight:Start()
	local subject: Model = self.Instance
	local prompt: ProximityPrompt = subject:FindFirstChildWhichIsA("ProximityPrompt", true)

	if not prompt then
		--	warn("PromptSubjectHighlight: Start: No ProximityPrompt found")
		return
	end

	-- One persistent highlight faded in and out; creating per show raced a pending delayed Destroy, which then destroyed the new one
	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.Enabled = false
	highlight.Parent = subject
	self._cleaner:Add(highlight)

	-- Left at Roblox's default when unset, so an instance that never asked for a colour is unchanged
	local function applyColor()
		local color = subject:GetAttribute("HighlightColor")
		if color then
			highlight.OutlineColor = color
		end
	end

	applyColor()
	self._cleaner:Connect(subject:GetAttributeChangedSignal("HighlightColor"), applyColor)

	-- Only one fade at a time, cancelled before the next, so fade-in and fade-out can't fight
	local activeTween: Tween?
	local activeConn: RBXScriptConnection?

	local function clearTween()
		if activeConn then
			activeConn:Disconnect()
			activeConn = nil
		end
		if activeTween then
			activeTween:Cancel()
			activeTween = nil
		end
	end
	self._cleaner:Add(clearTween)

	local function fade(targetTransparency: number, disableAfter: boolean)
		clearTween()

		highlight.Enabled = true
		local tween = TweenService:Create(highlight, TWEEN_INFO, { OutlineTransparency = targetTransparency })
		activeTween = tween

		if disableAfter then
			-- Disabled once faded out, so it doesn't hold a slot in Roblox's limited highlight pool
			activeConn = tween.Completed:Connect(function(state)
				if state == Enum.PlaybackState.Completed then
					highlight.Enabled = false
				end
				clearTween()
			end)
		end

		tween:Play()
	end

	self._cleaner:Add(prompt.PromptShown:Connect(function()
		fade(0, false)
	end))

	self._cleaner:Add(prompt.PromptHidden:Connect(function()
		fade(1, true)
	end))
end

function PromptSubjectHighlight:Stop()
	self._cleaner:Destroy()
end

return PromptSubjectHighlight
