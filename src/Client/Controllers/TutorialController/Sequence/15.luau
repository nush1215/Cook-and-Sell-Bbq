-- Step 15: Put the BBQ out on the sell stall, which is what brings a customer. Ends by holding the take
-- off, which step 16 releases once the sale has gone through -- see there.
local HttpService = game:GetService("HttpService")

local EquippedItem = require(script.Parent.Parent.Parent.Parent.Modules.EquippedItem)
local SkewerStandController = require(script.Parent.Parent.Parent.SkewerStandController)

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
			-- The stand's contents ride on one attribute as a JSON list. Counted against what was already
			-- there rather than against empty: a customer mid-visit when the player last left puts the
			-- skewer it was holding back on the stand, so the stand isn't always bare when this opens.
			local function placedCount(): number
				local encoded = stand:GetAttribute("PlacedSkewers")
				return if encoded then #HttpService:JSONDecode(encoded) else 0
			end

			local startingCount = placedCount()
			while placedCount() <= startingCount do
				stand:GetAttributeChangedSignal("PlacedSkewers"):Wait()
			end

			-- Taken here rather than after AwaitGoal returns, which is a frame later: the skewer's own take
			-- prompt is built with the model it rides on, so it's live on the frame the place lands.
			--
			-- What follows is a wait for a customer, and the only thing in reach during it is a prompt
			-- offering to take back the very skewer being waited on -- which would leave the beat waiting
			-- for a sale on an empty stand, with nothing to say so.
			SkewerStandController:SetTakeLocked(true)
		end,
	})

	beam.Destroy()
	highlight.Destroy()

	self:LogStep("PlaceOnSellStand")

	self.SequenceFinish:Fire()
end
