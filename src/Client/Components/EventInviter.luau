-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

--
local EventInviter = Component.new({
	Tag = script.Name,
})

function EventInviter:Start()
	self._cleaner = Trove.new()

	--
	local adornee = self.Instance
	local eventId = adornee:GetAttribute("Id")
	--
	if not eventId then
		return
	end

	--
	local prompt = self._cleaner:Add(Instance.new("ProximityPrompt"))
	prompt.ActionText = "View Event"
	prompt.HoldDuration = 0.5
	prompt.RequiresLineOfSight = false
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Parent = adornee

	--
	self._cleaner:Connect(prompt.Triggered, function()
		pcall(function()
			SocialService:PromptRsvpToEventAsync(eventId)
		end)
	end)
end

function EventInviter:Stop()
	self._cleaner:Destroy()
end

return EventInviter
