-- Services
local HttpService = game:GetService("HttpService")

--
local ServerRandom = {}

local FNV_OFFSET = 2166136261
local FNV_PRIME = 16777619
local UINT_32_MAX = 0xFFFFFFFF
local MAX_RANDOM_SEED = 2147483647

local serverSalt = HttpService:GenerateGUID(false)
local counter = 0

-- Folds the entropy string into a Random.new-safe seed via FNV-1a.
local function buildSeed(context: string?): number
	counter += 1
	local entropy =
		`{serverSalt}:{counter}:{os.time()}:{os.clock()}:{HttpService:GenerateGUID(false)}:{context or ""}`

	local hash = FNV_OFFSET
	for index = 1, #entropy do
		hash = bit32.bxor(hash, string.byte(entropy, index))
		hash = bit32.band(hash * FNV_PRIME, UINT_32_MAX)
	end

	local seed = hash % MAX_RANDOM_SEED
	return if seed > 0 then seed else MAX_RANDOM_SEED
end

-- Creates a Random seeded from server-only entropy (salt + counter + clock + GUID + context).
function ServerRandom.MakeRNG(context: string?): Random
	return Random.new(buildSeed(context))
end

return ServerRandom
