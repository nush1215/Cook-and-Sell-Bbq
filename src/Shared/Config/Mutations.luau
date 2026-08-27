-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Assets
local Assets = ReplicatedStorage.Assets
local ParticlesFolder = Assets.Particles

--
export type Mutation = {
	Id: string, -- also the name of the particle folder under Assets.Particles
	Name: string, -- how it reads to the player
	Multiplier: number, -- what a BBQ carrying it sells for, as a multiple of its plain value
	Color: Color3, -- the [GOLDEN] tag's colour on the BBQ's inventory label
	DialogueVariant: string?, -- the NpcDialogue variant its lines come from; without one the customer
	-- falls back on reacting to the cook state (see StickModel.GetDialogueVariant)
	Particles: Folder, -- not authored below, back-filled from Assets.Particles
}

--
local Mutations = {}

--[[
    What a BBQ can come off a grill as, beyond how well it was cooked.

    A mutation is stamped onto the BBQ's record the moment a cook is stopped (GrillerManager), and it
    stays on it wherever it goes -- so Multiplier is the whole economy weight of the mutation system,
    the same way a sauce's is. Every ingredient on a mutated BBQ wears the mutation's particles, so
    it's obvious on sight on the grill, in hand, on the sell stand and in a customer's hand alike.

    What stamps one is the grill itself, not anything the player did with the skewer: a structure
    carrying a Mutation (see Config.Structures) hands it to whatever finishes cooking on it, so a BBQ is
    only ever mutated by the grill it was actually cooked on. Two grills do, and they're deliberately
    opposite ends of the same idea: the Golden Grill is Robux-only and stamps Golden every single time,
    so Golden is what a mutation costs; the Electric Grill is bought with money for its speed and throws
    a Shocked one only now and then (Structures.MutationChance), so Shocked is what a mutation happens
    to be worth. The guaranteed one is worth more than the occasional one, which is what keeps the
    Robux grill the better buy for anyone who wants mutations rather than throughput.
]]
Mutations.Data = {
	{
		Id = "Golden",
		Name = "Golden",
		Multiplier = 1.75,
		Color = Color3.fromRGB(255, 205, 65),
		DialogueVariant = "Golden",
	},
	{
		Id = "Shocked",
		Name = "Shocked",
		-- Under Golden's, and it has to stay there: this one comes off a grill bought with money at a
		-- chance, where Golden comes off one bought with Robux every time.
		Multiplier = 1.5,
		Color = Color3.fromRGB(120, 205, 255),
		-- No DialogueVariant, so a customer reacts to how well it was cooked instead (see
		-- StickModel.GetDialogueVariant). Golden's exists because NpcDialogue was written a set of
		-- Golden lines; giving Shocked its own is adding those lines and this field, and nothing else.
	},
}

-- Each entry pulls its particle folder out of Assets.Particles, matched on Id. A mutation whose folder
-- is missing gets dropped rather than left half-built, so it can't be stamped onto a BBQ and then error
-- when that BBQ is rendered.
for index = #Mutations.Data, 1, -1 do
	local mutation = Mutations.Data[index]
	local particles = ParticlesFolder:FindFirstChild(mutation.Id)

	if not particles then
		warn(`Mutation {mutation.Id} has no folder in Assets.Particles, it won't be applied`)
		table.remove(Mutations.Data, index)
		continue
	end

	mutation.Particles = particles
end

table.freeze(Mutations.Data)

function Mutations.GetMutationFromId(id: string): Mutation?
	for _, mutation in Mutations.Data do
		if mutation.Id == id then
			return mutation
		end
	end

	return nil
end

function Mutations.GetAllMutations(): { Mutation }
	return Mutations.Data
end

-- What a BBQ carrying this mutation sells for, as a multiple of its plain value. A plain BBQ -- or one
-- carrying an id the config no longer has -- is worth its plain value, so callers can multiply
-- unconditionally.
function Mutations.GetMultiplier(id: string?): number
	local mutation = id and Mutations.GetMutationFromId(id)
	return if mutation then mutation.Multiplier else 1
end

-- The mutation's tag on a BBQ's inventory label, sitting next to [PERFECT] -- e.g. "[GOLDEN]".
function Mutations.GetLabelTag(id: string): string
	return `[{string.upper(id)}]`
end

return Mutations
