-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

--
-- How far a placed sound is worth sending. Roblox's own rolloff has silenced it well before this, so a
-- recipient past it is paying for a packet it can't hear
local DEFAULT_MAX_DISTANCE = 250

--
type SoundReplication =
	"All"
	| { Type: "All" }
	| { Type: "Player", Player: Player }
	| { Type: "Players", Players: { Player } }
	| { Type: "PlayersExcept", Players: { Player } }

type SoundOptions = {
	Limit: boolean?,
	RandomFromFolder: boolean?,
	MaxDistance: number?,
}

--
local SoundManager = {
	PlaySoundEvent = Network.Event("PlaySound"),
	PlayRandomSoundEvent = Network.Event("PlayRandomSoundInFolder"),
}

-- Every current player except those in `excludedPlayers`.
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

-- Expands a replication descriptor into the concrete recipients.
local function getRecipients(replication: SoundReplication): { Player }?
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

	warn("Invalid sound replication type:", replicationType)
	return nil
end

-- Resolves the sound's world origin from its location, or nil for an unplaced one that everyone hears.
local function getOriginPosition(location: CFrame | Vector3 | Part?): Vector3?
	if typeof(location) == "Vector3" then
		return location
	end

	if typeof(location) == "CFrame" then
		return location.Position
	end

	if typeof(location) == "Instance" and location:IsA("BasePart") then
		return location.Position
	end

	return nil
end

-- Filters recipients by HumanoidRootPart distance from the sound's origin.
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

-- Tells the described clients to play a sound at `location`, returning the Sound instance.
function SoundManager:PlaySound(
	replication: SoundReplication,
	soundName: string,
	location: CFrame | Vector3 | Part?,
	customProperties: { [any]: any }?,
	options: SoundOptions?
)
	local recipients = getRecipients(replication)
	if not recipients then
		return
	end

	local originPosition = getOriginPosition(location)
	if originPosition then
		local maxDistance = if options and options.MaxDistance then options.MaxDistance else DEFAULT_MAX_DISTANCE
		recipients = filterPlayersByDistance(recipients, originPosition, maxDistance)
	end

	if #recipients == 0 then
		return
	end

	local limit = if options then options.Limit else nil
	if options and options.RandomFromFolder then
		self.PlayRandomSoundEvent:FireClients(recipients, { soundName, { location, customProperties, limit } })
		return
	end

	self.PlaySoundEvent:FireClients(recipients, { soundName, location, customProperties, limit })
end

return SoundManager
