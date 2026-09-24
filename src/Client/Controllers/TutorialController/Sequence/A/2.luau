-- Step 2: the same beat for the stick stand, the other half of a working stall. Separate from step 1 so they put one thing down and see it land before being asked for the next.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Structures = require(ReplicatedStorage.Shared.Config.Structures)

-- Modules
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)

-- Controllers
local BuildController = require(script.Parent.Parent.Parent.Parent.BuildController)
local InventoryController = require(script.Parent.Parent.Parent.Parent.InventoryController)

local CATEGORY = "StickStands"
local GUIDE_NAME = "StickStand"

local BEAM_HIDE_DISTANCE = 12

return function(self)
	-- Narrowed off step 1's griller. Held to the finish, so nothing granted mid-run can go down out of turn
	BuildController:SetPlaceCategory(CATEGORY, "Place your Stick Stand first")

	local function isEquipped(): boolean
		return Structures.IsCategory(EquippedItem.GetStructureId() or "", CATEGORY)
	end

	-- Slot, then the Place button once it's locked on the guide -- see step 1
	local spotlight = self:SpotlightFrame(function()
		if not isEquipped() then
			local tool = self:GetStructureTool(CATEGORY)
			return tool and InventoryController:GetSlotFrame(tool)
		end

		return if BuildController:CanPlaceOnSnap() then BuildController:GetMobilePlaceButton() else nil
	end)

	-- Hotbar only until the tool is out, and the world left alone until then -- see step 1
	self:AwaitGoal(nil, {
		-- Named rather than "the other one" -- placing the last griller took its slot, so there's nothing to say other to
		Description = `Equip your {self:Emphasize("Stick Stand")}`,
		Wait = function()
			while not isEquipped() do
				self:EquipForGamepad(self:GetStructureTool(CATEGORY))
				task.wait()
			end
		end,
	})

	self:LogStep("EquipStand")

	local guide = self:ShowGuide(GUIDE_NAME)
	BuildController:SetSnapTarget(guide.Model and guide.Model.Hitbox)

	local function guideModel(): Instance?
		return guide.Model
	end

	local highlight = self:CreateHighlight(guideModel)
	local beam = self:CreateBeam(guideModel, BEAM_HIDE_DISTANCE)

	self:AwaitGoal({
		{
			Description = `Equip your {self:Emphasize("Stick Stand")}`,
			Check = function()
				self:EquipForGamepad(self:GetStructureTool(CATEGORY))
				return isEquipped()
			end,
		},
	}, {
		Description = `Place your {self:Emphasize("Stick Stand")} on your plot`,
		Wait = function()
			self:GetStructure(CATEGORY)
		end,
	})

	spotlight.Destroy()
	beam.Destroy()
	highlight.Destroy()
	guide.Destroy()
	BuildController:SetSnapTarget(nil)

	self:LogStep("PlaceStand")

	self.SequenceFinish:Fire()
end
