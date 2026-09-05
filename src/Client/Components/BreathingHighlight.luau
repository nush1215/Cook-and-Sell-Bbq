-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Highlights = require(Shared.Config.Highlights)

--
local TWEEN_INFO =
	TweenInfo.new(Highlights.BREATHE_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

-- Pulses an outline to say "you can act on this now": the tag is the eligibility state. HighlightColor is read live. Never share an adornee with PromptSubjectHighlight.
local BreathingHighlight = Component.new({
	Tag = script.Name,
})

function BreathingHighlight:Start()
	local instance: Instance = self.Instance

	self._cleaner = Trove.new()

	-- Parented rather than adorned: a Highlight with no Adornee falls back to its parent, Model or part alike
	local highlight = Instance.new("Highlight")
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.OutlineColor = Color3.fromRGB(0, 0, 0)
	highlight.OutlineTransparency = Highlights.OUTLINE_DIM
	highlight.FillTransparency = Highlights.FILL_DIM
	highlight.Parent = instance
	self._cleaner:Add(highlight)

	-- Outline and fill are separate colours; both take the attribute, so the two stay the same hue
	local function applyColor()
		local color = instance:GetAttribute("HighlightColor") or Highlights.PLACE
		highlight.OutlineColor = color
		highlight.FillColor = color
	end

	applyColor()

	-- Start at the dim end and tween to the bright one; the reversing loop plays the other half.
	local tween = TweenService:Create(highlight, TWEEN_INFO, {
		--	OutlineTransparency = Highlights.OUTLINE_BRIGHT,
		FillTransparency = Highlights.FILL_BRIGHT,
	})
	self._cleaner:Add(tween)
	tween:Play()

	self._cleaner:Connect(instance:GetAttributeChangedSignal("HighlightColor"), applyColor)
end

function BreathingHighlight:Stop()
	self._cleaner:Destroy()
end

return BreathingHighlight
