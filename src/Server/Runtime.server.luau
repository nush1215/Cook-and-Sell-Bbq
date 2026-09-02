-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

-- Server
local Server = script.Parent
local Managers = Server.Managers
local Components = Server.Components

-- Shared
local Shared = ReplicatedStorage.Shared
local Loader = require(Shared.Loader)

-- Modules
local LoadedComponents = require(Server.Modules.LoadedComponents)

--
local PRIORITY_TO_LOAD = {
	"PlayerDataManager",
}

--
local LoadedManagers = {}

--
Loader.run({
	Label = "Server",
	Container = Managers,
	Components = Components,
	Priority = PRIORITY_TO_LOAD,
	Modules = LoadedManagers,
	LoadedComponents = LoadedComponents,
})

--
PhysicsService:RegisterCollisionGroup("Player")
PhysicsService:RegisterCollisionGroup("LeaderboardNPC")

PhysicsService:CollisionGroupSetCollidable("Player", "LeaderboardNPC", false)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		for _, v in character:GetChildren() do
			if v:IsA("BasePart") then
				v.CollisionGroup = "Player"
			end
		end
	end)
end)

for _, v in Players:GetPlayers() do
	if v.Character then
		for _, v in v.Character:GetChildren() do
			if v:IsA("BasePart") then
				v.CollisionGroup = "Player"
			end
		end
	else
		v.CharacterAdded:Connect(function(character)
			for _, v in character:GetChildren() do
				if v:IsA("BasePart") then
					v.CollisionGroup = "Player"
				end
			end
		end)
	end
end

--
ReplicatedStorage:SetAttribute("ServerLoaded", true)
