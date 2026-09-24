-- Services
local Players = game:GetService("Players")

-- Controllers
local CameraController = require(script.Parent.CameraController)
local HudController

-- Local Player
local LocalPlayer = Players.LocalPlayer

-- Drops the character above the target so it lands on top of the spawn part instead of clipping in.
local SPAWN_HEIGHT_OFFSET = 5

-- Wires the top bar's teleport buttons. Both destinations are readable off the world and the client owns its character, so there's no round-trip.
local TeleportController = {}

-- Pivots the character onto a part and swings the camera to match, so they land looking where they face.
function TeleportController:_teleportToPart(targetPart: PVInstance)
	-- No character to move while the player is mid-respawn.
	local character = LocalPlayer.Character
	if not character or not character.PrimaryPart then
		return
	end

	local destination = targetPart:GetPivot() * CFrame.new(0, SPAWN_HEIGHT_OFFSET, 0)
	character:PivotTo(destination)

	CameraController:AlignCameraYawTo(destination.LookVector)
end

-- Sends the character to their base's PlayerSpawn. Nothing until they've been given a base.
function TeleportController:TeleportToBase()
	local baseId = LocalPlayer:GetAttribute("BaseId")
	if not baseId then
		return
	end

	self:_teleportToPart(workspace.Base[baseId].Core.PlayerSpawn)
end

function TeleportController:OnInit()
	HudController = require(script.Parent.HudController)
end

function TeleportController:OnStart()
	HudController:BindHudButton("Store", function()
		self:_teleportToPart(workspace.Core.Teleports.Store)
	end)

	HudController:BindHudButton("Base", function()
		self:TeleportToBase()
	end)
end

return TeleportController
