-- Services
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

--
local ClientRandom = {}

local FNV_OFFSET = 2166136261
local FNV_PRIME = 16777619
local UINT_32_MAX = 0xFFFFFFFF
local MAX_RANDOM_SEED = 2147483647

local localPlayer = Players.LocalPlayer
local sessionSalt = HttpService:GenerateGUID(false)
local counter = 0

-- Folds the entropy string into a Random.new-safe seed via FNV-1a.
local function buildSeed(context: string?): number
	counter += 1

	local mouse = UserInputService:GetMouseLocation()
	local camera = Workspace.CurrentCamera
	local viewpoint = if camera then camera.CFrame.Position else Vector3.zero

	local entropy =
		`{sessionSalt}:{localPlayer.UserId}:{counter}:{tick()}:{os.clock()}:{mouse.X},{mouse.Y}:{viewpoint}:{context or ""}`

	local hash = FNV_OFFSET
	for index = 1, #entropy do
		hash = bit32.bxor(hash, string.byte(entropy, index))
		hash = bit32.band(hash * FNV_PRIME, UINT_32_MAX)
	end

	local seed = hash % MAX_RANDOM_SEED
	return if seed > 0 then seed else MAX_RANDOM_SEED
end

-- Creates a Random seeded from client-only entropy (session salt + user + input/camera state + context).
function ClientRandom.MakeRNG(context: string?): Random
	return Random.new(buildSeed(context))
end

return ClientRandom
