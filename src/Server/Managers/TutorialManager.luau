-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ConfigService = game:GetService("ConfigService")
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
local BuildManager
local NotificationManager
local StickManager

--[[
    The server half of the onboarding. The sequence itself lives entirely on the client
    (TutorialController) -- everything here is the handful of things a client can't be trusted with or
    can't see: what the tutorial's first pull lands on, whether the customer it's promised turns up,
    whether the hammer has been earned yet, the finished flag, and the funnel.

    Nothing here drives the client. There's no "start" handshake and no per-step acknowledgement: the
    client reads TutorialCompleted off its own replica, waits for the variant attribute set below, and
    runs that one, reporting the steps it passes. Which variant that is comes from an experience config,
    so the one thing this side adds is resolving that and publishing it where the client can see it. The
    rigs below (the guaranteed roll, the guaranteed customer, the widened cook window) are armed for
    the whole time a player is unfinished rather than switched on at the step that needs them, so none
    of them depends on a client message arriving at the right moment.
]]

-- The experience config (Creator Hub -> Configs) holding which onboarding a player runs, and what any
-- experiment on that key serves alternative values for. Its value is a variant name: a folder under
-- TutorialController/Sequence and a key in VARIANT_FUNNEL_STEPS.
--
-- Doubles as the player attribute the resolved variant is published on, carrying the same thing to the
-- client. An attribute rather than player data: the assignment comes from outside and lasts a session,
-- and ConfigService gives the same player the same answer next time anyway.
local VARIANT_KEY = "TutorialVariant"

-- What runs when ConfigService can't answer -- in Studio, where it has nothing to answer with, and on a
-- server that can't reach it -- and when the config names a variant this build has no steps for.
local FALLBACK_VARIANT = "B"

-- What the tutorial's roll is pinned to. Rolled ingredients run from $75 to $400,000 and the player
-- starts with $100, so an unpinned first pull could land something they can't buy and the tutorial
-- would have nowhere to go. Corn is $75, which with the $5 stick leaves $20 -- the cheap tier is the
-- only tier with any headroom at all here.
local TUTORIAL_INGREDIENT_ID = "Corn"

-- The stick variant B hands over at the start, instead of sending the player shopping for one. The same
-- tier A has them buy: cheapest at $5, and the only one that restocks every window, so a player who ends
-- up buying it after all can never find it sold out.
local TUTORIAL_STICK_ID = "WoodenStick"

-- The variant that starts the player with a stick and moves the shop trip to the end of the run.
local STICK_FIRST_VARIANT = "B"

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
	"Plots",
	"Structures",

	-- Both halves of a build, since a structure is only ever in one of two places. Wiping only the
	-- placed ones would leave a player who put their griller down and quit with a base that has none
	-- and a backpack that has none either -- and the first beat of the tutorial waits on a tool that
	-- could then never appear.
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

-- Ordered onboarding funnel, one list per tutorial variant, since a variant that reorders or drops beats
-- would otherwise report against step numbers that mean something else. Each beat of the tutorial logs
-- one of these keys (the client fires the Key, the index and Name are resolved here) so we can see where
-- players drop off. Deliberately finer than the sequence list -- the stick-shop beat reports both
-- SelectStick and BuyStick, because "opened the shop and never picked anything" and "picked one and never
-- bought it" are different failures. The two build beats split the same way, for the same reason: never
-- taking the tool out is a different kind of stuck from taking it out and never finding somewhere to put
-- the thing down.
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
		{ Key = "StartCook", Name = "Start Cooking" },
		{ Key = "StopCook", Name = "Finish Cooking" },
		{ Key = "TakeFromGrill", Name = "Take BBQ Off Griller" },
		{ Key = "PlaceOnSellStand", Name = "Place BBQ On Sell Stand" },
		{ Key = "AcceptOffer", Name = "Accept Customer Offer" },
		{ Key = "Finish", Name = "Tutorial Finished" },
	},

	-- The same beats as A in a different order: the player is handed a stick at the start, so the four
	-- shop-trip beats move from the middle to the end, where the sale has just left them with none. Keys
	-- and names are A's untouched -- only the order differs, which is the whole point of the comparison.
	--
	-- This order has to match what Sequence/B actually fires. _logStep only reports forward progress, so a
	-- list that disagrees with the client silently drops every beat resolving to a lower index.
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
		{ Key = "StartCook", Name = "Start Cooking" },
		{ Key = "StopCook", Name = "Finish Cooking" },
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

