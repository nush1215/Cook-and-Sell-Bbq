-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Managers
local Managers = script.Parent.Parent.Parent
local PlayerDataManager = require(Managers.PlayerDataManager)
local StickStandManager = require(Managers.StickStandManager)
local EmployeeHutManager = require(Managers.EmployeeHutManager)

-- Shared
local Shared = ReplicatedStorage.Shared
local Sticks = require(Shared.Config.Sticks)
local Ingredients = require(Shared.Config.Ingredients)
local Structures = require(Shared.Config.Structures)
local EmployeeHut = require(Shared.Config.EmployeeHut)
local Employees = require(Shared.Config.Employees)

-- The category, not one model's id, so a second kind of stand is worked here unchanged
local STAND_CATEGORY = "StickStands"

-- Said while hovering with nothing in any hut to build from
local EMPTY_VARIANT = "Empty"

-- The half-stocked stores: sticks with nothing to thread on, or ingredients with nothing to thread them onto
local NO_INGREDIENTS_VARIANT = "NoIngredients"
local NO_STICKS_VARIANT = "NoSticks"

-- Said when the only stands it could work are ones the player is part-way through, so standing about waiting
-- for its turn reads as exactly that rather than as an employee that hasn't spotted a free stand
local YIELDING_VARIANT = "Waiting"

-- How long it waits before looking again when a trip found nothing to do
local RETRY_DELAY = 4

-- Its own, so two makers picking stock in the same frame don't share a sequence
local rng = Random.new()

-- The BBQ maker: draws sticks and ingredients out of a hut's store and builds skewers on stands for the cooker to grill. Its star is how much it carries in one trip -- a poor one walks back for every single ingredient, which is the ladder you can watch rather than read.

--
local BbqMaker = {}

-- Where a fresh maker starts: hanging around the hut. Its work begins and ends at the store
BbqMaker.Initial = "Hover"

