-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
ReplicatedStorage:SetAttribute("ServerLoaded", true)
