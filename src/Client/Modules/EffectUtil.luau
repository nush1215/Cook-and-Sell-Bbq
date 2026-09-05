--
local EffectUtil = {}

export type Effect = {
	Clone: Instance,
	Children: { Instance },
	Particles: { ParticleEmitter },
	Cleanup: () -> (),
	EmitParticles: () -> (),
}

-- Clones an effect folder onto `parent`, returning the clone, its children, its emitters and a cleanup.
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
