-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local WeatherManager = require(Managers.WeatherManager)

return function(context, weatherName: string)
	if not WeatherManager:SetWeather(if weatherName == "Clear" then nil else weatherName) then
		return `The weather is already {weatherName}.`
	end

	return `Rolling the weather over to {weatherName}.`
end
