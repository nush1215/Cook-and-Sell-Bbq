-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

-- Constants
local TWEEN_INFO = TweenInfo.new(0.5)

--[[
	PromptSubjectHighlight -- outlines whatever a ProximityPrompt is attached to for as long as that
	prompt is on screen, so the thing being offered is obvious rather than having to be picked out from
	behind the label.

	Tag an instance that holds a prompt somewhere beneath it. Unlike BreathingHighlight this says
	"you're in range of this" rather than "you can act on this" -- the prompt's own visibility is the
	whole condition, so nothing here reads eligibility.

	Attributes (optional):
		HighlightColor (Color3) default white -- the outline's colour, read live, so an instance whose
		                                         prompt changes meaning can recolour without being
		                                         untagged and retagged. Only the outline takes it: the
		                                         fill stays fully transparent here.

	Don't put this and BreathingHighlight on the same instance -- see the note there.
]]
local PromptSubjectHighlight = Component.new({
	Tag = script.Name,
})

function PromptSubjectHighlight:Construct()
	self._cleaner = Trove.new()
end

function PromptSubjectHighlight:Start()
	--
	local subject: Model = self.Instance
	local prompt: ProximityPrompt = subject:FindFirstChildWhichIsA("ProximityPrompt", true)

	--
	if not prompt then
		--	warn("PromptSubjectHighlight: Start: No ProximityPrompt found")
		return
	end

	-- Use a single, persistent highlight that we fade in/out instead of
	-- creating one on show and queuing a delayed Destroy on hide. The old
	-- approach raced: a rapid hide -> show would re-create the highlight while
	-- the previous hide's `task.delay` destroy was still pending, and because
	-- that closure captured the `highlight` upvalue it would destroy the *new*
	-- highlight — so the outline never appeared.
	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.Enabled = false
	highlight.Parent = subject
	self._cleaner:Add(highlight)

	-- Left at Roblox's default when the attribute isn't set, so an instance that never asked for a
	-- colour outlines the way it always has.
	local function applyColor()
		local color = subject:GetAttribute("HighlightColor")
		if color then
			highlight.OutlineColor = color
		end
	end

	applyColor()
	self._cleaner:Connect(subject:GetAttributeChangedSignal("HighlightColor"), applyColor)

	-- Only one fade may be active at a time. We cancel/disconnect the previous
	-- one before starting the next so fade-in and fade-out can't fight.
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
			-- Disable once fully faded out so we don't sit in Roblox's limited
			-- pool of active highlights while invisible.
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
