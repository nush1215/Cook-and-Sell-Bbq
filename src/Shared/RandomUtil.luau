--
local RandomUtil = {}

type RandomLike = number | Random

-- Accepts an existing Random, a numeric seed, or creates a fresh Random.
local function resolveRng(seedOrRng: RandomLike?): Random
	if typeof(seedOrRng) == "Random" then
		return seedOrRng
	end

	if typeof(seedOrRng) == "number" then
		return Random.new(seedOrRng)
	end

	return Random.new()
end

-- Picks a random value from { {value, weight}, ... }, returning the value and its full entry.
function RandomUtil.GetResultFromWeight(data: { { any | number } }, seedOrRng: RandomLike?)
	local totalWeight = 0
	for _, entry in data do
		totalWeight += entry[2]
	end

	if totalWeight <= 0 then
		return nil, nil
	end

	local rng = resolveRng(seedOrRng)
	local chosen = rng:NextNumber(0, totalWeight)

	local accumulatedWeight = 0
	for _, entry in data do
		accumulatedWeight += entry[2]
		if chosen <= accumulatedWeight then
			return entry[1], entry
		end
	end

	return data[#data][1], data[#data]
end

-- A random value from `data` avoiding `ignoreList`, retried up to 10 times; nil if every attempt failed.
function RandomUtil.GetRandomFromArray(data: { any }, ignoreList: any?, seedOrRng: RandomLike?): any?
	if #data == 0 then
		return nil
	end

	local rng = resolveRng(seedOrRng)
	local maxAttempts = 10

	for _ = 1, maxAttempts do
		local randomIndex = rng:NextInteger(1, #data)
		local currentRandom = data[randomIndex]

		local shouldIgnore = false
		if ignoreList then
			if typeof(ignoreList) == "table" then
				shouldIgnore = table.find(ignoreList, currentRandom) ~= nil
			else
				shouldIgnore = ignoreList == currentRandom
			end
		end

		if not shouldIgnore then
			return currentRandom
		end
	end

	return nil
end

-- A random point on the part, constrained to the XZ plane (Y = 0).
function RandomUtil.GetRandomXZFromPart(part: BasePart, seedOrRng: RandomLike?): Vector3
	local partSize = part.Size
	local rng = resolveRng(seedOrRng)
	local randomOffset =
		Vector3.new(rng:NextNumber(-partSize.X / 2, partSize.X / 2), 0, rng:NextNumber(-partSize.Z / 2, partSize.Z / 2))
	return (part.CFrame * CFrame.new(randomOffset)).Position
end

-- A random point anywhere within the part's bounds.
function RandomUtil.GetRandomXYZFromPart(part: BasePart, seedOrRng: RandomLike?): Vector3
	local partSize = part.Size
	local rng = resolveRng(seedOrRng)
	local randomOffset = Vector3.new(
		rng:NextNumber(-partSize.X / 2, partSize.X / 2),
		rng:NextNumber(-partSize.Y / 2, partSize.Y / 2),
		rng:NextNumber(-partSize.Z / 2, partSize.Z / 2)
	)
	return (part.CFrame * CFrame.new(randomOffset)).Position
end

-- A random number in [min, max).
function RandomUtil.GetRandomFromMinMax(min: number, max: number, seedOrRng: RandomLike?): number
	local rng = resolveRng(seedOrRng)
	return rng:NextNumber(min, max)
end

-- A random integer in [min, max].
function RandomUtil.GetRandomIntFromMinMax(min: number, max: number, seedOrRng: RandomLike?): number
	local rng = resolveRng(seedOrRng)
	return rng:NextInteger(min, max)
end

-- True with the given percentage chance (0-100).
function RandomUtil.RollChance(chance: number, seedOrRng: RandomLike?): boolean
	local rng = resolveRng(seedOrRng)
	return rng:NextNumber(0, 100) < chance
end

return RandomUtil
