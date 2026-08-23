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

-- One reward arriving out of a crate: a burst off it and a slow flash over it, long enough to still be
-- fading while the row hovers. Run per reward, so a crate paying out four of them fires this four times.
return function(loot: Model)
	EffectController:RunEffect("HighlightPulse", { loot, CratesConfig.FLASH_COLOR, PULSE_DURATION, 0 })

	local effect = EffectUtil.ParentEffectFolder(ShowLootParticles, loot.PrimaryPart)

	effect.EmitParticles()

	task.delay(CLEANUP_DELAY, effect.Cleanup)
end
