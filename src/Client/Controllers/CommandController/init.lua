-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Cmdr = require(ReplicatedStorage.CmdrClient)

-- Local Player
local LocalPlayer = Players.LocalPlayer

--
local KEY_BINDS = {
	Enum.KeyCode.F2,
}

--
local CommandController = {}

function CommandController:OnInit()
	Cmdr:SetActivationKeys(KEY_BINDS)

	Cmdr.Registry:RegisterCommandsIn(script.Commands)
	Cmdr.Registry:RegisterTypesIn(script.Types)
	Cmdr.Registry:RegisterHooksIn(script.Hooks)
end

return CommandController
