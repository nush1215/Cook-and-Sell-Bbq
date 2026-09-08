-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local BaseUnlocks = require(Shared.Config.BaseUnlocks)

-- Controllers
local EffectController = require(script.Parent.Parent.Controllers.EffectController)

-- Springs a base model to the server's SlotCFrame. Where the model starts is the whole difference: an unlock rises small from below, a structure drops in full-size from above.
local LayoutStand = Component.new({
	Tag = script.Name,
})

function LayoutStand:Start()
	local model: Model = self.Instance

	-- Retargeted, not snapped, so a mid-flight change bends the same spring. Only the pivot moves on a reflow
	local function retarget()
		Spr.target(model, BaseUnlocks.LAYOUT_DAMPING, BaseUnlocks.LAYOUT_FREQUENCY, {
			Pivot = model:GetAttribute("SlotCFrame"),
		})
	end

	-- Rise in and pop from the below-slot, undersized pose the server authored the fresh copy at.
	Spr.target(model, BaseUnlocks.LAYOUT_DAMPING, BaseUnlocks.LAYOUT_FREQUENCY, {
		Pivot = model:GetAttribute("SlotCFrame"),
		Scale = 1,
	})

	if model:GetAttribute("PulseOnSpawn") then
		EffectController:RunEffect("HighlightPulse", {
			model,
			BaseUnlocks.UNLOCK_PULSE_COLOR,
			BaseUnlocks.UNLOCK_PULSE_DURATION,
			BaseUnlocks.UNLOCK_PULSE_START_TRANSPARENCY,
		})
	end

	self._connection = model:GetAttributeChangedSignal("SlotCFrame"):Connect(retarget)
end

function LayoutStand:Stop()
	if self._connection then
		self._connection:Disconnect()
	end

	Spr.stop(self.Instance)
end

return LayoutStand
