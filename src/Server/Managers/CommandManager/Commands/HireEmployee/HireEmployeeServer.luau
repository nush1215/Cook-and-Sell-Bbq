-- Services
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Managers
local Managers = ServerScriptService.Server.Managers
local EmployeeManager = require(Managers.EmployeeManager)

-- Shared
local Shared = ReplicatedStorage.Shared
local Employees = require(Shared.Config.Employees)
local Rating = require(Shared.Config.Rating)

return function(context, body: string, stars: number?, role: string?, player: Player?)
	local target = player or context.Executor

	-- An admin grant, so it's equipped straight into the first empty slot, unlocked or not -- testing on a
	-- base with no hut would otherwise leave every hire unequipped with no panel to equip them from
	local success, message = EmployeeManager:HireEmployee(
		target,
		role or Employees.ROLES.COOKER,
		body,
		math.clamp(stars or 3, 0, Rating.MAX_STARS),
		{ Equip = true }
	)

	if not success then
		return message or "Failed to hire an employee."
	end

	return message
end
