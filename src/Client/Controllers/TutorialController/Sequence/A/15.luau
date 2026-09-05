-- Step 15: put the BBQ out on the sell stall, which brings a customer. Ends holding the take off, which step 16 releases.
local HttpService = game:GetService("HttpService")

local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local SkewerStandController = require(script.Parent.Parent.Parent.Parent.SkewerStandController)

local NEAR_DISTANCE = 12
local BEAM_HIDE_DISTANCE = 12

return function(self)
	local base = self:GetBase()
	local stand = base.Stalls.SellStall.SkewerStand

	local highlight = self:CreateHighlight(stand)
	local beam = self:CreateBeam(stand, BEAM_HIDE_DISTANCE)

	self:AwaitGoal({
		{
			Description = `Go to your {self:Emphasize("Stall")}`,
			Check = function()
				return self:IsNear(stand, NEAR_DISTANCE)
			end,
		},
		{
			Description = `Equip your {self:Emphasize("BBQ")}`,
			Check = function()
				return EquippedItem.GetSkewer() ~= nil
			end,
		},
	}, {
		Description = `Place your {self:Emphasize("BBQ")} on the stand`,
		Wait = function()
			-- Counted against what was already there -- a customer mid-visit last session puts its skewer back
			local function placedCount(): number
				local encoded = stand:GetAttribute("PlacedSkewers")
				return if encoded then #HttpService:JSONDecode(encoded) else 0
			end

			local startingCount = placedCount()
			while placedCount() <= startingCount do
				stand:GetAttributeChangedSignal("PlacedSkewers"):Wait()
			end

			-- Taken here, not a frame later: the skewer's take prompt is built with the model, and the wait that follows has nothing else in reach
			SkewerStandController:SetTakeLocked(true)
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("PlaceOnSellStand")

	self.SequenceFinish:Fire()
end
