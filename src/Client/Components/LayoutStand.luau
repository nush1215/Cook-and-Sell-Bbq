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

--[[
	LayoutStand — springs a base's unlock model to the spot the server picked for it.

	The server decides where the model goes and writes its target to a SlotCFrame attribute; this
	just animates it there. A fresh Layout copy is authored below its slot and undersized, so it
	rises up and pops to full scale on start; an upgrade that reshuffles the grid retargets the
	attribute and the copy slides across (scale is left alone, so it doesn't re-pop).

	A freshly-placed structure rides the same spring the other way up: the server authors it *above*
	its slot and at full size, so it drops onto the spot rather than growing out of it -- buying an
	upgrade and building something read differently on purpose. Nothing here tells the two apart;
	where the model starts is the whole difference, and being already full size makes the scale
	target below a no-op for them.

	A model that came up on a purchase or a placement also carries PulseOnSpawn, and flashes gold as
	it moves. The server only sets it on the render that follows an actual change, so a base building
	itself out on join stays quiet.
]]
local LayoutStand = Component.new({
	Tag = script.Name,
})

function LayoutStand:Start()
	local model: Model = self.Instance

	-- Retarget rather than snap, so an attribute change mid-flight bends the same spring instead of
	-- restarting it. Reflows only move the pivot; the scale pop is a one-time thing on start.
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