-- How much a stand still has room for, or 0 when it's full, cooked, or not something to build on.
local function getRoom(record): number
	if type(record) ~= "table" or record.Cooked then
		return 0
	end

	local stick = Sticks.GetStickFromId(record.StickId)

	return if stick then math.max(stick.Capacity - #record.Ingredients, 0) else 0
end

-- Whether the player has worked this stand recently enough that it's still theirs to finish.
local function isPlayerBuilding(employee, uid: string): boolean
	local touchedAt = StickStandManager:GetPlayerTouchedAt(employee.Player, uid)

	return touchedAt > 0 and os.clock() - touchedAt < Employees.PLAYER_BUILD_COOLDOWN
end

-- The slice of a ranked list a maker of `skill` draws from, richest first. One at worst stars is the whole list.
function BbqMaker.PickRanked(skill: number, ranked: { any })
	if #ranked == 0 then
		return nil
	end

	local top = Employees.InterpolateBySkill(
		Employees.MAKER_PICK_TOP_WORST,
		Employees.MAKER_PICK_TOP_BEST,
		Employees.MAKER_PICK_TOP_GAMMA,
		skill
	)

	-- At least one, so even a perfect employee has something to draw from
	local window = math.max(1, math.floor(#ranked * top))

	return ranked[rng:NextInteger(1, window)]
end

-- What a hut holds, richest first. Value per second of cook time rises with tier throughout the config, so the tier ladder is that ranking and needs no arithmetic.
function BbqMaker.RankStoredIngredients(store): { string }
	local ids = {}

	for ingredientId, amount in store.Ingredients do
		if amount > 0 and Ingredients.GetIngredientFromId(ingredientId) then
			table.insert(ids, ingredientId)
		end
	end

	table.sort(ids, function(left, right)
		local a, b = Ingredients.GetIngredientFromId(left), Ingredients.GetIngredientFromId(right)

		if a.Tier.Index ~= b.Tier.Index then
			return a.Tier.Index > b.Tier.Index
		end

		return a.Price > b.Price
	end)

	return ids
end

-- What a hut holds in sticks, best first. Array order in the config is the tier, and capacity rises with it.
function BbqMaker.RankStoredSticks(store): { string }
	local ids = {}

	for index = #Sticks.GetAllSticks(), 1, -1 do
		local stick = Sticks.Data[index]
		if (store.Sticks[stick.Id] or 0) > 0 then
			table.insert(ids, stick.Id)
		end
	end

	return ids
end

-- The uid of a hut holding something this run needs, or nil. Nearest isn't worth solving: a base has few huts.
local function findStockedHut(employee, data, needsStick: boolean): string?
	for uid, placed in data.Structures do
		if not Structures.IsCategory(placed.Type, EmployeeHut.CATEGORY) then
			continue
		end

		local store = data.HutStorage[uid]
		if not store then
			continue
		end

		if needsStick then
			if #BbqMaker.RankStoredSticks(store) > 0 then
				return uid
			end
		elseif #BbqMaker.RankStoredIngredients(store) > 0 then
			return uid
		end
	end

	return nil
end

-- A stand worth building on: one with room, that the player isn't part-way through themselves. Two passes rather than one, so looking at an empty stand can't leave a claim on it when a part-built one wins. The last return says the only ones it passed over were the player's own, so hovering can say it's standing back rather than looking like it never noticed them.
local function findWorkableStand(employee, data): (string?, boolean, boolean)
	local yielding = false

	-- Part-built first: finishing a stick beats starting another, and a cooker may be waiting on it
	for uid, placed in data.Structures do
		if not Structures.IsCategory(placed.Type, STAND_CATEGORY) or getRoom(data.StickStands[uid]) <= 0 then
			continue
		end

		if isPlayerBuilding(employee, uid) then
			yielding = true
		elseif employee:ClaimStation(uid) then
			return uid, false, false
		end
	end

	for uid, placed in data.Structures do
		if not Structures.IsCategory(placed.Type, STAND_CATEGORY) or type(data.StickStands[uid]) == "table" then
			continue
		end

		if isPlayerBuilding(employee, uid) then
			yielding = true
		elseif employee:ClaimStation(uid) then
			return uid, true, false
		end
	end

	return nil, false, yielding
end

-- Whether `uid` can take what this load holds: a stick wants a bare stand, ingredients want one with room.
local function standFits(data, uid: string, load): boolean
	local record = data.StickStands[uid]

	if load.StickId then
		return type(record) ~= "table"
	end

	return getRoom(record) > 0
end

-- A stand for a load already in hand, so a run whose stand fell through finds another rather than fetching twice.
local function findStandForLoad(employee, data, load): string?
	for uid, placed in data.Structures do
		if not Structures.IsCategory(placed.Type, STAND_CATEGORY) or isPlayerBuilding(employee, uid) then
			continue
		end

		if standFits(data, uid, load) and employee:ClaimStation(uid) then
			return uid
		end
	end

	return nil
end

-- Drifts around the store between jobs, circling the hut rather than tramping through the middle of it.
local function hoverNearStore(employee, now: number, data)
	local hut = employee:GetHomeModel(data)

	if hut then
		employee:StepWander(now, data, function()
			return employee:PickPointAround(hut, Employees.HOVER_RADIUS)
		end)

		return
	end

	-- No hut placed at all, so it keeps to where it spawned instead of roaming the plots
	local home = employee:GetHomePosition(data)
	if home then
		employee:StepWander(now, data, function()
			return employee:PickPointNear(home, Employees.HOVER_RADIUS)
		end)
	end
end

-- Seconds this maker spends putting one item on a stand, off its star.
local function getBuildOverhead(employee): number
	return employee:GetCurveValue(
		Employees.MAKER_BUILD_WORST,
		Employees.MAKER_BUILD_BEST,
		Employees.MAKER_BUILD_GAMMA
	)
end

-- Walks toward a station, giving up on a route it can't finish. Returns the state to move to, or nil to keep walking.
local function walkToStation(employee, now: number, uid: string, arrived: string, dwell: number?): string?
	local model = employee:GetStructureModel(uid)
	if not model then
		employee:ReleaseStations()
		return "Hover"
	end

	local result = employee:StepWalk(now, employee._walkTarget or employee:GetApproachPosition(model))
	if result == "arrived" then
		employee:FaceTowards(model:GetPivot().Position)

		if dwell then
			employee:Dwell(now, dwell)
		end

		return arrived
	end

	if result == "timeout" then
		employee:ReleaseStations()
		return "Hover"
	end

	return nil
end

-- Hangs around the store waiting for something to build. Everything routes through here, so a rejoin mid-trip picks its load straight back up.
BbqMaker.Hover = function(employee, now: number): string?
	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
	if not data then
		return nil
	end

	local load = employee.Record.Load

	-- A load with nothing left in it is a run that ended outside Build; dropped rather than carried forever,
	-- since nothing empty-handed can ever satisfy the carrying branch below
	if load and not load.StickId and #load.Ingredients == 0 then
		employee:SetLoad(nil)
		load = nil
	end

	-- Already carrying: it needs somewhere to put this, never a second trip to the store
	if load then
		if employee._buildUid then
			return "ToBench"
		end

		if employee:ShouldPoll(now) then
			employee._buildUid = findStandForLoad(employee, data, load)

			if employee._buildUid then
				return "ToBench"
			end
		end

		-- Nowhere to put it yet, so it waits with its hands full rather than fetching more on top
		hoverNearStore(employee, now, data)

		return nil
	end

	if employee:ShouldPoll(now) then
		local standUid, needsStick, yielding = findWorkableStand(employee, data)

		if standUid then
			local hutUid = findStockedHut(employee, data, needsStick)

			if hutUid then
				employee._buildUid = standUid
				employee._hutUid = hutUid

				return "ToStore"
			end

			-- Nothing stocked to build it with, so the stand goes back for the player or another maker
			employee:ReleaseStations()
			employee:DelayPoll(now, RETRY_DELAY)
		end

		-- Read every poll rather than only on a failed pairing, so what's holding it up is always what it
		-- talks about: half a store is worth naming, and so is deliberately standing off a stand
		local hasSticks = findStockedHut(employee, data, true) ~= nil
		local hasIngredients = findStockedHut(employee, data, false) ~= nil

		if not hasSticks and not hasIngredients then
			employee:SetVariant(EMPTY_VARIANT)
		elseif not hasIngredients then
			employee:SetVariant(NO_INGREDIENTS_VARIANT)
		elseif not hasSticks then
			employee:SetVariant(NO_STICKS_VARIANT)
		else
			employee:SetVariant(if yielding then YIELDING_VARIANT else nil)
		end
	end

	hoverNearStore(employee, now, data)

	return nil
end

BbqMaker.ToStore = function(employee, now: number): string?
	return walkToStation(employee, now, employee._hutUid, "Fetch", employee:GetPickupOverhead())
end

-- Takes a load out of the hut. Each item is withdrawn one at a time and banked into Load as it goes, so a hut picked up mid-fetch costs the rest of the trip rather than what's already in hand.
BbqMaker.Fetch = function(employee, _now: number): string?
	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
	local store = data and data.HutStorage[employee._hutUid]

	if not store then
		employee:ReleaseStations()
		return "Hover"
	end

	local record = data.StickStands[employee._buildUid]
	local load = { HutUid = employee._hutUid, Ingredients = {} }

	-- An empty stand needs a stick under it before anything can go on
	if type(record) ~= "table" then
		local stickId = BbqMaker.PickRanked(employee.Record.Skill, BbqMaker.RankStoredSticks(store))

		if not stickId or not EmployeeHutManager:TakeFromStore(employee.Player, employee._hutUid, "Sticks", stickId) then
			employee:ReleaseStations()
			return "Hover"
		end

		load.StickId = stickId
	end

	-- Room left on the stick, capped by what this one can carry in a trip -- the whole ladder, in one line
	local room = if load.StickId then Sticks.GetStickFromId(load.StickId).Capacity else getRoom(record)
	local carry = Employees.GetTierFromStars(Employees.MAKER_CARRY_MARKS, employee:GetStars())

	for _ = 1, math.min(room, carry) do
		local ingredientId = BbqMaker.PickRanked(employee.Record.Skill, BbqMaker.RankStoredIngredients(store))
		if not ingredientId then
			break
		end

		if not EmployeeHutManager:TakeFromStore(employee.Player, employee._hutUid, "Ingredients", ingredientId) then
			break
		end

		table.insert(load.Ingredients, ingredientId)
	end

	-- Nothing came out and no stick to place, so there was nothing here worth the walk
	if not load.StickId and #load.Ingredients == 0 then
		employee:ReleaseStations()
		return "Hover"
	end

	employee:SetLoad(load)
	employee:Say("Fetch")

	return "ToBench"
end

BbqMaker.ToBench = function(employee, now: number): string?
	return walkToStation(employee, now, employee._buildUid, "Build", getBuildOverhead(employee))
end

-- Threads the load onto the stand, one item per dwell. One at a time is what makes each ingredient drop in and sound like a player put it there.
BbqMaker.Build = function(employee, now: number): string?
	local load = employee.Record.Load
	if not load then
		employee:ReleaseStations()
		return "Hover"
	end

	-- Taken over by the player, or picked up, while this was walking
	if isPlayerBuilding(employee, employee._buildUid) then
		employee:Say("WaitTurn")
		employee:ReleaseStations()
		return "Hover"
	end

	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)

	-- Hands empty, before any question of whether the stand still fits: the last item going on is what
	-- fills the stick, so asking for room here would strand the load on the run that actually succeeded
	if not load.StickId and #load.Ingredients == 0 then
		local record = data and data.StickStands[employee._buildUid]

		employee:SetLoad(nil)

		-- A stick with room left earns another trip; a finished one is the cooker's now
		if getRoom(record) > 0 then
			local hutUid = findStockedHut(employee, data, false)

			if hutUid then
				employee._hutUid = hutUid
				return "ToStore"
			end
		elseif type(record) == "table" then
			employee:Say("BuildDone", record.StickId)
		end

		employee:ReleaseStations()

		return "Hover"
	end

	-- Refused for good rather than for a moment: the stand filled up, got cooked, or was taken away while
	-- this walked over. Holding the load, it goes looking for another stand instead of retrying forever
	if data and not standFits(data, employee._buildUid, load) then
		employee:ReleaseStations()
		return "Hover"
	end

	-- The stick first: nothing can go on a bare stand
	if load.StickId then
		if not StickStandManager:PlaceStickOnStand(employee.Player, employee._buildUid, load.StickId) then
			return nil
		end

		load.StickId = nil
		employee:SetLoad(load)

		-- Paced only while something's still in hand, or it stands about "making BBQ" with nothing to place
		if #load.Ingredients > 0 then
			employee:Dwell(now, getBuildOverhead(employee))
		end

		return nil
	end

	local ingredientId = load.Ingredients[1]

	-- Refused means the owner is mid-toggle somewhere, so it holds the item and tries again next tick
	if StickStandManager:AddIngredientToStand(employee.Player, employee._buildUid, ingredientId) then
		table.remove(load.Ingredients, 1)
		employee:SetLoad(load)

		-- Same rule: no wait after the one that empties its hands, so the finished line lands on the finish
		if #load.Ingredients > 0 then
			employee:Dwell(now, getBuildOverhead(employee))
		end
	end

	return nil
end

return BbqMaker
