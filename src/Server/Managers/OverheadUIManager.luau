-- Services
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local GuiUtil = require(Shared.GuiUtil)

-- Assets
local Assets = ReplicatedStorage.Assets
local UI = Assets.UI

--
local PlayerDataManager

--
local OverheadUIManager = {
	_cleaners = {},
}

function OverheadUIManager:_attachUI(player: Player)
	--
	local cleaner = Trove.new()
	self._cleaners[player] = cleaner

	local isVerified = player.HasVerifiedBadge
	local hasSubscription = player.HasRobloxSubscription
	local playerName = player.DisplayName

	if isVerified then
		playerName = `{playerName}{utf8.char(0xE000)}`
	end

	if hasSubscription then
		playerName = `{utf8.char(0xE003)}{playerName}`
	end

	--
	local overheadUI = cleaner:Clone(UI.OverheadUI)
	overheadUI.PlayerName.Text = playerName
	overheadUI.PlayerName.VIPGradient.Enabled = player:HasTag("VIP")
	overheadUI.Parent = workspace.Terrain

	-- Set adornee
	local function parentOverhead()
		--
		local character = player.Character
		local humanoid = character.Humanoid

		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

		local characterSize = character:GetExtentsSize()
		overheadUI.StudsOffset = Vector3.new(0, (characterSize.Y / 2) - 0.5, 0)
		overheadUI.Adornee = character.Head
	end

	if player.Character then
		parentOverhead()
	end
	player.CharacterAdded:Connect(parentOverhead)

	cleaner:Add(CollectionService:GetInstanceAddedSignal("VIP"):Connect(function(vipPlayer: Player)
		if vipPlayer == player then
			overheadUI.PlayerName.VIPGradient.Enabled = true
		end
	end))
end

function OverheadUIManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
end

function OverheadUIManager:OnStart()
	Players.PlayerAdded:Connect(function(player)
		self:_attachUI(player)
	end)

	for _, player in Players:GetPlayers() do
		self:_attachUI(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local cleaner = self._cleaners[player]
		if cleaner then
			cleaner:Destroy()
			self._cleaners[player] = nil
		end
	end)
end

return OverheadUIManager
