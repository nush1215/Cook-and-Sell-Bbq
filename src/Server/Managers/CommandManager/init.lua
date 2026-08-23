-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Cmdr = require(Packages.Cmdr)

--
local CommandService = {}

function CommandService:OnInit()
	Cmdr:RegisterDefaultCommands()

	for _, command in script.Commands:GetChildren() do
		Cmdr:RegisterCommandsIn(command)
	end

	Cmdr:RegisterTypesIn(script.Types)
	Cmdr:RegisterHooksIn(script.Hooks)
end

return CommandService
