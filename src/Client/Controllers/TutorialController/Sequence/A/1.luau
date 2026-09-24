-- Step 1: get a griller standing on the base, teaching that a structure is a tool you take out and put down. The ghost is a suggestion -- the beat finishes on one going down anywhere legal.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Structures = require(ReplicatedStorage.Shared.Config.Structures)

-- Modules
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)

-- Controllers
local BuildController = require(script.Parent.Parent.Parent.Parent.BuildController)
local InventoryController = require(script.Parent.Parent.Parent.Parent.InventoryController)

-- The category, not the id, so a later model of griller still counts (see Config.Structures)
local CATEGORY = "Grillers"
local GUIDE_NAME = "Grill"

local BEAM_HIDE_DISTANCE = 12

return function(self)
	-- Taken before the hotbar is even lit: putting the other structure down here leaves the beat that asks for it with no tool
	BuildController:SetPlaceCategory(CATEGORY, "Place your Griller first")

	local function isEquipped(): boolean
		return Structures.IsCategory(EquippedItem.GetStructureId() or "", CATEGORY)
	end

	-- One cue for the slot and the Place button, so the two never fight over the shared spotlight
	local spotlight = self:SpotlightFrame(function()
		if not isEquipped() then
			local tool = self:GetStructureTool(CATEGORY)
			return tool and InventoryController:GetSlotFrame(tool)
		end

		-- Dark while they aim, back once it's locked on the guide: a phone builds off the button alone
		return if BuildController:CanPlaceOnSnap() then BuildController:GetMobilePlaceButton() else nil
	end)

	-- Nothing in the world yet: they have nothing to put down, so this half is only the hotbar
	self:AwaitGoal(nil, {
		Description = `Equip your {self:Emphasize("Griller")}`,
		Wait = function()
			while not isEquipped() do
				self:EquipForGamepad(self:GetStructureTool(CATEGORY))
				task.wait()
			end
		end,
	})

	-- Logged here, so the funnel separates never taking it out from never finding somewhere to put it
	self:LogStep("EquipGrill")

	-- Now they're holding one, say where it could go -- the goal is anywhere legal, not this spot
	local guide = self:ShowGuide(GUIDE_NAME)

	-- A thumb- or stick-aimed ghost locks on once it's near, still free to go down anywhere else
	BuildController:SetSnapTarget(guide.Model and guide.Model.Hitbox)

	-- Resolved through the guide, so an unauthored one draws nothing rather than erroring the step
	local function guideModel(): Instance?
		return guide.Model
	end

	local highlight = self:CreateHighlight(guideModel)
	local beam = self:CreateBeam(guideModel, BEAM_HIDE_DISTANCE)

	-- A guard, not a passed step, so putting the tool away asks for it again. The cues stay up through that
	self:AwaitGoal({
		{
			Description = `Equip your {self:Emphasize("Griller")}`,
			Check = function()
				self:EquipForGamepad(self:GetStructureTool(CATEGORY))
				return isEquipped()
			end,
		},
	}, {
		Description = `Place your {self:Emphasize("Griller")} on your plot`,
		-- The tag is set last, so waiting on a findable griller is waiting on a finished one
		Wait = function()
			self:GetStructure(CATEGORY)
		end,
	})

	spotlight.Destroy()
	beam.Destroy()
	highlight.Destroy()
	guide.Destroy()
	BuildController:SetSnapTarget(nil)

	self:LogStep("PlaceGrill")

	self.SequenceFinish:Fire()
end
