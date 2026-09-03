-- Step 9: Get the BBQ onto the griller, which is also what starts it cooking. Opens by holding the take
-- off, which step 10 releases once the bar clears the raw band -- see there.
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local GrillerController = require(script.Parent.Parent.Parent.Parent.GrillerController)

local NEAR_DISTANCE = 12
local BEAM_HIDE_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("Grillers")

	-- The place prompt's attachment rather than the slot: it marks where the player has to stand to place,
	-- and the model is wide enough that its centre reads as near from places nothing on it is in reach.
	-- Each beat's "near" is wherever the thing it's asking for can be reached from. Found the whole way
	-- down, since it sits on Grill.Main.Base rather than on the griller itself.
	local promptAttachment = slot:FindFirstChild("GrillAttachment", true)

	-- Both held from up here, before the BBQ is anywhere near the grate, because setting it down is what
	-- starts the cook -- there is no gap between the two to take a lock in. Grill's own attribute handlers
	-- refresh ahead of any waiter on the place, so a lock taken on that signal is already a flash too late.
	--
	-- Which one is doing the work swaps the instant the cook stamps: the take prompt reads IsStopLocked
	-- while cooking and IsTakeLocked otherwise (see Grill:RefreshInteraction), and PlacedStickId lands a
	-- frame before Cooking does. Step 10 hands both back.
	--
	-- Nothing about the next beat wants the BBQ coming back off. The griller is cooking it, the banner is
	-- asking them to wait, and a prompt sat on top of it offering to undo the step they just finished is
	-- the only other thing in reach -- and taking it now would settle a raw BBQ worth almost nothing.
	GrillerController:SetTakeLocked(true)
	GrillerController:SetStopLocked(true)

	local highlight = self:CreateHighlight(slot)
	local beam = self:CreateBeam(promptAttachment, BEAM_HIDE_DISTANCE)

	self:AwaitGoal({
		{
			Description = `Go to your {self:Emphasize("Griller")}`,
			Check = function()
				return self:IsNear(promptAttachment, NEAR_DISTANCE)
			end,
		},
		{
			Description = `Equip your {self:Emphasize("BBQ")}`,
			Check = function()
				return EquippedItem.GetSkewer() ~= nil
			end,
		},
	}, {
		-- "Place", matching the prompt's own ActionText, so the banner and the thing they press say the
		-- same word.
		Description = `Place your {self:Emphasize("BBQ")} on the grill`,
		Wait = function()
			while slot:GetAttribute("PlacedStickId") == nil do
				slot:GetAttributeChangedSignal("PlacedStickId"):Wait()
			end
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("PlaceOnGrill")

	self.SequenceFinish:Fire()
end
