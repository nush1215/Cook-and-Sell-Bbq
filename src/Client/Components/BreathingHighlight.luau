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

--[[
	BreathingHighlight -- pulses an outline on a part or model to say "you can act on this now".

	Tag an instance to start it breathing and untag it to stop, so the tag *is* the eligibility
	state: the systems that already work out whether a prompt should be up (Grill:RefreshInteraction,
	StickStand:RefreshPrompt, SkewerStand:_updatePlacePrompt, ...) toggle it from the same check.
	Nothing here polls -- an untagged instance costs nothing and holds no Highlight, which also keeps
	us well inside Roblox's limited pool of active highlights.

	Attributes (optional):
		HighlightColor (Color3) default Highlights.PLACE -- drives both OutlineColor and FillColor, and
		                                                    is read live, so an instance that means two
		                                                    different things at different times (the
		                                                    griller: "put a raw skewer here" then
		                                                    "claim the cooked one") can recolour
		                                                    without being untagged and retagged.

	Don't put this and PromptSubjectHighlight on the same instance. Two Highlights sharing an adornee
	is undefined -- Roblox renders one of them and there's no saying which -- so they'd silently
	fight instead of layering.
]]
local BreathingHighlight = Component.new({
	Tag = script.Name,
})

function BreathingHighlight:Start()
	local instance: Instance = self.Instance

	self._cleaner = Trove.new()

	-- Parented to the instance rather than adorned explicitly: a Highlight with no Adornee falls back
	-- to its parent, which works the same for a Model as for a BasePart.
	local highlight = Instance.new("Highlight")
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.OutlineColor = Color3.fromRGB(0, 0, 0)
	highlight.OutlineTransparency = Highlights.OUTLINE_DIM
	highlight.FillTransparency = Highlights.FILL_DIM
	highlight.Parent = instance
	self._cleaner:Add(highlight)

	-- The outline and the fill are separate colours on a Highlight; both breathe here, so both take
	-- the attribute and the two stay the same hue.
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
