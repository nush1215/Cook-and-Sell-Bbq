-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)

-- Constants
local NOW_TEXT = "Now!"
local ENDED_TEXT = "Ended"

--
local EventCountdown = Component.new({
	Tag = script.Name,
})

-- Converts an event's StartTime/EndTime dictionary (UTC parts) to unix seconds.
local function toUnixSeconds(time): number
	local dateTime = DateTime.fromUniversalTime(time.Year, time.Month, time.Day, time.Hour, time.Minute, time.Second, time.Millisecond)
	return dateTime.UnixTimestampMillis / 1000
end

function EventCountdown:Start()
	self._cleaner = Trove.new()

	--
	local label: TextLabel = self.Instance
	local eventId = label:GetAttribute("Id")
	--
	if not eventId then
		return
	end

	-- The fetch yields, so it runs on a trove thread that a Stop mid-request cancels
	self._cleaner:Add(task.spawn(function()
		-- Client-only API; a failed or nil fetch (unpublished event, Studio) leaves the authored text alone
		local ok, event = pcall(function()
			return SocialService:GetExperienceEventAsync(eventId)
		end)
		if not ok or not event then
			return
		end

		local startsAt = toUnixSeconds(event.StartTime)
		local endsAt = toUnixSeconds(event.EndTime)

		-- Counted on the synced clock so a skewed device clock can't shift it
		while true do
			local now = workspace:GetServerTimeNow()
			-- Under a second would floor to "0s", so the last second already reads as started
			if startsAt - now >= 1 then
				label.Text = GuiUtil.ConvertSecondsToDHMS(startsAt - now)
			elseif now < endsAt then
				label.Text = NOW_TEXT
			else
				label.Text = ENDED_TEXT
				break
			end

			task.wait(1)
		end
	end))
end

function EventCountdown:Stop()
	self._cleaner:Destroy()
end

return EventCountdown
