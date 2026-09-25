-- Services
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Assets
local Weathers = ReplicatedStorage.Assets.Weathers

--
-- Seconds a weather takes to roll in or clear away
local TRANSITION_TIME = 10

local TRANSITION_TWEEN_INFO = TweenInfo.new(TRANSITION_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

-- The properties each effect class fades between
local EFFECT_PROPERTIES = {
	Atmosphere = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" },
	BloomEffect = { "Intensity", "Size", "Threshold" },
	BlurEffect = { "Size" },
	ColorCorrectionEffect = { "Brightness", "Contrast", "Saturation", "TintColor" },
	DepthOfFieldEffect = { "FarIntensity", "FocusDistance", "InFocusRadius", "NearIntensity" },
	SunRaysEffect = { "Intensity", "Spread" },
}

-- Values that leave each effect class invisible, so one the map lacks can fade in from and out to nothing
local NEUTRAL_EFFECT_PROPERTIES = {
	Atmosphere = { Density = 0, Glare = 0, Haze = 0 },
	BloomEffect = { Intensity = 0 },
	BlurEffect = { Size = 0 },
	ColorCorrectionEffect = { Brightness = 0, Contrast = 0, Saturation = 0, TintColor = Color3.new(1, 1, 1) },
	DepthOfFieldEffect = { FarIntensity = 0, NearIntensity = 0 },
	SunRaysEffect = { Intensity = 0 },
}

-- Runs the server's weather off the folders in Assets.Weathers: Properties attributes retune Lighting, effects named like the map's retune them in place, other effects and world objects fade in on top, and the Sky cuts over halfway.
local WeatherManager = {
	-- The weather folder's name while one is rolling in or up, nil on clear skies
	CurrentWeather = nil :: string?,

	-- Every Lighting property any weather sets, as the map had it, for clearing back to
	_defaultLightingProperties = {} :: { [string]: any },
	-- [name] = { Effect, Properties } for each of the map's own Lighting effects, as authored
	_mapEffects = {} :: { [string]: { Effect: Instance, Properties: { [string]: any } } },
	_defaultSky = nil :: Sky?,

	-- What the current weather brought that the map doesn't have, faded out and removed when it leaves
	_addedInstances = {} :: { Instance },

	-- Bumped per transition, so a superseded one's halfway cut doesn't land
	_transitionId = 0,
}

-- Fades `instance` to `goal` over the transition.
local function fade(instance: Instance, goal: { [string]: any })
	TweenService:Create(instance, TRANSITION_TWEEN_INFO, goal):Play()
end

-- The fading properties of `effect` as they stand, as a tween goal.
local function readEffectProperties(effect: Instance): { [string]: any }
	local properties = {}
	for _, property in EFFECT_PROPERTIES[effect.ClassName] do
		properties[property] = (effect :: any)[property]
	end

	return properties
end

-- Rolls the server's weather over to `weatherName`, or back to the map's own clear skies when nil. False if it's already that weather.
function WeatherManager:SetWeather(weatherName: string?): boolean
	if weatherName == self.CurrentWeather then
		return false
	end

	self.CurrentWeather = weatherName
	self._transitionId += 1

	local transitionId = self._transitionId
	local weather = if weatherName then Weathers[weatherName] else nil
	local weatherProperties = if weather then weather.Properties:GetAttributes() else {}

	for _, instance in self._addedInstances do
		-- World objects outlive the fade until their last particles land
		local removeAfter = TRANSITION_TIME

		if EFFECT_PROPERTIES[instance.ClassName] then
			fade(instance, NEUTRAL_EFFECT_PROPERTIES[instance.ClassName])
		else
			for _, descendant in instance:GetDescendants() do
				if descendant:IsA("ParticleEmitter") then
					removeAfter = math.max(removeAfter, TRANSITION_TIME + descendant.Lifetime.Max)
					fade(descendant, { Rate = 0 })
				elseif descendant:IsA("Sound") then
					fade(descendant, { Volume = 0 })
				end
			end
		end

		task.delay(removeAfter, function()
			instance:Destroy()
		end)
	end

	table.clear(self._addedInstances)

	local lightingGoal = {}
	local snappedProperties = {}

	for property, defaultValue in self._defaultLightingProperties do
		local value = weatherProperties[property]
		if value == nil then
			value = defaultValue
		end

		-- Bools and enums can't tween, so they flip with the sky at the halfway mark
		if typeof(value) == "number" or typeof(value) == "Color3" then
			lightingGoal[property] = value
		else
			snappedProperties[property] = value
		end
	end

	fade(Lighting, lightingGoal)

	for name, mapEffect in self._mapEffects do
		local weatherEffect = weather and weather:FindFirstChild(name)
		local retunes = weatherEffect and weatherEffect.ClassName == mapEffect.Effect.ClassName

		fade(mapEffect.Effect, if retunes then readEffectProperties(weatherEffect) else mapEffect.Properties)
	end

	if weather then
		for _, child in weather:GetChildren() do
			local mapEffect = self._mapEffects[child.Name]
			local retunesMapEffect = mapEffect and mapEffect.Effect.ClassName == child.ClassName

			-- Retuned map effects are faded above, and the Sky cuts over halfway
			if child == weather.Properties or child:IsA("Sky") or retunesMapEffect then
				continue
			end

			local clone = child:Clone()
			local fades = {}

			if EFFECT_PROPERTIES[clone.ClassName] then
				fades[clone] = readEffectProperties(clone)

				for property, value in NEUTRAL_EFFECT_PROPERTIES[clone.ClassName] do
					(clone :: any)[property] = value
				end

				clone.Parent = Lighting
			else
				for _, descendant in clone:GetDescendants() do
					if descendant:IsA("ParticleEmitter") then
						fades[descendant] = { Rate = descendant.Rate }
						descendant.Rate = 0
					elseif descendant:IsA("Sound") then
						fades[descendant] = { Volume = descendant.Volume }
						descendant.Volume = 0
					end
				end

				-- Persistent so it reaches every client rather than only those streaming has near its part
				clone.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
				clone.Parent = workspace
			end

			for instance, goal in fades do
				fade(instance, goal)
			end

			table.insert(self._addedInstances, clone)
		end
	end

	task.delay(TRANSITION_TIME / 2, function()
		if self._transitionId ~= transitionId then
			return
		end

		for property, value in snappedProperties do
			(Lighting :: any)[property] = value
		end

		local weatherSky = weather and weather:FindFirstChildOfClass("Sky")
		local nextSky = if weatherSky then weatherSky:Clone() else self._defaultSky

		-- Up before the old one comes down, so no client catches a frame of Roblox's default sky
		if nextSky then
			nextSky.Parent = Lighting
		end

		for _, sky in Lighting:GetChildren() do
			if not sky:IsA("Sky") or sky == nextSky then
				continue
			end

			if sky == self._defaultSky then
				sky.Parent = nil
			else
				sky:Destroy()
			end
		end
	end)

	return true
end

function WeatherManager:OnInit()
	for _, weather in Weathers:GetChildren() do
		for property in weather.Properties:GetAttributes() do
			self._defaultLightingProperties[property] = (Lighting :: any)[property]
		end
	end

	for _, effect in Lighting:GetChildren() do
		if EFFECT_PROPERTIES[effect.ClassName] then
			self._mapEffects[effect.Name] = { Effect = effect, Properties = readEffectProperties(effect) }
		end
	end

	self._defaultSky = Lighting:FindFirstChildOfClass("Sky")
end

return WeatherManager
