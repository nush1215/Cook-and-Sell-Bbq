-- Step 1: Get a griller standing on the base. The player already owns one -- it's in the backpack from
-- the data template rather than bought -- so the whole beat is teaching them that a structure is a tool
-- you take out and put down, which is the one thing nothing else in the sequence explains.
--
-- The ghost on the plot is a suggestion and nothing more. It's there because a first-time player looking
-- at an empty base has no idea what a sensible stall looks like, but the beat finishes on a griller
-- going down anywhere legal -- so laying the stall out their own way is a thing they're allowed to
-- discover on their very first build rather than something they get told off for.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Structures = require(ReplicatedStorage.Shared.Config.Structures)

-- Modules
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)

-- The kind of structure this beat is after, rather than the id of the one they start with: a player
-- whose first griller is some later model of one is still building a griller (see Config.Structures on
-- why the category is what everything binds to).
local CATEGORY = "Grillers"
local GUIDE_NAME = "Grill"

local BEAM_HIDE_DISTANCE = 12

return function(self)
	local function isEquipped(): boolean
		return Structures.IsCategory(EquippedItem.GetStructureId() or "", CATEGORY)
	end

	-- Lit only while the tool is still in the bag. Once it's out the player is aiming a ghost at the
	-- ground, and a dimmed screen is the last thing that beat wants.
	local spotlight = self:SpotlightHotbarSlot(function()
		return if isEquipped() then nil else self:GetStructureTool(CATEGORY)
	end)

	-- Nothing is drawn out in the world yet. A ghost standing on the plot, lit up and with a beam
	-- running to it, is telling the player to go and put something down -- and they have nothing in
	-- their hands to put down with. So this half of the beat is only the hotbar, which is the one thing
	-- they can act on, and the world stays as they found it until they've taken the tool out.
	self:AwaitGoal(nil, {
		Description = `Equip your {self:Emphasize("Griller")}`,
		Wait = function()
			while not isEquipped() do
				task.wait()
			end
		end,
	})

	-- Logged here rather than at the end, so the funnel separates "never took it out of the bag" from
	-- "took it out and never found anywhere to put it down".
	self:LogStep("EquipGrill")

	-- Now that they're holding one, say where it could go. The guide is a suggestion: the goal below is
	-- a griller going down anywhere legal, not one going down on this spot.
	local guide = self:ShowGuide(GUIDE_NAME)

	-- Both cues resolve through the guide rather than taking it once, so a guide that was never authored
	-- draws nothing instead of erroring the step -- the same way every other missing tutorial asset warns
	-- and carries on.
	local function guideModel(): Instance?
		return guide.Model
	end

	local highlight = self:CreateHighlight(guideModel)
	local beam = self:CreateBeam(guideModel, BEAM_HIDE_DISTANCE)

	-- The equip is a guard again rather than something already passed: put the tool away here and the
	-- banner goes back to asking for it, the way every other beat walks backwards when its groundwork is
	-- undone. The cues stay up through that -- they've been seen now, and taking them away and putting
	-- them back with every equip would read as a fault rather than as an answer.
	self:AwaitGoal({
		{
			Description = `Equip your {self:Emphasize("Griller")}`,
			Check = isEquipped,
		},
	}, {
		Description = `Place your {self:Emphasize("Griller")} on your plot`,
		-- The category tag is set last, after the model is parented and its attributes are written, so
		-- waiting on a griller becoming findable is waiting on one that has finished being built.
		-- GetStructure is that wait.
		Wait = function()
			self:GetStructure(CATEGORY)
		end,
	})

	spotlight.Destroy()
	beam.Destroy()
	highlight.Destroy()
	guide.Destroy()

	self:LogStep("PlaceGrill")

	self.SequenceFinish:Fire()
end
