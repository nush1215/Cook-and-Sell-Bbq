-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Network = require(ReplicatedStorage.Shared.Network)

-- Read-only access to the data template so the wipe below resets keys to their real defaults rather
-- than duplicating them here.
local DataSettings = require(script.Parent.PlayerDataManager.DataSettings)

-- Managers
local PlayerDataManager
local IngredientRollingManager
local SellNpcManager
local GrillerManager
local TutorialCrateManager

--[[
    The server half of the onboarding. The sequence itself lives entirely on the client
    (TutorialController) -- everything here is the handful of things a client can't be trusted with or
    can't see: what the tutorial's first pull lands on, whether the customer it's promised turns up,
    the finished flag, and the funnel.

    Nothing here drives the client. There's no "start" handshake and no per-step acknowledgement: the
    client reads TutorialCompleted off its own replica and runs, reporting the steps it passes. The
    rigs below (the guaranteed roll, the guaranteed customer, the widened cook window) are armed for
    the whole time a player is unfinished rather than switched on at the step that needs them, so none
    of them depends on a client message arriving at the right moment.
]]

-- What the tutorial's roll is pinned to. Rolled ingredients run from $75 to $400,000 and the player
-- starts with $500, so an unpinned first pull could land something they can't buy and the tutorial
-- would have nowhere to go. Any of the cheap tier works here.
local TUTORIAL_INGREDIENT_ID = "Corn"

-- How many times longer the perfect cook window runs while they're being taught it. The window is a
-- quarter of the bar, and on the pinned ingredient above that's about two seconds -- too sharp to ask
-- of someone meeting the mechanic for the first time, on a touchscreen, having just been told what a
-- griller is. At 3x it's about six, which still asks them to watch the bar and react. Nothing else
-- about the cook moves: the run up to the window and the burn past it keep their normal timings.
local TUTORIAL_COOK_WINDOW_STRETCH = 3

-- Beat between the tutorial ending and its reward crate crashing in. The crash takes the player's
-- camera, so it waits for the finish to land -- the rigs dropping, the flag written, the last banner
-- gone -- rather than talking over it.
local TUTORIAL_CRATE_DELAY = 2

