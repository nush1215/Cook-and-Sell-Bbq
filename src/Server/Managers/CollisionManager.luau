-- Services
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

--[[
    Owns the game's collision groups and the rules between them.

    Players and NPCs each get their own group so NPCs can be made to pass through players (and each other)
    while everything still collides with the world (the built-in Default group, which the world stays in).
    Player characters are assigned to the Player group as they spawn; callers assign their own models (e.g.
    a spawned NPC) with SetModelGroup.

    Structure is what every placed structure goes into (see Base:BuildStructure). It's solid to players
    like the rest of the world -- a base you can walk through isn't a base -- and passable to the
    customers coming for the stall, who are sent on a plain MoveTo with nothing routing them round
    anything (see SellNpcManager:_walkTo). Without that, a griller left standing on the line between the
    spawn and the stall stops the visit dead until it times out and the sale simply never happens.

    RockDebris is the odd one out: nothing here assigns it, because the rocks a meteor crate throws are
    spawned client-side by Modules/RockModule, which can't require a server manager. It names the group
    as a string and this registers it -- so the name has to stay in step across the two.
]]

--
local CollisionManager = {
	PLAYER = "Player",
	NPC = "Npc",
	STRUCTURE = "Structure",
	ROCK_DEBRIS = "RockDebris",
}

-- Registers a collision group if it isn't already (RegisterCollisionGroup errors on a repeat).
local function ensureGroup(name: string)
	if not PhysicsService:IsCollisionGroupRegistered(name) then
		PhysicsService:RegisterCollisionGroup(name)
	end
end

-- Puts every BasePart in `model` into collision group `groupName`.
function CollisionManager:SetModelGroup(model: Model, groupName: string)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = groupName
		end
	end
end

function CollisionManager:OnInit()
	ensureGroup(self.PLAYER)
	ensureGroup(self.NPC)
	ensureGroup(self.STRUCTURE)
	ensureGroup(self.ROCK_DEBRIS)

	-- NPCs don't collide with each other or with players; both still collide with the world (Default).
	PhysicsService:CollisionGroupSetCollidable(self.NPC, self.NPC, false)
	PhysicsService:CollisionGroupSetCollidable(self.NPC, self.PLAYER, false)

	-- A customer walks through whatever the owner has built rather than getting stuck on it. Left
	-- collidable with Player on purpose, since a structure is something you stand a base out of.
	PhysicsService:CollisionGroupSetCollidable(self.STRUCTURE, self.NPC, false)

	-- Debris is scenery: it falls, rests on the ground and fades, but never shoves anyone around.
	-- Left collidable with Default on purpose, or the rocks would drop through the floor.
	PhysicsService:CollisionGroupSetCollidable(self.ROCK_DEBRIS, self.PLAYER, false)
	PhysicsService:CollisionGroupSetCollidable(self.ROCK_DEBRIS, self.NPC, false)
end

function CollisionManager:OnStart()
	local function hookPlayer(player: Player)
		if player.Character then
			self:SetModelGroup(player.Character, self.PLAYER)
		end
		player.CharacterAdded:Connect(function(character: Model)
			self:SetModelGroup(character, self.PLAYER)
		end)
	end

	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
end

return CollisionManager
