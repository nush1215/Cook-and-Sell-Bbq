-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Assets
local Assets = ReplicatedStorage.Assets
local Particles = Assets.Particles
local ShowRandomParticles = Particles.ShowRandom

-- Modules
local EffectUtil = require(script.Parent.Parent.Modules.EffectUtil)

--
local CLEANUP_DELAY = 3

-- The Random Ingredient's result arriving: a burst off it. No flash -- the reveal's own highlight flashes it, and a second would fight it.
return function(loot: Model)
	local effect = EffectUtil.ParentEffectFolder(ShowRandomParticles, loot.PrimaryPart)

	effect.EmitParticles()

	task.delay(CLEANUP_DELAY, effect.Cleanup)
end
