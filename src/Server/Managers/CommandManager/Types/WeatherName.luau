-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

return function(registry)
	-- Built from the weather folders so a weather added there needs no edit here; Clear is the map's own skies
	local weatherNames = { "Clear" }
	for _, weather in ReplicatedStorage.Assets.Weathers:GetChildren() do
		table.insert(weatherNames, weather.Name)
	end
	table.sort(weatherNames)

	registry:RegisterType("weatherName", registry.Cmdr.Util.MakeEnumType("weatherName", weatherNames))
end
