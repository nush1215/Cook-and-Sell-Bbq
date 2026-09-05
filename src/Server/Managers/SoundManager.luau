-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

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
}

--
local SoundManager = {
	PlaySoundEvent = Network.Event("PlaySound"),
	PlayRandomSoundEvent = Network.Event("PlayRandomSoundInFolder"),
	ReplicateToOthersEvent = Network.Event("ReplicateSoundToOthers"),
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

-- Tells the described clients to play a sound at `location`, returning the Sound instance.
function SoundManager:PlaySound(
	replication: SoundReplication,
	soundName: string,
	location: CFrame | Vector3 | Part?,
	customProperties: { [any]: any }?,
	options: SoundOptions?
)
	local recipients = getRecipients(replication)
	if not recipients or #recipients == 0 then
		return
	end

	local limit = if options then options.Limit else nil
	if options and options.RandomFromFolder then
		self.PlayRandomSoundEvent:FireClients(recipients, { soundName, { location, customProperties, limit } })
		return
	end

	self.PlaySoundEvent:FireClients(recipients, { soundName, location, customProperties, limit })
end

function SoundManager:OnStart()
	self.ReplicateToOthersEvent:OnServerEvent(function(fromPlayer: Player, params: { any })
		local soundName, location, customProperties, limit = table.unpack(params)
		self:PlaySound({ Type = "PlayersExcept", Players = { fromPlayer } }, soundName, location, customProperties, {
			Limit = limit,
		})
	end)
end

return SoundManager
