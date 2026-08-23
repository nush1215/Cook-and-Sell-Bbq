-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AnalyticsService = game:GetService("AnalyticsService")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

--
local Codes = require(script.Codes)

--
local PlayerDataManager
local NotificationManager

--
local CodeManager = {
	ClaimCodeEvent = Network.Event("ClaimCode"),
	_inCooldown = {},
}

function CodeManager:ClaimCode(player: Player, code: string)
	-- Add a debounce so that it wont call ts a billion times in 1 sec
	if self._inCooldown[player] then
		NotificationManager:NotifyNormal(
			player,
			{
				Text = "Please wait a moment before redeeming another code!",
				Duration = 3,
				Sound = "Reject",
			}
		)
		return
	end

	self._inCooldown[player] = true
	task.delay(1, function()
		self._inCooldown[player] = false
	end)

	-- Check if the code is valid
	local codeData = Codes.GetCodeFromCode(code)
	if not codeData then
		NotificationManager:NotifyNormal(player, {
			Text = "Invalid code!",
			Duration = 5,
			Sound = "Reject",
		})
		return
	end

	-- Check if the player has already redeemed the code
	local hasData, playerData = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	-- Keyed on the code as authored, never as typed: the lookup above is case-insensitive, so storing
	-- the raw input would let "release" redeem again after "RELEASE".
	if table.find(playerData.RedeemedCodes, codeData.Code) then
		NotificationManager:NotifyNormal(player, {
			Text = "You have already redeemed this code!",
			Duration = 5,
			Sound = "Reject",
		})
		return
	end

	-- Redeem the code
	PlayerDataManager:InsertPlayerDataKey(player, "RedeemedCodes", codeData.Code)

	codeData.Callback(player)
	NotificationManager:NotifyNormal(
		player,
		{
			Text = `Successfully Redeemed <font color="#ffd400">{codeData.Code}</font> Code!`,
			Duration = 5,
			Sound = "CollectedReward",
		}
	)

	if codeData.OnClaimMessage then
		NotificationManager:NotifyNormal(player, {
			Text = codeData.OnClaimMessage,
			Duration = 5,
		})
	end

	task.spawn(function()
		pcall(function()
			AnalyticsService:LogCustomEvent(player, "Redeemed Code", 1, {
				[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = codeData.Code,
			})
		end)
	end)
end

function CodeManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	NotificationManager = require(script.Parent.NotificationManager)
end

function CodeManager:OnStart()
	self.ClaimCodeEvent:OnServerEvent(function(player: Player, code: string)
		self:ClaimCode(player, code)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._inCooldown[player] = nil
	end)
end

return CodeManager
