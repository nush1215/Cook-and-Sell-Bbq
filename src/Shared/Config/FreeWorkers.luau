-- The three workers given away the first time a player opens their repaired hut: one of each role, all
-- the same rating, so the only thing rolled is who they are. Rolled off the player's own UserId rather
-- than stored, so the same three faces come back every session until one of them is taken.

-- Shared
local RandomUtil = require(script.Parent.Parent.RandomUtil)
local Employees = require(script.Parent.Employees)

--
export type Candidate = {
	Role: string, -- one of Employees.ROLES, fixed by the slot it sits in
	Stars: number, -- 0-5 as the player reads it; the record stores it back down as 0-1 Skill
	Body: string, -- one of Employees.BODIES
	Name: string,
	-- What it's wearing, keyed by the HumanoidDescription field each id is written to -- see Employees.Cosmetics
	Cosmetics: { Hair: string?, Hat: string?, Head: string?, Skin: string? },
}

--
local FreeWorkers = {}

-- The PlayerGui panel the three are offered on, shown in place of the hut's own on its first open
FreeWorkers.UI_NAME = "FreeWorkersUI"

-- The ScreenGui in the owner's PlayerGui their baked portraits land in, each named by slot. PlayerGui, so only the owner is sent them
FreeWorkers.PORTRAIT_FOLDER = "FreeWorkerPortraits"

-- What each card offers, by the slot it's authored as. The length is how many cards there are
FreeWorkers.SLOT_ROLES = {
	Employees.ROLES.BBQ_MAKER,
	Employees.ROLES.COOKER,
	Employees.ROLES.SELLER,
}

table.freeze(FreeWorkers.SLOT_ROLES)

-- What every one of them is worth. Mid-ladder on purpose: enough to be worth equipping and watching work,
-- well short of what the board's own top end sells for
FreeWorkers.STARS = 2.5

-- The three on offer to `userId`. Walked in the same fixed order the hiring board's roll takes, so the client and the server each derive the same three without a word passing between them.
function FreeWorkers.RollCandidates(userId: number): { Candidate }
	local rng = Random.new(userId)
	local candidates = {}

	-- No two of the three share a name, though each draws from the pool that suits its own body
	local used = {}

	for _, role in FreeWorkers.SLOT_ROLES do
		local body = Employees.BODIES[rng:NextInteger(1, #Employees.BODIES)]

		-- Filtered rather than taken from one shared list, since each body has its own pool. Walked in the
		-- config's order, so the same seed lands on the same name wherever it's rolled
		local available = {}
		for _, candidate in Employees.GetNames(body) do
			if not used[candidate] then
				table.insert(available, candidate)
			end
		end

		local name = available[rng:NextInteger(1, #available)]
		used[name] = true

		-- One or the other, never both: a bonnet sitting on top of a fringe reads as a bug
		local hair, hat
		if RandomUtil.RollChance(Employees.HAT_CHANCE, rng) then
			hat = Employees.Cosmetics.Hats[rng:NextInteger(1, #Employees.Cosmetics.Hats)]
		else
			local styles = Employees.Cosmetics.Hair[body]
			hair = styles[rng:NextInteger(1, #styles)]
		end

		local heads = Employees.Cosmetics.Heads
		local tones = Employees.SKIN_TONES

		table.insert(candidates, {
			Role = role,
			Stars = FreeWorkers.STARS,
			Body = body,
			Name = name,
			Cosmetics = {
				Hair = hair,
				Hat = hat,
				Head = heads[rng:NextInteger(1, #heads)],
				Skin = tones[rng:NextInteger(1, #tones)],
			},
		})
	end

	return candidates
end

return FreeWorkers
