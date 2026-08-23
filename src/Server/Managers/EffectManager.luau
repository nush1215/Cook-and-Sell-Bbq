-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

--
local DEFAULT_MAX_DISTANCE = 5000

--
type EffectReplication =
	"All"
	| { Type: "All" }
	| { Type: "Player", Player: Player }
	| { Type: "Players", Players: { Player } }
	| { Type: "PlayersExcept", Players: { Player } }

type EffectOptions = {
	MaxDistance: number?,
	SkipLowGraphics: boolean?,
}

--
local EffectManager = {
	RunEffectEvent = Network.Event("RunEffect"),
}

-- Resolves the effect's world origin from the first effect argument.
local function getOriginPosition(origin: any): Vector3?
	if typeof(origin) == "Vector3" then
		return origin
	end

	if typeof(origin) ~= "Instance" then
		return nil
	end

	if origin:IsA("BasePart") then
		return origin.Position
	end

	if origin:IsA("Model") then
		return origin:GetPivot().Position
	end

	return nil
end

-- Gets all current players except the excluded list.
local function getPlayersExcept(excludedPlayers: { Player }): { Player }
	local excluded = {}
	for _, player in excludedPlayers do
		excluded[player] = true
	end

	local players = {}
	for _, player in Players:GetPlayers() do
		if excluded[player] then
			continue
		end

		table.insert(players, player)
	end

	return players
end

-- Expands a replication descriptor into concrete recipients.
local function getRecipients(replication: EffectReplication): { Player }?
	if replication == "All" then
		return Players:GetPlayers()
	end

	local replicationData = replication :: any
	local replicationType = replicationData.Type
	if replicationType == "All" then
		return Players:GetPlayers()
	end

	if replicationType == "Player" then
		return { replicationData.Player }
	end

	if replicationType == "Players" then
		return replicationData.Players
	end

	if replicationType == "PlayersExcept" then
		return getPlayersExcept(replicationData.Players)
	end

	warn("Invalid effect replication type:", replicationType)
	return nil
end

-- Filters recipients by HumanoidRootPart distance from the effect origin.
local function filterPlayersByDistance(players: { Player }, originPosition: Vector3, maxDistance: number): { Player }
	local filteredPlayers = {}

	for _, player in players do
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if not (rootPart and rootPart:IsA("BasePart")) then
			continue
		end

		if (rootPart.Position - originPosition).Magnitude <= maxDistance then
			table.insert(filteredPlayers, player)
		end
	end

	return filteredPlayers
end

-- Tells selected clients to run an effect module.
function EffectManager:RunEffect(
	replication: EffectReplication,
	effectName: string,
	data: { any }?,
	options: EffectOptions?
)
	local effectData = data or {}
	local recipients = getRecipients(replication)
	if not recipients then
		return
	end

	local originPosition = getOriginPosition(effectData[1])
	if originPosition then
		local maxDistance = if options and options.MaxDistance then options.MaxDistance else DEFAULT_MAX_DISTANCE
		recipients = filterPlayersByDistance(recipients, originPosition, maxDistance)
	end

	if options and options.SkipLowGraphics then
		-- TODO: Filter out players with low graphics mode enabled once that setting exists server-side.
	end

	if #recipients == 0 then
		return
	end

	self.RunEffectEvent:FireClients(recipients, { effectName, effectData })
end

return EffectManager
