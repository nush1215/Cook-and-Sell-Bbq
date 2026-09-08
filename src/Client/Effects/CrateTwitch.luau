-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Assets
local Assets = ReplicatedStorage.Assets
local Particles = Assets.Particles
local TwitchParticles = Particles.Crates.Twitch

-- Shared
local Shared = ReplicatedStorage.Shared
local CratesConfig = require(Shared.Config.Crates)

-- Modules
local EffectUtil = require(script.Parent.Parent.Modules.EffectUtil)

-- Controllers
local Controllers = script.Parent.Parent.Controllers
local EffectController = require(Controllers.EffectController)
local SoundController = require(Controllers.SoundController)

--
local PULSE_DURATION = 0.12
local PULSE_TRANSPARENCY = 0.4
local CLEANUP_DELAY = 2

-- One rattle beat: a puff, a brief flash and the sound. Limited, so a batch reads as one crate not ten.
return function(crate: Model)
	local effect = EffectUtil.ParentEffectFolder(TwitchParticles, crate.PrimaryPart)

	EffectController:RunEffect("HighlightPulse", { crate, CratesConfig.FLASH_COLOR, PULSE_DURATION, PULSE_TRANSPARENCY })

	SoundController:PlaySound("CrateTwitch", crate.PrimaryPart, {
		PlaybackSpeed = Random.new():NextNumber(0.99, 1.01),
	}, true)

	effect.EmitParticles()

	task.delay(CLEANUP_DELAY, effect.Cleanup)
end
