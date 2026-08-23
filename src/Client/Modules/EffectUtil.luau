--
local EffectUtil = {}

export type Effect = {
	Clone: Instance,
	Children: { Instance },
	Particles: { ParticleEmitter },
	Cleanup: () -> (),
	EmitParticles: () -> (),
}

-- Clones an effect folder, parents its children to the target, and gathers the particle emitters inside.
-- @param effectFolder: The template folder/instance to clone
-- @param parent: Where the cloned children get parented
-- @returns A table with the emptied clone, the parented children, every particle emitter inside it, and a cleanup function
function EffectUtil.ParentEffectFolder(effectFolder: Instance, parent: Instance): Effect
	local clone = effectFolder:Clone()
	local children = clone:GetChildren()
	local particles = {}

	for _, v in clone:GetDescendants() do
		if v:IsA("ParticleEmitter") then
			table.insert(particles, v)
		end
	end

	for _, v in children do
		v.Parent = parent
	end

	return {
		Clone = clone,
		Children = children,
		Particles = particles,
		Cleanup = function()
			for _, v in children do
				v:Destroy()
			end
			clone:Destroy()
		end,
		EmitParticles = function()
			for _, particle in particles do
				particle:Emit(particle:GetAttribute("EmitCount"))
			end
		end,
	}
end

return EffectUtil
