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

-- What a BBQ can come off a grill as, beyond how well it cooked. Stamped by the grill rather than the player, so Golden is guaranteed on the Robux grill and Shocked only occasional on the Electric one -- which is what keeps the Robux grill the better buy for mutations.
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
		-- Under Golden's, and it must stay there -- this comes off a money grill at a chance, Golden off Robux every time
		Multiplier = 1.5,
		Color = Color3.fromRGB(120, 205, 255),
		-- No DialogueVariant, so a customer reacts to the cook state; giving Shocked one is lines plus this field
	},
}

-- Resolves each mutation's particle folder, dropping any that's missing so it can't error on render.
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

-- A mutation's sale multiple. A plain or unknown one is 1, so callers multiply unconditionally.
function Mutations.GetMultiplier(id: string?): number
	local mutation = id and Mutations.GetMutationFromId(id)
	return if mutation then mutation.Multiplier else 1
end

-- The mutation's tag on a BBQ's inventory label, sitting next to [PERFECT] -- e.g. "[GOLDEN]".
function Mutations.GetLabelTag(id: string): string
	return `[{string.upper(id)}]`
end

return Mutations