-- Key -> index lookup, per variant. Which one a log resolves against depends on the player, so both are
-- built up front rather than picking one here.
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

	-- [player] = true once _setupTutorial has claimed them. Both of its entry points can fire for the
	-- same player, and the stick grant it can make isn't something to do twice.
	_setupStarted = {},

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

-- Resolves which onboarding this player runs and publishes it for the client to pick up. Reading the
-- config is what enrols them in any experiment on that key, so this is only ever reached for a player
-- who still has the tutorial ahead of them.
-- @param player: A player who still has the tutorial ahead of them
-- @returns the variant they were assigned
function TutorialManager:_assignVariant(player: Player): string
	-- Yields, and in an experience with no configs at all it hangs before erroring outright -- so this
	-- failing is the ordinary case in Studio, not a rare one.
	local fetched, snapshot = pcall(function()
		return ConfigService:GetConfigForPlayerAsync(player)
	end)
	local assigned = fetched and snapshot:GetValue(VARIANT_KEY)

	-- A variant the config names but this build has no steps for would quietly run the fallback while the
	-- experiment went on counting them in the arm they were assigned, which reads as that arm performing
	-- exactly like the fallback. Nothing else would show it, so say it here.
	if assigned and not VARIANT_FUNNEL_STEPS[assigned] then
		warn(`TutorialManager: config "{VARIANT_KEY}" served unknown variant "{tostring(assigned)}"`)
	end

	local variant = if VARIANT_FUNNEL_STEPS[assigned] then assigned else FALLBACK_VARIANT
	player:SetAttribute(VARIANT_KEY, variant)

	return variant
end

-- Picks the player up as unfinished (or leaves them alone if they've already done the tutorial) and
-- arms both rigs for the whole run.
function TutorialManager:_setupTutorial(player: Player)
	-- PlayerAdded and the OnStart sweep can both land on the same player, and the grant below would hand
	-- over two sticks if they did. Claimed before the first yield, so a second call can't get past here
	-- while the first is still waiting on data.
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

	-- After the completed check, never before it: reading the config enrols the player in whatever
	-- experiment is running, and someone who finished onboarding long ago can't be affected by it.
	local variant = self:_assignVariant(player)

	-- The config fetch yields, and can sit there a while before giving up.
	if not player:IsDescendantOf(Players) then
		return
	end

	-- B opens with a stick in hand rather than a trip to the shop for one, so the run can reach a sale
	-- before it sends the player anywhere. Left in the bag rather than equipped: the first beat asks them
	-- to take the griller out, and a stick already in their hands would just get swapped straight back
	-- out before they'd been told it was there.
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

	-- The hammer is held back for the whole run (BuildManager reads the same flag on every spawn), so
	-- a first-time player can't take back down the griller and stand the sequence has just walked them
	-- through putting up -- with the tutorial then waiting forever on structures that no longer exist.
	-- Handed over here rather than left for their next spawn: the beat it belongs to is finishing, and
	-- a reward that turns up after a respawn they may never take reads as nothing having happened.
	BuildManager:GivePickupTool(player)
	-- Silent, unlike every other payout toast: the client is playing its finish over the top of this --
	-- confetti and TutorialComplete -- and a second sound under that is noise rather than a second
	-- reward. The word "Hammer" is coloured by Keywords.Highlight on the way out.
	NotificationManager:NotifyNormal(player, {
		Text = "You unlocked the Hammer! Equip it to move things on your base",
		Duration = 5,
	})
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
-- the index and name are resolved against the running variant's funnel and reported to Analytics.
-- @param player: The player progressing through the tutorial
-- @param key: A funnel step Key from the active variant's FUNNEL_STEPS
function TutorialManager:_logStep(player: Player, key: string)
	-- Unassigned means no tutorial in progress, so there's no funnel for this to belong to.
	local variant = player:GetAttribute(VARIANT_KEY)
	if not variant then
		return
	end

	local step = FUNNEL_STEP_INDEX[variant][key]
	if not step then
		warn(`TutorialManager:_logStep -> unknown funnel step key "{tostring(key)}" for variant "{variant}"`)
		return
	end

	-- The funnel should only ever move forward, so a step the player has already reached is ignored and
	-- only genuine progress is reported.
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
