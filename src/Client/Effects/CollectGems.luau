-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Assets
local Assets = ReplicatedStorage.Assets
local Particles = Assets.Particles

-- Shared
local Shared = ReplicatedStorage.Shared
local Colors = require(Shared.Colors)
local RandomUtil = require(Shared.RandomUtil)

-- Modules
local PitchLadder = require(script.Parent.Parent.Modules.PitchLadder)
local EffectUtil = require(script.Parent.Parent.Modules.EffectUtil)

--
local EffectController = require(script.Parent.Parent.Controllers.EffectController)
local SoundController = require(script.Parent.Parent.Controllers.SoundController)
local CurrencyController = require(script.Parent.Parent.Controllers.CurrencyController)

--
local LocalPlayer = Players.LocalPlayer

-- Per-player pitch ladder so each tipped player ramps independently, apart from the cash one.
local pitch = PitchLadder.new({ Max = 1.7, MaxHits = 1 })

-- Plays a customer's tip: gems burst off the customer and fly into the player, their popups adding up to `gems`.
return function(origin: Model?, gems: number, targetPlayer: Player?)
	-- Sent to everyone nearby, and a client that hasn't streamed the customer in receives nil for it
	if not origin then
		return
	end

	local target = targetPlayer or LocalPlayer

	-- The assets are read in here rather than at require, where a missing one would stop every later effect loading
	local originCFrame: CFrame
	local rootPart = origin:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		originCFrame = rootPart.CFrame
		EffectUtil.BurstOffBody(origin, rootPart, Particles.Gems)
	else
		-- NPC rigs get pooled away, so the character can already be gone by the time this reaches us
		originCFrame = origin:GetPivot()
	end

	EffectController:RunEffect("HighlightPulse", { origin, Colors.Gems, 1, 0.3 })

	-- Ramp the pitch up on each consecutive tip, resetting once the player pauses for long enough.
	SoundController:PlaySound("GemCollect", originCFrame, { PlaybackSpeed = pitch:Next(target) })

	-- Never more projectiles than gems, so every one carries at least one
	local projectileAmount = math.min(RandomUtil.GetRandomIntFromMinMax(4, 6), gems)
	local projectile = Particles.GemProjectile
	local startPosition = originCFrame.Position

	-- Split exactly, the remainder going to the first few, since rounding would visibly lose gems off a tip this small
	local popupBase, popupRemainder = gems // projectileAmount, gems % projectileAmount

	EffectUtil.LaunchCollectProjectiles(
		projectile,
		startPosition,
		target,
		projectileAmount,
		function(character: Model, index: number)
			SoundController:PlaySound(
				"GemCollected",
				character.PrimaryPart,
				{ PlaybackSpeed = Random.new():NextNumber(0.97, 1) },
				true
			)

			-- Screen UI, so only the player being tipped sees them
			if target == LocalPlayer then
				CurrencyController:SpawnCurrencyPopup(popupBase + (if index <= popupRemainder then 1 else 0), "Gems")
			end
		end
	)
end
