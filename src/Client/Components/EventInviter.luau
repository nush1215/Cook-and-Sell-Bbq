-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Component = require(Packages.Component)
local Trove = require(Packages.Trove)

--
local LocalPlayer = Players.LocalPlayer

--
local EventInviter = Component.new({
	Tag = script.Name,
	-- ReplicatedStorage too, so an inviter parked off someone else's base keeps its component and can come back
	Ancestors = { workspace, ReplicatedStorage },
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

	-- Every base carries one at Base[id].Core.RSVPInv, so only the local player's own is shown
	local baseFolder = workspace:FindFirstChild("Base")
	if baseFolder and adornee:IsDescendantOf(baseFolder) then
		self:_watchBaseOwnership(adornee.Parent)
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

-- Parks the inviter in ReplicatedStorage unless its base is the local player's, re-checked as BaseId moves.
function EventInviter:_watchBaseOwnership(core: Instance)
	local adornee = self.Instance
	local baseId = core.Parent.Name

	local function refresh()
		adornee.Parent = if LocalPlayer:GetAttribute("BaseId") == baseId then core else ReplicatedStorage
	end

	-- A streamed-out base leaves nowhere to return to, so the parked copy goes rather than lingering
	self._cleaner:Connect(core.AncestryChanged, function()
		if not core:IsDescendantOf(workspace) then
			adornee:Destroy()
		end
	end)

	-- BaseId lands after the bases are built, so the player's own starts parked until it arrives
	self._cleaner:Connect(LocalPlayer:GetAttributeChangedSignal("BaseId"), refresh)
	refresh()
end

function EventInviter:Stop()
	self._cleaner:Destroy()
end

return EventInviter
