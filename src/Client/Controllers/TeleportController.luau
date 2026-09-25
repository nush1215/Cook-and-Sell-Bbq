-- Services
local Players = game:GetService("Players")

-- Controllers
local CameraController = require(script.Parent.CameraController)
local HudController

-- Local Player
local LocalPlayer = Players.LocalPlayer

-- Drops the character above the target so it lands on top of the spawn part instead of clipping in.
local SPAWN_HEIGHT_OFFSET = 5

-- How long a streamed-in base gets to finish replicating the spawn _cacheBaseSpawn reads.
local CHILD_TIMEOUT = 10

-- Wires the top bar's teleport buttons. Both destinations are readable off the world and the client owns its character, so there's no round-trip.
local TeleportController = {
	_baseSpawns = {}, -- [baseId] = its PlayerSpawn pivot, kept after the base streams out since bases never move
}

-- Pivots the character onto a pose and swings the camera to match, so they land looking where they face.
function TeleportController:_teleportTo(pivot: CFrame)
	-- No character to move while the player is mid-respawn.
	local character = LocalPlayer.Character
	if not character or not character.PrimaryPart then
		return
	end

	local destination = pivot * CFrame.new(0, SPAWN_HEIGHT_OFFSET, 0)
	character:PivotTo(destination)

	CameraController:AlignCameraYawTo(destination.LookVector)
end

-- Remembers where a base's PlayerSpawn stands, so the trip home still works once the base has streamed out.
function TeleportController:_cacheBaseSpawn(baseModel: Instance)
	local core = baseModel:WaitForChild("Core", CHILD_TIMEOUT)
	local spawnPart = core and core:WaitForChild("PlayerSpawn", CHILD_TIMEOUT)

	if spawnPart then
		self._baseSpawns[baseModel.Name] = spawnPart:GetPivot()
	end
end

-- Sends the character to their base's PlayerSpawn. Nothing until they've been given a base and it's streamed in once.
function TeleportController:TeleportToBase()
	local baseId = LocalPlayer:GetAttribute("BaseId")
	local pivot = baseId and self._baseSpawns[baseId]
	if not pivot then
		return
	end

	self:_teleportTo(pivot)
end

function TeleportController:OnInit()
	HudController = require(script.Parent.HudController)
end

function TeleportController:OnStart()
	HudController:BindHudButton("Store", function()
		self:_teleportTo(workspace.Core.Teleports.Store:GetPivot())
	end)

	HudController:BindHudButton("Base", function()
		self:TeleportToBase()
	end)

	-- An atomic base is gone from the world while streamed out, so each spawn is noted as it streams in. Off this thread, since the loader runs every OnStart on one
	task.spawn(function()
		local baseFolder = workspace:WaitForChild("Base")

		baseFolder.ChildAdded:Connect(function(baseModel)
			self:_cacheBaseSpawn(baseModel)
		end)

		-- _cacheBaseSpawn waits on the base's children, so keep the sweep off this thread too
		for _, baseModel in baseFolder:GetChildren() do
			task.spawn(function()
				self:_cacheBaseSpawn(baseModel)
			end)
		end
	end)
end

return TeleportController
