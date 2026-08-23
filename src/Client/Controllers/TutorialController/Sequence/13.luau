-- Step 13: Take the BBQ off the heat once it's actually cooked.
--
-- A cook is only ever ended by the player, and stopping inside the raw band gives them a BBQ worth
-- almost nothing -- which, on the one sale the tutorial is teaching, reads as the game being broken
-- rather than as their mistake. So rather than letting them stop early and telling them off for it,
-- both stop prompts are held shut (step 12 takes the lock) until the bar clears the raw band, and only
-- then does the beat ask for the knob. Past that point the timing is theirs: anywhere from the window
-- to the end of the bar is a real BBQ.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CookStates = require(ReplicatedStorage.Shared.Config.CookStates)

local NEAR_DISTANCE = 12

return function(self)
	local slot = self:GetStructure("Grillers")
	local knob = slot.Knob.Handle

	local highlight = self:CreateHighlight(knob)

	-- How far along the 0-1 bar the cook is, read the same way the griller itself derives it -- the warp
	-- included, since the tutorial's own cook is the one carrying a widened window, and reading it off
	-- the raw clock would hand the prompts back while the bar still showed raw.
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
			slot:GetAttribute("CookProgress")
		)

		return elapsed / cookTime
	end

	local function isCooking(): boolean
		return slot:GetAttribute("Cooking") == true
	end

	local function isCookedEnough(): boolean
		return isCooking() and cookProgress() >= CookStates.RAW_END
	end

	-- Hand the prompts back the moment the BBQ is worth taking off. Nothing else on the grill changes
	-- between lighting it and stopping it, so there's no state change to hang this on -- it has to be
	-- watched for. A cook that has ended without leaving the raw band releases it too: the knob starts
	-- cooks as well as stopping them, so holding it shut past the end of one would leave the player with
	-- a raw BBQ and no way to put it back on the heat.
	local lock = self.CookPromptLock
	self.CookPromptLock = nil

	local releaseConnection
	releaseConnection = RunService.Heartbeat:Connect(function()
		if isCooking() and not isCookedEnough() then
			return
		end

		releaseConnection:Disconnect()
		releaseConnection = nil

		if lock then
			lock.Destroy()
			lock = nil
		end
	end)

	self:AwaitGoal({
		{
			Description = `Stay by your {self:Emphasize("Griller")}`,
			-- The knob, not the griller: this beat is asking for the knob's own prompt, so what counts as
			-- near is wherever that prompt is in reach from.
			Check = function()
				return self:IsNear(knob, NEAR_DISTANCE)
			end,
		},
		{
			Description = function()
				return if isCooking()
					then "Let it cook..."
					else `Turn the {self:Emphasize("Knob")} to start cooking`
			end,
			Check = isCookedEnough,
		},
	}, {
		Description = `It's ready! Turn the {self:Emphasize("Knob")} off`,
		Wait = function()
			while slot:GetAttribute("Cooked") ~= true do
				slot:GetAttributeChangedSignal("Cooked"):Wait()
			end
		end,
	})

	if releaseConnection then
		releaseConnection:Disconnect()
	end
	if lock then
		lock.Destroy()
	end
	highlight.Destroy()

	self:LogStep("StopCook")

	self.SequenceFinish:Fire()
end
