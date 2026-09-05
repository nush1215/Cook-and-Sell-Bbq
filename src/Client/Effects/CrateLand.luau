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

-- Dust and a flash for anything putting a crate down hard: a thrown arrival, an idle hop, the slam.
return function(crate: Model)
	local extents = crate:GetExtentsSize()
	local effect = EffectUtil.ParentEffectFolder(LandParticles, crate.PrimaryPart)

	-- Searched among the children just parented, so a leftover GroundParticles can't be the one moved
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

	-- Its own highlight, adorning the PrimaryPart, so the flash reads off the body not the silhouette
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
