-- Services
local Players = game:GetService("Players")

-- Controllers
local HudController

-- Local Player
local LocalPlayer = Players.LocalPlayer

-- Drops the character above the target so it lands on top of the spawn part instead of clipping in.
local SPAWN_HEIGHT_OFFSET = 5

-- Wires the Top HUD bar's teleport buttons. Both destinations (the shared Store pad and the player's
-- own base spawn) are readable off the world, and the client owns its character, so these pivot the
-- local character directly with no server round-trip.
local TeleportController = {}

-- Pivots the local character onto a target part, sat SPAWN_HEIGHT_OFFSET studs above it.
function TeleportController:_teleportToPart(targetPart: PVInstance)
	-- No character to move while the player is mid-respawn.
	local character = LocalPlayer.Character
	if not character or not character.PrimaryPart then
		return
	end

	character:PivotTo(targetPart:GetPivot() * CFrame.new(0, SPAWN_HEIGHT_OFFSET, 0))
end

function TeleportController:OnInit()
	HudController = require(script.Parent.HudController)
end

function TeleportController:OnStart()
	HudController:BindHudButton("Store", function()
		self:_teleportToPart(workspace.Core.Teleports.Store)
	end)

	HudController:BindHudButton("Base", function()
		local baseId = LocalPlayer:GetAttribute("BaseId")
		if not baseId then
			return
		end

		self:_teleportToPart(workspace.Base[baseId].Core.PlayerSpawn)
	end)
end

return TeleportController
