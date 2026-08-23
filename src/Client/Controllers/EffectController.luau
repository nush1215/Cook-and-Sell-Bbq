-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

--
local Effects = script.Parent.Parent.Effects

--
local RunEffect = Network.Event("RunEffect")

--
local EffectController = {
	_effects = {},
}

function EffectController:RunEffect(effect: string, data: { any })
	local effectModule = self._effects[effect]
	if not effectModule then
		warn("Effect not found:", effect)
		return
	end

	if not (typeof(data) == "table") then
		data = { data }
	end

	return effectModule(table.unpack(data))
end

function EffectController:OnInit()
	local EffectsFolder = Instance.new("Folder")
	EffectsFolder.Name = "Effects"
	EffectsFolder.Parent = workspace

	for _, v in Effects:GetChildren() do
		local effect = require(v)
		self._effects[v.Name] = effect
	end
end

function EffectController:OnStart()
	RunEffect:OnClientEvent(function(data: { any })
		self:RunEffect(table.unpack(data))
	end)
end

return EffectController
