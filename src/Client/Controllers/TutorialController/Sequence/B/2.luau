-- Step 2: The same beat again for the stick stand, which is the other half of a working stall -- the
-- stand is where a BBQ gets built and the griller is where it gets cooked, and every beat from step 4
-- on wants both of them standing.
--
-- Second rather than folded into step 1 so the player puts one thing down, sees it land, and only then
-- is asked for the next. Two tools out at once on a first build is a choice, and this beat isn't ready
-- to be one.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Structures = require(ReplicatedStorage.Shared.Config.Structures)

-- Modules
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)

local CATEGORY = "StickStands"
local GUIDE_NAME = "StickStand"

local BEAM_HIDE_DISTANCE = 12

return function(self)
	local function isEquipped(): boolean
		return Structures.IsCategory(EquippedItem.GetStructureId() or "", CATEGORY)
	end

	local spotlight = self:SpotlightHotbarSlot(function()
		return if isEquipped() then nil else self:GetStructureTool(CATEGORY)
	end)

	-- Hotbar only until the tool is out, and the world left alone until then -- see step 1.
	self:AwaitGoal(nil, {
		-- Named rather than called "the other one": placing the last of a kind takes its tool out of the
		-- backpack, so by now the griller's slot is gone and there's nothing to say "other" to.
		Description = `Equip your {self:Emphasize("Stick Stand")}`,
		Wait = function()
			while not isEquipped() do
				task.wait()
			end
		end,
	})

	self:LogStep("EquipStand")

	local guide = self:ShowGuide(GUIDE_NAME)

	local function guideModel(): Instance?
		return guide.Model
	end

	local highlight = self:CreateHighlight(guideModel)
	local beam = self:CreateBeam(guideModel, BEAM_HIDE_DISTANCE)

	self:AwaitGoal({
		{
			Description = `Equip your {self:Emphasize("Stick Stand")}`,
			Check = isEquipped,
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

	self:LogStep("PlaceStand")

	self.SequenceFinish:Fire()
end
