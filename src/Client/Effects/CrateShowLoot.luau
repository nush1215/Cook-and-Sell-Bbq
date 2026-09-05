-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Assets
local Assets = ReplicatedStorage.Assets
local Particles = Assets.Particles
local ShowLootParticles = Particles.Crates.ShowLoot

-- Shared
local Shared = ReplicatedStorage.Shared
local CratesConfig = require(Shared.Config.Crates)

-- Modules
local EffectUtil = require(script.Parent.Parent.Modules.EffectUtil)

-- Controllers
local EffectController = require(script.Parent.Parent.Controllers.EffectController)

--
local PULSE_DURATION = 1.25
local CLEANUP_DELAY = 3

-- One reward arriving: a burst and a slow flash, still fading as the row hovers. Run per reward.
return function(loot: Model)
	EffectController:RunEffect("HighlightPulse", { loot, CratesConfig.FLASH_COLOR, PULSE_DURATION, 0 })

	local effect = EffectUtil.ParentEffectFolder(ShowLootParticles, loot.PrimaryPart)

	effect.EmitParticles()

	task.delay(CLEANUP_DELAY, effect.Cleanup)
end
