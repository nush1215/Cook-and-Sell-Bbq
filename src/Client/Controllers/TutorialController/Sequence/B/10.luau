-- Step 10: Wait the cook out, then take the BBQ off the griller.
--
-- Taking it off is what ends a cook, so this one beat is both the timing call and the collection. A cook
-- is only ever ended by the player, and pulling inside the raw band gives them a BBQ worth almost nothing
-- -- which, on the one sale the tutorial is teaching, reads as the game being broken rather than as their
-- mistake. So rather than letting them pull early and telling them off for it, the take is held shut
-- (step 9 takes GrillerController's locks) until the bar clears the raw band, and only then does the beat
-- ask for it. Past that point the timing is theirs: anywhere from the window to the end of the bar is a
-- real BBQ.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CookStates = require(ReplicatedStorage.Shared.Config.CookStates)

-- Modules
local EquippedItem = require(script.Parent.Parent.Parent.Parent.Parent.Modules.EquippedItem)

-- Controllers
local GrillerController = require(script.Parent.Parent.Parent.Parent.GrillerController)

-- Matches the grill prompts' MaxActivationDistance, so the beat clears where the prompt comes in reach.
local NEAR_DISTANCE = 15
local BEAM_HIDE_DISTANCE = 15

return function(self)
	local slot = self:GetStructure("Grillers")

	-- The grill's own attachment rather than the slot: the take prompt rides on the skewer, which is
	-- seated inches from it, and the model is wide enough that its centre reads as near from places
	-- nothing on it is in reach. Found the whole way down, since it sits on Grill.Main.Base rather than
	-- on the griller itself.
	local promptAttachment = slot:FindFirstChild("GrillAttachment", true)

	local highlight = self:CreateHighlight(slot)

	-- The skewer rather than the griller: it's what the banner is naming, and the take prompt rides on it.
	-- The server rebuilds it on every record write, so it's resolved each frame, falling back to the
	-- prompt's own attachment inches away while it's between builds.
	--
	-- This is also the one beat the player is asked to wait through, so it's the one they're most likely
	-- to wander off in the middle of -- and the only guard that can put the banner back to "stay by your
	-- griller" is the one they can walk out of.
	local beam = self:CreateBeam(function()
		return slot:FindFirstChild("Skewer") or promptAttachment
	end, BEAM_HIDE_DISTANCE)

	-- How far along the 0-1 bar the cook is, read the same way the griller itself derives it -- both warps
	-- included, since the tutorial's own cook is the one carrying a widened window, and the grill it's
	-- being run on is whichever griller the player owns, which can be an unstable one. Reading it off the
	-- raw clock would hand the take back while the bar still showed raw.
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

	-- Hand the take back the moment the BBQ is worth pulling off. Nothing else on the grill changes
	-- between setting it down and taking it off, so there's no state change to hang this on -- it has to
	-- be watched for. A cook that has ended without leaving the raw band releases it too, or the locks
	-- would be left standing over whatever cooks next.
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
		-- Above the cook guard on purpose: asked for while there's still bar left to run, it costs them
		-- nothing, where the same ask at the moment the window opens would cost them the window.
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
		-- "Take", matching the prompt's own ActionText, so the banner and the thing they press say the
		-- same word.
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
	-- The path where the take lands before the heartbeat got there; a lock already released no-ops.
	GrillerController:SetTakeLocked(false)
	GrillerController:SetStopLocked(false)
	beam.Destroy()
	highlight.Destroy()

	self:LogStep("TakeFromGrill")

	self.SequenceFinish:Fire()
end
