-- Services
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

-- Owns the game's collision groups. Structure is solid to players and passable to customers, whose plain MoveTo would otherwise stall on a griller in the way. RockDebris is named as a string by the client's RockModule, so the name has to stay in step.

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

	-- Customers walk through structures; left collidable with Player, since a base is something to stand on
	PhysicsService:CollisionGroupSetCollidable(self.STRUCTURE, self.NPC, false)

	-- Scenery only. Left collidable with Default, or the rocks would drop through the floor
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
