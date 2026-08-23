-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Client
local Client = script.Parent
local Controllers = Client.Controllers
local Components = Client.Components

-- Shared
local Shared = ReplicatedStorage.Shared
local Loader = require(Shared.Loader)

-- Packages
local Packages = ReplicatedStorage.Packages
local Replica = require(Packages.Replica)

-- Modules
local LoadedComponents = require(Client.Modules.LoadedComponents)

--
local PRIORITY_TO_LOAD = {
	"PlayerDataController",
}

--
local LoadedControllers = {}

-- Wait for the server to finish bootstrapping before requesting data.
Loader.waitForAttribute(ReplicatedStorage, "ServerLoaded")
Replica.RequestData()

--
Loader.run({
	Label = "Client",
	Container = Controllers,
	Components = Components,
	Priority = PRIORITY_TO_LOAD,
	Modules = LoadedControllers,
	LoadedComponents = LoadedComponents,
})

--
ReplicatedStorage:SetAttribute("ClientLoaded", true)
