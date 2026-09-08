-- Dormant while sauce dispensers are postponed: Data is empty, but the API stays live so StickModel's callers take their existing unsauced path.

-- Services
-- local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Assets
-- local Assets = ReplicatedStorage.Assets
-- local SauceParticlesFolder = Assets.SauceParticles
-- local SauceTemplatesFolder = Assets.SauceTemplates

--
export type Sauce = {
	Id: string, -- also the name of the ParticleEmitter under Assets.SauceParticles
	Name: string, -- how it reads in a notification
	Multiplier: number, -- what a skewer wearing it sells for, as a multiple of its ingredient value
	Color: Color3, -- the [KETCHUP] tag's colour on the skewer's inventory label
	Particles: ParticleEmitter, -- not authored below, back-filled from Assets.SauceParticles
	Template: BasePart?, -- authored as the template's name (a string) only when it differs from Id;
	-- back-filled to the SauceTemplates part the bottle's fill copies, or nil if it's missing
}

--
local Sauces = {}

-- Weakest to strongest. A skewer keeps its one sauce wherever it goes, so Multiplier is the whole weight
Sauces.Data = {}

--[==[
Sauces.Data = {
	{
		Id = "Ketchup",
		Name = "Ketchup",
		Multiplier = 1.25,
		Color = Color3.fromRGB(216, 52, 45),
	},
	{
		Id = "Mayo",
		Name = "Mayo",
		Multiplier = 1.4,
		Color = Color3.fromRGB(247, 240, 205),
		Template = "Mayonnaise",
	},
	{
		Id = "Mustard",
		Name = "Mustard",
		Multiplier = 1.6,
		Color = Color3.fromRGB(238, 195, 47),
	},
	{
		Id = "SoySauce",
		Name = "Soy Sauce",
		Multiplier = 1.8,
		Color = Color3.fromRGB(120, 78, 52),
	},
	{
		Id = "HotSauce",
		Name = "Hot Sauce",
		Multiplier = 2.25,
		Color = Color3.fromRGB(255, 106, 61),
	},
}

-- Each entry pulls its ParticleEmitter out of Assets.SauceParticles, matched on Id. A sauce whose
-- emitter is missing gets dropped rather than left half-built, so it can't be applied to a skewer and
-- then error when that skewer is rendered.
for index = #Sauces.Data, 1, -1 do
	local sauce = Sauces.Data[index]
	local particles = SauceParticlesFolder:FindFirstChild(sauce.Id)

	if not particles then
		warn(`Sauce {sauce.Id} has no ParticleEmitter in Assets.SauceParticles, it won't be applied`)
		table.remove(Sauces.Data, index)
		continue
	end

	sauce.Particles = particles

	-- The bottle's fill copies its look from this part; a flavor whose template asset is named
	-- differently to its Id authors that name in Template, otherwise it matches by Id. Missing one
	-- only costs the fill visual (unlike Particles), so warn and leave it nil rather than dropping.
	local template = SauceTemplatesFolder:FindFirstChild(sauce.Template or sauce.Id)
	if not template then
		warn(`Sauce {sauce.Id} has no template in Assets.SauceTemplates, its bottle won't show a fill`)
	end

	sauce.Template = template
end
]==]

table.freeze(Sauces.Data)

function Sauces.GetSauceFromId(id: string): Sauce?
	for _, sauce in Sauces.Data do
		if sauce.Id == id then
			return sauce
		end
	end

	return nil
end

function Sauces.GetAllSauces(): { Sauce }
	return Sauces.Data
end

-- A sauce's sale multiple. An unsauced or unknown one is 1, so callers multiply unconditionally.
function Sauces.GetMultiplier(id: string?): number
	local sauce = id and Sauces.GetSauceFromId(id)
	return if sauce then sauce.Multiplier else 1
end

-- The sauce's tag on a skewer's inventory label, sitting next to [COOKED] -- e.g. "[SOYSAUCE]".
function Sauces.GetLabelTag(id: string): string
	return `[{string.upper(id)}]`
end

return Sauces
