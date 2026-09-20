-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Shared
local Shared = ReplicatedStorage.Shared
local Structures = require(Shared.Config.Structures)

-- Managers
local Managers = ServerScriptService.Server.Managers
local BuildManager = require(Managers.BuildManager)

--
local TABLES_CATEGORY = "Tables"

-- Every table at once, since they have no shop yet and one giveStructure per item is a lot of typing
return function(context, amount: number?, player: Player?)
	local target = player or context.Executor
	local count = amount or 1
	local given = 0

	for _, structure in Structures.Data do
		if structure.Category == TABLES_CATEGORY then
			BuildManager:GrantStructure(target, structure.Id, count)
			given += 1
		end
	end

	return `Gave {count} of each of {given} tables to {target.Name}.`
end