-- Gameplay-progress keys wiped back to template defaults when a player leaves without having finished
-- the tutorial, so onboarding always restarts from scratch on a base in its starting state. Everything
-- not listed here is preserved -- notably real-money purchases, purchase logs, redeemed codes, the
-- group reward and accumulated playtime, none of which the tutorial should be able to take back.
local PROGRESS_RESET_KEYS = {
	"Currency",
	"Unlocks",
	"Ingredients",
	"PendingRolls",
	"IngredientIndex",
	"Sticks",
	"StickStands",
	"SkewerStand",
	"FilledSticks",
	"Grillers",
	"GrillerCookSpeed",
	"SauceDispensers",
	"Sauces",
	"Crates",
	"TutorialCrateTimer",
	"StickShop",
	"LastRichVisit",
	"SaleRefusals",
	"SeenHaggle",
	"TutorialStep",

	-- The lifetime counters go too: they're the record of what the player has done, and a run that's
	-- being thrown away shouldn't leave a trail in the leaderboards or the stall's reputation.
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

-- Ordered onboarding funnel. Each beat of the tutorial logs one of these keys (the client fires the
-- Key, the index and Name are resolved here) so we can see where players drop off. Deliberately finer
-- than the sequence list -- the stick-shop beat reports both SelectStick and BuyStick, because "opened
-- the shop and never picked anything" and "picked one and never bought it" are different failures.
local FUNNEL_STEPS = {
	{ Key = "Start", Name = "Tutorial Started" },
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
	{ Key = "StartCook", Name = "Start Cooking" },
	{ Key = "StopCook", Name = "Finish Cooking" },
	{ Key = "TakeFromGrill", Name = "Take BBQ Off Griller" },
	{ Key = "PlaceOnSellStand", Name = "Place BBQ On Sell Stand" },
	{ Key = "AcceptOffer", Name = "Accept Customer Offer" },
	{ Key = "Finish", Name = "Tutorial Finished" },
}

-- Key -> index lookup
local FUNNEL_STEP_INDEX = {}
for index, step in FUNNEL_STEPS do
	FUNNEL_STEP_INDEX[step.Key] = index
end

--
local TutorialManager = {
	FinishTutorialEvent = Network.Event("FinishTutorial"),
	LogStepEvent = Network.Event("LogTutorialStep"),

	-- (player, stepIndex, stepName) when a player reaches a new onboarding step.
	OnFunnelStep = Signal.new(),

	_unfinished = {}, -- [player] = true while their tutorial is still running

	-- Furthest funnel step index each player has logged, so a step reported twice (a beat the client
	-- re-enters) isn't re-reported to the funnel.
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

-- Pins the player's next pull to the tutorial ingredient. Called once when they're picked up as
-- unfinished and again after every pull, because the pin is worth exactly one roll -- so a player who
-- rolls, walks away without buying, and rolls again still can't land something they can't afford.
function TutorialManager:_armGuaranteedRoll(player: Player)
	if not self._unfinished[player] then
		return
	end

	IngredientRollingManager:ForceNextIngredient(player, TUTORIAL_INGREDIENT_ID)
end

-- Picks the player up as unfinished (or leaves them alone if they've already done the tutorial) and
-- arms both rigs for the whole run.
function TutorialManager:_setupTutorial(player: Player)
	local hasData, completed = PlayerDataManager:GetPlayerDataKey(player, "TutorialCompleted"):await()
	if not hasData or completed then
		return
	end

	-- They may have left while the data read was in flight.
	if not player:IsDescendantOf(Players) then
		return
	end

	self._unfinished[player] = true

	self:_armGuaranteedRoll(player)
	SellNpcManager:SetCustomersGuaranteed(player, true)
	GrillerManager:SetCookWindowStretch(player, TUTORIAL_COOK_WINDOW_STRETCH)
end

-- Wipes an unfinished player's gameplay progress back to template defaults, mutating the data table
-- directly because this runs on the way out, when the player may already be gone and a replica write
-- would be rejected. Their next session then loads a profile that's already back at the start.
-- @param playerData: The live data table, saved as-is once every pre-cleanup callback has run
function TutorialManager:_resetProgressIfUnfinished(playerData: { [string]: any })
	if playerData.TutorialCompleted then
		return
	end

	local template = DataSettings.PlayerDataTemplate
	for _, key in PROGRESS_RESET_KEYS do
		playerData[key] = deepCopy(template[key])
	end
end

-- Marks the tutorial done: drops every rig, flags the data so it never runs again, and hands off to
-- the completion reward.
function TutorialManager:FinishTutorialForPlayer(player: Player)
	if not self._unfinished[player] then
		return
	end

	self:_logStep(player, "Finish")

	self._unfinished[player] = nil
	SellNpcManager:SetCustomersGuaranteed(player, false)

	-- The stretch is stamped onto each cook as it's lit, so dropping it here leaves a cook already
	-- running on the widened window it was started with rather than snapping its bar mid-run.
	GrillerManager:SetCookWindowStretch(player, nil)

	PlayerDataManager:SetPlayerDataKey(player, "TutorialCompleted", true)

	self:_grantCompletionReward(player)
end

-- Hands the player whatever finishing the tutorial is worth: a crate, crashed into their base like a
-- meteor, which holds out behind a countdown before it can be opened. Delayed a beat so the finish
-- itself -- the rigs coming down, the flag being written -- is fully settled before the crash takes
-- their camera.
function TutorialManager:_grantCompletionReward(player: Player)
	task.delay(TUTORIAL_CRATE_DELAY, function()
		if player:IsDescendantOf(Players) then
			TutorialCrateManager:SpawnFor(player)
		end
	end)
end

-- Logs which onboarding funnel step the player has reached. The client fires the Key as it progresses;
-- the index and name are resolved here and reported for the Analytics onboarding funnel.
-- @param player: The player progressing through the tutorial
-- @param key: A funnel step Key from FUNNEL_STEPS
function TutorialManager:_logStep(player: Player, key: string)
	local step = FUNNEL_STEP_INDEX[key]
	if not step then
		warn(`TutorialManager:_logStep -> unknown funnel step key "{tostring(key)}"`)
		return
	end

	-- The funnel should only ever move forward, so a step the player has already reached is ignored and
	-- only genuine progress is reported.
	if step <= (self._maxFunnelStep[player] or 0) then
		return
	end
	self._maxFunnelStep[player] = step

	self.OnFunnelStep:Fire(player, step, FUNNEL_STEPS[step].Name)

	PlayerDataManager:SetPlayerDataKey(player, "TutorialStep", step)
end

function TutorialManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	IngredientRollingManager = require(script.Parent.IngredientRollingManager)
	SellNpcManager = require(script.Parent.SellNpcManager)
	GrillerManager = require(script.Parent.GrillerManager)
	TutorialCrateManager = require(script.Parent.TutorialCrateManager)

	PlayerDataManager:RegisterPreCleanupCallback(function(player: Player, playerData)
		self:_resetProgressIfUnfinished(playerData)

		self._unfinished[player] = nil
		self._maxFunnelStep[player] = nil
	end)
end

function TutorialManager:OnStart()
	self.FinishTutorialEvent:OnServerEvent(function(player: Player)
		self:FinishTutorialForPlayer(player)
	end)

	self.LogStepEvent:OnServerEvent(function(player: Player, key: string)
		self:_logStep(player, key)
	end)

	-- The pin is consumed by the pull it lands on, so re-arm off the pull itself rather than trying to
	-- guess when the tutorial's roll happens. At one unlocked stand this fires once per pull.
	IngredientRollingManager.OnIngredientRolled:Connect(function(player: Player)
		self:_armGuaranteedRoll(player)
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(function()
			self:_setupTutorial(player)
		end)
	end)

	-- Players already here when this loads (a server hot-reload, or a join that beat the connect above).
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_setupTutorial(player)
		end)
	end
end

return TutorialManager
