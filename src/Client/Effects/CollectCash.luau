-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Assets
local Assets = ReplicatedStorage.Assets
local Particles = Assets.Particles

-- Shared
local Shared = ReplicatedStorage.Shared
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

-- Per-player pitch ladder so each collector ramps independently.
local pitch = PitchLadder.new({ Max = 1.7, MaxHits = 1 })

-- Plays the collect-cash effect from a CFrame, part or model, splitting `value` across projectiles.
return function(origin: CFrame | BasePart | Model, value: number?, targetPlayer: Player?)
	local target = targetPlayer or LocalPlayer

	local originCFrame: CFrame
	if typeof(origin) == "CFrame" then
		originCFrame = origin
	elseif origin:IsA("BasePart") then
		originCFrame = origin.CFrame
	else
		local rootPart = origin:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			originCFrame = rootPart.CFrame

			-- Cash also bursts off the whole rig, so the sale reads on the character, not just as projectiles
			EffectUtil.BurstOffBody(origin, rootPart, Particles.Cash)
		else
			-- NPC rigs get pooled away, so the character can already be gone by the time this reaches us
			originCFrame = origin:GetPivot()
		end
	end

	-- A raw CFrame has no instance to flash, so only pulse when handed a part or model
	if typeof(origin) ~= "CFrame" then
		EffectController:RunEffect("HighlightPulse", { origin, Color3.fromRGB(85, 255, 0), 1, 0.3 })
	end

	-- Ramp the pitch up on each consecutive collect, resetting once the player pauses for long enough.
	SoundController:PlaySound("CashCollect", originCFrame, { PlaybackSpeed = pitch:Next(target) })

	local projectileAmount = RandomUtil.GetRandomIntFromMinMax(4, 6)
	local projectile = Particles.CashProjectile
	local startPosition = originCFrame.Position

	-- Split across projectiles, skipping labels below 1. Screen UI, so only the player being paid sees them
	local popupValue = if target == LocalPlayer and value then math.floor(value / projectileAmount) else nil
	if popupValue and popupValue < 1 then
		popupValue = nil
	end

	-- Each lands with its own chime, popping a "+X" on arrival
	EffectUtil.LaunchCollectProjectiles(projectile, startPosition, target, projectileAmount, function(character: Model)
		SoundController:PlaySound(
			"CashCollected",
			character.PrimaryPart,
			{ PlaybackSpeed = Random.new():NextNumber(0.97, 1) },
			true
		)

		if popupValue then
			CurrencyController:SpawnCurrencyPopup(popupValue)
		end
	end)
end
