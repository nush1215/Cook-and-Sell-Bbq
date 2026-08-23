-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Assets
local Assets = ReplicatedStorage.Assets
local Particles = Assets.Particles
local LandParticles = Particles.Crates.Land

-- Shared
local Shared = ReplicatedStorage.Shared
local CratesConfig = require(Shared.Config.Crates)

-- Modules
local EffectUtil = require(script.Parent.Parent.Modules.EffectUtil)

--
local HIGHLIGHT_DURATION = 1
local HIGHLIGHT_TRANSPARENCY = 0.4
local CLEANUP_DELAY = 3

-- Dust off the ground and a flash across the crate, for anything that puts one down hard -- a thrown
-- crate arriving on its slot, an idle one landing out of a hop, and the slam it bursts on.
return function(crate: Model)
	local extents = crate:GetExtentsSize()
	local effect = EffectUtil.ParentEffectFolder(LandParticles, crate.PrimaryPart)

	-- Sit the ground particles at the bottom of the crate. Searched among the children just parented
	-- rather than off the part itself, so a leftover GroundParticles from an earlier land can't be the
	-- one that gets moved.
	local groundParticles
	for _, child in effect.Children do
		if child.Name == "GroundParticles" then
			groundParticles = child
			break
		end
	end

	if groundParticles then
		groundParticles.CFrame = CFrame.new(0, -extents.Y / 2, 0) * CFrame.Angles(math.rad(-90), 0, 0)
	end

	-- Its own highlight rather than HighlightPulse, because this one adorns the PrimaryPart instead of
	-- the whole model -- the flash reads as coming off the crate's body, not tracing its silhouette.
	local highlight = Instance.new("Highlight")
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.OutlineTransparency = 1
	highlight.FillTransparency = HIGHLIGHT_TRANSPARENCY
	highlight.FillColor = CratesConfig.FLASH_COLOR
	highlight.Parent = crate.PrimaryPart

	TweenService:Create(highlight, TweenInfo.new(HIGHLIGHT_DURATION), { FillTransparency = 1 }):Play()
	task.delay(HIGHLIGHT_DURATION, function()
		highlight:Destroy()
	end)

	effect.EmitParticles()

	task.delay(CLEANUP_DELAY, effect.Cleanup)
end
