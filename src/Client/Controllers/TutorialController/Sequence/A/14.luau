-- Step 14: wait the cook out, then take the BBQ off. The take is held shut until the bar clears the raw band, since a raw pull on the one sale being taught reads as the game being broken.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CookStates = require(ReplicatedStorage.Shared.Config.CookStates)

-- Modules
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)

-- Controllers
local GrillerController = require(script.Parent.Parent.Parent.Parent.GrillerController)

-- Matches the grill prompts' MaxActivationDistance, so the beat clears where the prompt comes in reach
local NEAR_DISTANCE = 15

return function(self)
	local slot = self:GetStructure("Grillers")

	-- The grill's attachment, the take prompt riding on the skewer seated inches from it
	local promptAttachment = slot:FindFirstChild("GrillAttachment", true)

	local highlight = self:CreateHighlight(slot)

	-- Read the way the griller derives it, both warps included -- the raw clock would free the take while the bar still showed raw
	local function cookProgress(): number
		local startedAt = slot:GetAttribute("CookStartedAt")
		local cookTime = slot:GetAttribute("CookTime")
		if not startedAt or not cookTime or cookTime <= 0 then
			return 0
		end

		local elapsed = CookStates.GetBarElapsed(
			workspace:GetServerTimeNow() - startedAt,
			cookTime,
			slot:GetAttribute("CookWindowStretch"),
			slot:GetAttribute("CookProgress"),
			slot:GetAttribute("CookInstability"),
			slot:GetAttribute("CookInstabilityPhase")
		)

		return elapsed / cookTime
	end

	local function isCooking(): boolean
		return slot:GetAttribute("Cooking") == true
	end

	local function isCookedEnough(): boolean
		return isCooking() and cookProgress() >= CookStates.RAW_END
	end

	-- Watched for, there being no state change between placing and taking. A cook ending raw releases it too
	local releaseConnection
	releaseConnection = RunService.Heartbeat:Connect(function()
		if isCooking() and not isCookedEnough() then
			return
		end

		releaseConnection:Disconnect()
		releaseConnection = nil

		GrillerController:SetTakeLocked(false)
		GrillerController:SetStopLocked(false)
	end)

	self:AwaitGoal({
		{
			Description = `Stay by your {self:Emphasize("Griller")}`,
			Check = function()
				return self:IsNear(promptAttachment, NEAR_DISTANCE)
			end,
		},
		-- Above the cook guard: asked while bar remains it costs nothing, asked at the window it costs the window
		{
			Description = "Put away what you're holding",
			Check = function()
				return EquippedItem.GetTool() == nil
			end,
		},
		{
			Description = "Let it cook...",
			Check = isCookedEnough,
		},
	}, {
		-- "Take", matching the prompt's ActionText, so the banner and the button say the same word
		Description = `It's ready! Take your {self:Emphasize("BBQ")}`,
		Wait = function()
			while slot:GetAttribute("PlacedStickId") ~= nil do
				slot:GetAttributeChangedSignal("PlacedStickId"):Wait()
			end
		end,
	})

	if releaseConnection then
		releaseConnection:Disconnect()
	end
	-- The path where the take lands before the heartbeat got there; a lock already released no-ops
	GrillerController:SetTakeLocked(false)
	GrillerController:SetStopLocked(false)
	highlight.Destroy()

	self:LogStep("TakeFromGrill")

	self.SequenceFinish:Fire()
end
