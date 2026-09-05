-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ConfigService = game:GetService("ConfigService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Network = require(ReplicatedStorage.Shared.Network)

-- Read-only, so the wipe below resets keys to their real defaults rather than duplicating them
local DataSettings = require(script.Parent.PlayerDataManager.DataSettings)

-- Managers
local PlayerDataManager
local IngredientRollingManager
local SellNpcManager
local GrillerManager
local TutorialCrateManager
local BuildManager
local NotificationManager
local StickManager

-- The server half of onboarding: what the first pull lands on, the guaranteed customer, the hammer gate, the finished flag and the funnel. Nothing here drives the client -- the rigs are armed for the whole run rather than per step.

-- The experience config naming the variant, and the attribute it's published to the client on.
local VARIANT_KEY = "TutorialVariant"

-- The fallback when ConfigService can't answer, or names a variant this build has no steps for
local FALLBACK_VARIANT = "B"

-- Pinned so the first pull can't land something unaffordable. Garlic is cheap to buy and quick to cook
local TUTORIAL_INGREDIENT_ID = "Garlic"

-- The stick B starts with: cheapest, and the only one restocking every window, so it's never sold out
local TUTORIAL_STICK_ID = "WoodenStick"

-- The variant that starts the player with a stick and moves the shop trip to the end of the run.
local STICK_FIRST_VARIANT = "B"

-- The window is ~3s on the pinned ingredient, too sharp for a first meeting; 3x makes it ~9s
local TUTORIAL_COOK_WINDOW_STRETCH = 3

-- The crash takes the camera, so it waits for the finish to land rather than talking over it
local TUTORIAL_CRATE_DELAY = 2

-- Keys wiped when an unfinished player leaves, so onboarding restarts clean. Purchases and playtime are preserved.
local PROGRESS_RESET_KEYS = {
	"Currency",
	"Unlocks",
	"Plots",
	"Structures",

	-- Both halves, or a player who placed their griller and quit would have it in neither
	"OwnedStructures",

	"Ingredients",
	"PendingRolls",
	"IngredientIndex",
	"Sticks",
	"StickStands",
	"SkewerStand",
	"FilledSticks",
	"Grillers",
	"SauceDispensers",
	"Sauces",
	"Crates",
	"TutorialCrateTimer",
	"StickShop",
	"LastRichVisit",
	"SaleRefusals",
	"SeenHaggle",
	"SeenRichCustomer",
	"TutorialStep",

	-- The lifetime counters go too -- a run being thrown away shouldn't leave a trail in the leaderboards
	"SkewersCooked",
	"SkewersSold",
	"SalesCompleted",
	"SalesDeclined",
	"IngredientsBought",
	"SticksBought",
	"SkewersSauced",
	"TotalEarned",
	"CookStateCounts",
	"SoldCookStateCounts",
	"RecentSales",
}

-- The ordered funnel per variant. Finer than the sequence list, so "opened the shop" and "bought nothing" are separate failures.
local VARIANT_FUNNEL_STEPS = {
	A = {
		{ Key = "Start", Name = "Tutorial Started" },
		{ Key = "EquipGrill", Name = "Equip Griller Tool" },
		{ Key = "PlaceGrill", Name = "Build Griller" },
		{ Key = "EquipStand", Name = "Equip Stick Stand Tool" },
		{ Key = "PlaceStand", Name = "Build Stick Stand" },
		{ Key = "Roll", Name = "Roll Ingredients" },
		{ Key = "BuyIngredient", Name = "Buy Ingredient" },
		{ Key = "OpenStore", Name = "Travel To Store" },
		{ Key = "OpenStickShop", Name = "Open Stick Shop" },
		{ Key = "SelectStick", Name = "Select Stick" },
		{ Key = "BuyStick", Name = "Buy Stick" },
		{ Key = "ReturnToBase", Name = "Travel Back To Base" },
		{ Key = "EquipStick", Name = "Equip Stick" },
		{ Key = "PlaceStick", Name = "Place Stick On Stand" },
		{ Key = "AddIngredient", Name = "Add Ingredient To Stick" },
		{ Key = "TakeStick", Name = "Take BBQ From Stand" },
		{ Key = "PlaceOnGrill", Name = "Place BBQ On Griller" },
		{ Key = "TakeFromGrill", Name = "Take BBQ Off Griller" },
		{ Key = "PlaceOnSellStand", Name = "Place BBQ On Sell Stand" },
		{ Key = "AcceptOffer", Name = "Accept Customer Offer" },
		{ Key = "Finish", Name = "Tutorial Finished" },
	},

	-- A's keys and names in B's order. Must match what Sequence/B fires -- _logStep only reports forward progress
	B = {
		{ Key = "Start", Name = "Tutorial Started" },
		{ Key = "EquipGrill", Name = "Equip Griller Tool" },
		{ Key = "PlaceGrill", Name = "Build Griller" },
		{ Key = "EquipStand", Name = "Equip Stick Stand Tool" },
		{ Key = "PlaceStand", Name = "Build Stick Stand" },
		{ Key = "EquipStick", Name = "Equip Stick" },
		{ Key = "PlaceStick", Name = "Place Stick On Stand" },
		{ Key = "Roll", Name = "Roll Ingredients" },
		{ Key = "BuyIngredient", Name = "Buy Ingredient" },
		{ Key = "AddIngredient", Name = "Add Ingredient To Stick" },
		{ Key = "TakeStick", Name = "Take BBQ From Stand" },
		{ Key = "PlaceOnGrill", Name = "Place BBQ On Griller" },
		{ Key = "TakeFromGrill", Name = "Take BBQ Off Griller" },
		{ Key = "PlaceOnSellStand", Name = "Place BBQ On Sell Stand" },
		{ Key = "AcceptOffer", Name = "Accept Customer Offer" },
		{ Key = "OpenStore", Name = "Travel To Store" },
		{ Key = "OpenStickShop", Name = "Open Stick Shop" },
		{ Key = "SelectStick", Name = "Select Stick" },
		{ Key = "BuyStick", Name = "Buy Stick" },
		{ Key = "ReturnToBase", Name = "Travel Back To Base" },
		{ Key = "Finish", Name = "Tutorial Finished" },
	},
}

-- Key -> index per variant, both built up front since which one applies depends on the player
local FUNNEL_STEP_INDEX = {}
for variant, steps in VARIANT_FUNNEL_STEPS do
	local keyToIndex = {}
	for index, step in steps do
		keyToIndex[step.Key] = index
	end

	FUNNEL_STEP_INDEX[variant] = keyToIndex
end

--
local TutorialManager = {
	FinishTutorialEvent = Network.Event("FinishTutorial"),
	LogStepEvent = Network.Event("LogTutorialStep"),

	-- (player, variant, stepIndex, stepName) when a player reaches a new onboarding step.
	OnFunnelStep = Signal.new(),

	_unfinished = {}, -- [player] = true while their tutorial is still running

	-- [player] = true once claimed -- both entry points can fire, and the stick grant mustn't happen twice
	_setupStarted = {},

	-- Furthest step logged, so a beat the client re-enters isn't re-reported to the funnel
	_maxFunnelStep = {},
}

-- Copies a template value so resets never share nested tables with the template itself.
local function deepCopy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, childValue in value do
		copy[deepCopy(key)] = deepCopy(childValue)
	end
	return copy
end

-- Pins the next pull to the tutorial ingredient. Re-armed after every pull, since it's worth one roll.
function TutorialManager:_armGuaranteedRoll(player: Player)
	if not self._unfinished[player] then
		return
	end

	IngredientRollingManager:ForceNextIngredient(player, TUTORIAL_INGREDIENT_ID)
end

-- Resolves and publishes the player's variant. Reading the config enrols them in any experiment on that key.
function TutorialManager:_assignVariant(player: Player): string
	-- Yields, and hangs before erroring in an experience with no configs -- the ordinary case in Studio
	local fetched, snapshot = pcall(function()
		return ConfigService:GetConfigForPlayerAsync(player)
	end)
	local assigned = fetched and snapshot:GetValue(VARIANT_KEY)

	-- A named variant with no steps would silently run the fallback while the experiment counted the arm
	if assigned and not VARIANT_FUNNEL_STEPS[assigned] then
		warn(`TutorialManager: config "{VARIANT_KEY}" served unknown variant "{tostring(assigned)}"`)
	end

	local variant = if VARIANT_FUNNEL_STEPS[assigned] then assigned else FALLBACK_VARIANT
	player:SetAttribute(VARIANT_KEY, variant)

	return variant
end

-- Picks up an unfinished player and arms both rigs for the whole run.
function TutorialManager:_setupTutorial(player: Player)
	-- Claimed before the first yield, so a second call can't hand over a second stick
	if self._setupStarted[player] then
		return
	end
	self._setupStarted[player] = true

	local hasData, completed = PlayerDataManager:GetPlayerDataKey(player, "TutorialCompleted"):await()
	if not hasData or completed then
		return
	end

	-- They may have left while the data read was in flight.
	if not player:IsDescendantOf(Players) then
		return
	end

	-- After the completed check, since reading the config enrols the player in the experiment
	local variant = self:_assignVariant(player)

	-- The config fetch yields, and can sit there a while before giving up
	if not player:IsDescendantOf(Players) then
		return
	end

	-- Left in the bag, not equipped -- the first beat asks for the griller, which would swap it straight out
	if variant == STICK_FIRST_VARIANT then
		StickManager:GrantStick(player, TUTORIAL_STICK_ID, 1, true)

		if not player:IsDescendantOf(Players) then
			return
		end
	end

	self._unfinished[player] = true

	self:_armGuaranteedRoll(player)
	SellNpcManager:SetCustomersGuaranteed(player, true)
	GrillerManager:SetCookWindowStretch(player, TUTORIAL_COOK_WINDOW_STRETCH)
end

-- Wipes an unfinished player's progress on the way out, mutating `playerData` since a replica write would be rejected.
function TutorialManager:_resetProgressIfUnfinished(playerData: { [string]: any })
	if playerData.TutorialCompleted then
		return
	end

	local template = DataSettings.PlayerDataTemplate
	for _, key in PROGRESS_RESET_KEYS do
		playerData[key] = deepCopy(template[key])
	end
end

-- Marks the tutorial done: drops every rig, flags the data, and hands off to the reward.
function TutorialManager:FinishTutorialForPlayer(player: Player)
	if not self._unfinished[player] then
		return
	end

	self:_logStep(player, "Finish")

	self._unfinished[player] = nil
	SellNpcManager:SetCustomersGuaranteed(player, false)

	-- Stamped per cook, so dropping it leaves a running cook on the widened window it started with
	GrillerManager:SetCookWindowStretch(player, nil)

	PlayerDataManager:SetPlayerDataKey(player, "TutorialCompleted", true)

	self:_grantCompletionReward(player)

	-- Held back all run so the sequence's own structures can't be removed. Handed over here, not next spawn
	BuildManager:GivePickupTool(player)
	-- Silent -- the client's confetti and finish are playing over this, and a second sound is just noise
	NotificationManager:NotifyNormal(player, {
		Text = "You unlocked the Hammer! Equip it to move things on your base",
		Duration = 5,
	})
end

-- Hands over the completion reward: a crate crashed into their base, delayed so the finish settles first.
function TutorialManager:_grantCompletionReward(player: Player)
	task.delay(TUTORIAL_CRATE_DELAY, function()
		if player:IsDescendantOf(Players) then
			TutorialCrateManager:SpawnFor(player, true)
		end
	end)
end

-- Logs a funnel step by Key, resolving its index and name against the running variant.
function TutorialManager:_logStep(player: Player, key: string)
	-- Unassigned means no tutorial in progress, so there's no funnel for this to belong to
	local variant = player:GetAttribute(VARIANT_KEY)
	if not variant then
		return
	end

	local step = FUNNEL_STEP_INDEX[variant][key]
	if not step then
		warn(`TutorialManager:_logStep -> unknown funnel step key "{tostring(key)}" for variant "{variant}"`)
		return
	end

	-- Forward only, so a beat the client re-enters isn't reported twice
	if step <= (self._maxFunnelStep[player] or 0) then
		return
	end
	self._maxFunnelStep[player] = step

	self.OnFunnelStep:Fire(player, variant, step, VARIANT_FUNNEL_STEPS[variant][step].Name)

	PlayerDataManager:SetPlayerDataKey(player, "TutorialStep", step)
end

function TutorialManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	IngredientRollingManager = require(script.Parent.IngredientRollingManager)
	SellNpcManager = require(script.Parent.SellNpcManager)
	GrillerManager = require(script.Parent.GrillerManager)
	TutorialCrateManager = require(script.Parent.TutorialCrateManager)
	BuildManager = require(script.Parent.BuildManager)
	NotificationManager = require(script.Parent.NotificationManager)
	StickManager = require(script.Parent.StickManager)

	PlayerDataManager:RegisterPreCleanupCallback(function(player: Player, playerData)
		self:_resetProgressIfUnfinished(playerData)

		self._unfinished[player] = nil
		self._maxFunnelStep[player] = nil
		self._setupStarted[player] = nil
	end)
end

function TutorialManager:OnStart()
	self.FinishTutorialEvent:OnServerEvent(function(player: Player)
		self:FinishTutorialForPlayer(player)
	end)

	self.LogStepEvent:OnServerEvent(function(player: Player, key: string)
		self:_logStep(player, key)
	end)

	-- Re-armed off the pull itself, the pin being consumed by the one it lands on
	IngredientRollingManager.OnIngredientRolled:Connect(function(player: Player)
		self:_armGuaranteedRoll(player)
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(function()
			self:_setupTutorial(player)
		end)
	end)

	-- Covers players already here on a hot-reload, or a join that beat the connect above
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_setupTutorial(player)
		end)
	end
end

return TutorialManager
