-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Server
local Server = script.Parent.Parent
local ServerRandom = require(Server.Modules.ServerRandom)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local RandomUtil = require(Shared.RandomUtil)
local Ingredients = require(Shared.Config.Ingredients)
local RandomIngredient = require(Shared.Config.RandomIngredient)

-- Managers
local PlayerDataManager
local IngredientManager
local NotificationManager

-- The landing ray starts this far above the root, so a step up ahead is still found, and runs this far down
local LANDING_RAY_LIFT = 5
local LANDING_RAY_LENGTH = 200

-- Studs below the root that stand in for the ground when the ray finds none, roughly their feet
local FALLBACK_GROUND_DROP = 3

-- Runs the Random Ingredient product: rolls on purchase, banks the roll in data, and hands it over once the reveal everyone nearby watches has played.
local RandomIngredientManager = {
	RevealEvent = Network.Event("RandomIngredientReveal"), -- server -> all (buyer, uid, ingredientId, landingCFrame, startAt, isFirstOfDay)
	ClaimEvent = Network.Event("ClaimRandomIngredient"), -- client -> server (uid), the buyer's once their reveal ends

	-- [uid] = { Owner, StartAt } per reveal still playing on this server; dropped the moment it settles
	_reveals = {},
	-- [player] = when their last queued reveal ends, so a second buy plays after the first rather than on top of it
	_revealsEndAt = {},
}

-- Where a reveal lands: REVEAL_DISTANCE ahead of the buyer on the ground, facing back at them. Nil without a character.
local function findRevealLanding(player: Player): CFrame?
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return nil
	end

	-- Flattened, so looking up or down still lands it level in front of them
	local look = rootPart.CFrame.LookVector * Vector3.new(1, 0, 1)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis

	local position = rootPart.Position + look * RandomIngredient.REVEAL_DISTANCE

	-- Every character is left out, so it can't land on somebody's head
	local excluded = {}
	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer.Character then
			table.insert(excluded, otherPlayer.Character)
		end
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = excluded
	raycastParams.IgnoreWater = true

	local result = workspace:Raycast(
		position + Vector3.new(0, LANDING_RAY_LIFT, 0),
		Vector3.new(0, -LANDING_RAY_LENGTH, 0),
		raycastParams
	)

	local groundY = if result then result.Position.Y else rootPart.Position.Y - FALLBACK_GROUND_DROP
	local ground = Vector3.new(position.X, groundY, position.Z)

	return CFrame.lookAt(ground, Vector3.new(rootPart.Position.X, groundY, rootPart.Position.Z))
end

-- Rolls one ingredient off the pool, banks it, and starts its reveal for everyone nearby. `isFirstOfDay` only changes the show's bait, never the roll.
function RandomIngredientManager:GrantRandomIngredient(player: Player, isFirstOfDay: boolean?)
	-- Awaited first, since a receipt left over from their last session can clear before their data has loaded
	local hasData = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local weighted = {}
	for _, entry in RandomIngredient.Pool do
		table.insert(weighted, { entry.Id, entry.Chance })
	end

	local ingredientId = RandomUtil.GetResultFromWeight(weighted, ServerRandom.MakeRNG(RandomIngredient.Id))
	local uid = HttpService:GenerateGUID(false)

	-- Banked before anything plays, so leaving or the server dying mid-show still lands it on their next join
	PlayerDataManager:SetPlayerDataKey(player, { "PendingRandomIngredients", uid }, ingredientId)

	local landingCFrame = findRevealLanding(player)
	if not landingCFrame then
		self:SettleRandomIngredient(player, uid)
		return
	end

	local now = workspace:GetServerTimeNow()
	local startAt = math.max(now, self._revealsEndAt[player] or 0)
	local revealDuration = RandomIngredient.GetRevealDuration()

	self._revealsEndAt[player] = startAt + revealDuration + RandomIngredient.REVEAL_QUEUE_GAP
	self._reveals[uid] = { Owner = player, StartAt = startAt }

	-- To everyone, off one shared start time, so every client sees the same crash at the same moment
	self.RevealEvent:FireAllClients(player, uid, ingredientId, landingCFrame, startAt, isFirstOfDay == true)

	-- The roll is already theirs, so a client that never claims doesn't cost them it
	task.delay(startAt - now + revealDuration + RandomIngredient.CLAIM_FALLBACK_DELAY, function()
		if not self._reveals[uid] then
			return
		end

		self._reveals[uid] = nil

		-- Gone already, so it stays banked in their saved data for the next join to hand over
		if player:IsDescendantOf(Players) then
			self:SettleRandomIngredient(player, uid)
		end
	end)
end

-- Hands over a reveal's ingredient once its buyer's client has watched it land. An early claim is ignored; the fallback still pays.
function RandomIngredientManager:ClaimRandomIngredient(player: Player, uid: string)
	-- Straight off a remote, so it can't be trusted to be a string
	if typeof(uid) ~= "string" then
		return
	end

	local reveal = self._reveals[uid]
	if not reveal or reveal.Owner ~= player then
		return
	end

	local elapsed = workspace:GetServerTimeNow() - reveal.StartAt
	if elapsed < RandomIngredient.GetRevealDuration() - RandomIngredient.CLAIM_GRACE then
		return
	end

	-- Dropped before the grant yields, so a doubled claim or the fallback can't pay twice
	self._reveals[uid] = nil
	self:SettleRandomIngredient(player, uid)
end

-- Moves one banked roll into their inventory, equipped, and toasts it. A no-op for one already settled.
function RandomIngredientManager:SettleRandomIngredient(player: Player, uid: string)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	local ingredientId = data.PendingRandomIngredients[uid]
	if not ingredientId then
		return
	end

	PlayerDataManager:SetPlayerDataKey(player, { "PendingRandomIngredients", uid }, nil)

	-- Data outlives the config, so a roll banked before its ingredient was removed has nothing to hand over
	local ingredient = Ingredients.GetIngredientFromId(ingredientId)
	if not ingredient then
		return
	end

	IngredientManager:GrantIngredient(player, ingredientId)

	NotificationManager:NotifyNormal(player, {
		Text = `You got 1x {GuiUtil.Colorize(ingredient.Name, ingredient.Color)}`,
		Duration = 5,
		Sound = "CollectedReward",
		Effect = "Success",
	})
end

function RandomIngredientManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	IngredientManager = require(script.Parent.IngredientManager)
	NotificationManager = require(script.Parent.NotificationManager)

	-- A reveal cut short by leaving, or by the server dying mid-show, is handed over on the next join. Deferred, since this can't yield
	PlayerDataManager:RegisterPostLoadCallback(function(player: Player, data)
		for uid in data.PendingRandomIngredients do
			task.defer(self.SettleRandomIngredient, self, player, uid)
		end
	end)
end

function RandomIngredientManager:OnStart()
	self.ClaimEvent:OnServerEvent(function(player: Player, uid: string)
		self:ClaimRandomIngredient(player, uid)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._revealsEndAt[player] = nil
	end)
end

return RandomIngredientManager
