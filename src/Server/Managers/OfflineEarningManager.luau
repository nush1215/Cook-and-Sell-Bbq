-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local StickModel = require(Shared.StickModel)
local RandomUtil = require(Shared.RandomUtil)
local Sticks = require(Shared.Config.Sticks)
local Structures = require(Shared.Config.Structures)
local CookStates = require(Shared.Config.CookStates)
local SellNpc = require(Shared.Config.SellNpc)
local EarlyBoost = require(Shared.Config.EarlyBoost)
local Employees = require(Shared.Config.Employees)
local EmployeeHut = require(Shared.Config.EmployeeHut)
local Rating = require(Shared.Config.Rating)
local OfflineEarnings = require(Shared.Config.OfflineEarnings)

--
local PlayerDataManager
local CurrencyManager
local GrillerManager
local SkewerStandManager
local BaseManager
local BbqMaker
local Cooker
local Seller

-- The categories the stations are placed under, matched to what each role works
local STAND_CATEGORY = "StickStands"
local GRILLER_CATEGORY = "Grillers"

local STOP = OfflineEarnings.STOP_REASONS

-- Its own, so a pass rolling cooks and offers doesn't share a sequence with anything live
local rng = Random.new()

-- The workers keep at it while their owner is away. On the next join the time away is run through the same curves and prices the live roster steps by, the chest is spent, leftovers are left where they stood, and the money waits on the welcome-back panel to be claimed. Runs before the profile reaches anything else, so the base renders whatever the workers left -- see docs/balance.md.

--
local OfflineEarningManager = {
	ShowOfflineEarningsEvent = Network.Event("ShowOfflineEarnings"), -- server -> client ({ Amount, BbqSold, SecondsAway })
	ClaimOfflineEarningsEvent = Network.Event("ClaimOfflineEarnings", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 2 },
	}),
	OfflineEarningsClaimResultEvent = Network.Event("OfflineEarningsClaimResult"), -- server -> client ({ Success, Amount })

	OnOfflineEarningsSimulated = Signal.new(), -- (player, report)
	OnOfflineEarningsClaimed = Signal.new(), -- (player, report, payout)

	_pendingClaims = {}, -- [player] = report, held until it's claimed or paid on the last save
	_claiming = {}, -- [player] = true across a claim's read -> write window
}

-- Removes and returns the smallest time in `times`: the next moment a buffer or a pair of hands frees up.
local function popEarliest(times: { number }): number
	local earliest = 1

	for index = 2, #times do
		if times[index] < times[earliest] then
			earliest = index
		end
	end

	return table.remove(times, earliest)
end

-- The worker in `workers` free soonest, or nil with none equipped.
local function earliestFree(workers)
	local best

	for _, worker in workers do
		if not best or worker.FreeAt < best.FreeAt then
			best = worker
		end
	end

	return best
end

-- A roster record's numbers for the pass, every one off the same curve the live worker steps by.
local function buildWorker(record)
	local skill = record.Skill
	local stars = Rating.ToStars(skill)

	local function curve(worst: number, best: number, gamma: number): number
		return Employees.InterpolateBySkill(worst, best, gamma, skill)
	end

	return {
		Skill = skill,
		FreeAt = 0,
		Notice = curve(Employees.NOTICE_WORST, Employees.NOTICE_BEST, Employees.NOTICE_GAMMA),
		-- A typical station-to-station leg at this one's own pace, standing in for the base's layout
		WalkLeg = OfflineEarnings.WALK_LEG_STUDS
			/ curve(Employees.WALK_SPEED_WORST, Employees.WALK_SPEED_BEST, Employees.WALK_SPEED_GAMMA),
		Pickup = curve(Employees.PICKUP_OVERHEAD_WORST, Employees.PICKUP_OVERHEAD_BEST, Employees.PICKUP_OVERHEAD_GAMMA),
		Place = curve(Employees.PLACE_OVERHEAD_WORST, Employees.PLACE_OVERHEAD_BEST, Employees.PLACE_OVERHEAD_GAMMA),
		Build = curve(Employees.MAKER_BUILD_WORST, Employees.MAKER_BUILD_BEST, Employees.MAKER_BUILD_GAMMA),
		Decide = curve(Employees.SELL_DECIDE_WORST, Employees.SELL_DECIDE_BEST, Employees.SELL_DECIDE_GAMMA),
		Carry = Employees.GetTierFromStars(Employees.MAKER_CARRY_MARKS, stars),
		GrillTier = Employees.GetTierFromStars(Employees.GRILL_MARKS, stars),
		InFlight = {}, -- a cooker's cooks still on the go, by when each is put out to sell
	}
end

-- Writes `value` at `path` straight into `data`, for the join-time pass where no replica exists yet.
local function writeDirect(data, path: { string }, value)
	local container = data

	for index = 1, #path - 1 do
		container = container[path[index]]
	end

	container[path[#path]] = value
end

-- Runs the equipped workers through `horizon` seconds of the base as it was saved. Pure: `data` is only read, and everything the workers moved comes back in the result for ApplyOfflineEarnings to write.
function OfflineEarningManager:SimulateOfflineEarnings(data, horizon: number)
	local makers, cookers, sellers = {}, {}, {}

	for _, record in data.Employees do
		if not record.Slot then
			continue
		end

		local group = if record.Role == Employees.ROLES.BBQ_MAKER
			then makers
			elseif record.Role == Employees.ROLES.COOKER then cookers
			else sellers
		table.insert(group, buildWorker(record))
	end

	-- The stations, and what was left mid-pipeline on them
	local huts = {} -- { Uid, Sticks, Ingredients }, working copies the picks are drawn down against
	local grills = {} -- { Uid, FreeAt }
	local seeds = {} -- filled stick stands and lit grills, finished before anything new is started
	local standCapacity = 0 -- stands a maker can build on: bare ones, and filled ones once they're collected
	local onStands = {} -- when each skewer waiting on a stand is collected, so a full row holds the maker
	local onStand = {} -- when each BBQ on the sell stand sells, so a full stand holds the cooker

	for uid, placed in data.Structures do
		if Structures.IsCategory(placed.Type, EmployeeHut.CATEGORY) then
			local store = data.HutStorage[uid]
			if store then
				table.insert(huts, {
					Uid = uid,
					Sticks = table.clone(store.Sticks),
					Ingredients = table.clone(store.Ingredients),
				})
			end
		elseif Structures.IsCategory(placed.Type, STAND_CATEGORY) then
			local record = data.StickStands[uid]

			if type(record) ~= "table" then
				standCapacity += 1
			elseif not record.Cooked then
				-- Part-built stands are the player's to finish, so only a full stick is picked up
				local stick = Sticks.GetStickFromId(record.StickId)
				if stick and #record.Ingredients >= stick.Capacity then
					standCapacity += 1
					table.insert(seeds, {
						Source = "Stand",
						Uid = uid,
						StickId = record.StickId,
						Ingredients = table.clone(record.Ingredients),
					})
				end
			end
		elseif Structures.IsCategory(placed.Type, GRILLER_CATEGORY) then
			local record = data.Grillers[uid]
			local grill = { Uid = uid, FreeAt = 0 }
			table.insert(grills, grill)

			if record and record.Cooking then
				table.insert(seeds, {
					Source = "Grill",
					Uid = uid,
					Grill = grill,
					StickId = record.StickId,
					Ingredients = table.clone(record.Ingredients),
					Cook = record, -- the saved stamps: the bar's length, the banked run and the grill's own warps
				})
			elseif record then
				-- Something unlit or already cooked sits on it, which is the player's to deal with
				grill.FreeAt = math.huge
			end
		end
	end

	-- Customers as an established stall meets them, with the new player's head start folded in
	local totalEarned = data.TotalEarned
	local spawnMean = (SellNpc.SPAWN_DELAY_MIN + SellNpc.SPAWN_DELAY_MAX) / 2 * EarlyBoost.GetSpawnDelayScale(totalEarned)
	local decideMean = (SellNpc.DECIDE_DURATION_MIN + SellNpc.DECIDE_DURATION_MAX) / 2
	local retryMean = (SellNpc.RETRY_DELAY_MIN + SellNpc.RETRY_DELAY_MAX) / 2
	local interested = 1 - (1 - SellNpc.INTERESTED_CHANCE) * EarlyBoost.GetDeclineScale(totalEarned)

	-- Sells one BBQ off the stand from `availableAt`: customers keep coming until one buys, each answered by the seller free soonest, exactly as the live seller weighs a push. Unsold inside the window reads as never.
	local function sell(item, availableAt: number)
		item.SoldAt = math.huge

		if #sellers == 0 then
			return
		end

		local record = item.Record
		local value = StickModel.GetSellValue(record)
		local state = CookStates.GetStateFromId(StickModel.GetCookStateId(record))
		local now = availableAt

		while now < horizon do
			now += spawnMean + OfflineEarnings.CUSTOMER_WALK_SECONDS + decideMean

			if rng:NextNumber() >= interested then
				now += SellNpc.LEAVE_DELAY + retryMean
				continue
			end

			-- The same shape SellNpcManager negotiates on, so the seller's rule reads it unchanged
			local negotiation = {
				value = value,
				offer = math.round(value * rng:NextNumber(state.OfferMin, state.OfferMax)),
				counterCap = state.CounterCap,
				counterChance = state.CounterChance,
				counterRounds = 0,
				maxCounterRounds = SellNpc.MAX_COUNTER_ROUNDS,
				counterIncreaseMin = SellNpc.COUNTER_INCREASE_MIN,
				counterIncreaseMax = SellNpc.COUNTER_INCREASE_MAX,
			}

			while true do
				local seller = earliestFree(sellers)
				now = math.max(now, seller.FreeAt) + seller.Decide
				seller.FreeAt = now

				if not Seller.ShouldPush(seller.Skill, negotiation) then
					item.SoldAt = now
					item.Offer = negotiation.offer
					return
				end

				-- A push that misses sends the customer off, and the BBQ goes back out for the next one
				if not RandomUtil.RollChance(negotiation.counterChance, rng) then
					now += SellNpc.LEAVE_DELAY + retryMean
					break
				end

				local headroom = value * negotiation.counterCap - negotiation.offer
				negotiation.counterRounds += 1
				negotiation.offer = math.round(
					negotiation.offer
						+ headroom * rng:NextNumber(negotiation.counterIncreaseMin, negotiation.counterIncreaseMax)
				)
				negotiation.counterChance *= SellNpc.COUNTER_CHANCE_FALLOFF
			end
		end
	end

	-- Carries a cooked BBQ from the grill to the sell stand, waiting on a slot if the stand is full, and sells it.
	local function deliver(item, cooker, readyAt: number)
		local deliverAt = readyAt + cooker.Pickup + cooker.WalkLeg + cooker.Place

		if #onStand >= SkewerStandManager.MAX_SKEWERS then
			deliverAt = math.max(deliverAt, popEarliest(onStand))
		end

		item.DeliverAt = deliverAt
		sell(item, deliverAt)
		table.insert(onStand, item.SoldAt)
	end

	-- The record a settled cook leaves, minted like a live pull so the stand and the customer treat it the same.
	local function settleCook(item, grillUid: string, barAtPull: number, cookTime: number)
		item.Record = {
			Uid = HttpService:GenerateGUID(false),
			StickId = item.StickId,
			Ingredients = item.Ingredients,
			Cooked = true,
			CookState = CookStates.GetStateFromCook(barAtPull, cookTime),
			Mutation = GrillerManager:GetGrillerMutation(data, grillUid),
		}
	end

	-- Runs a filled stick through a cooker: off its stand, onto a free grill, pulled on its aim, out to sell. With nobody or nowhere to cook it, it waits on its stand.
	local function cook(item, availableAt: number)
		local cooker = earliestFree(cookers)
		local grill = earliestFree(grills)

		if not cooker or not grill or grill.FreeAt == math.huge then
			item.CollectedAt = math.huge
			table.insert(onStands, math.huge)
			return
		end

		-- Past its grill mark it juggles cooks, so the next is only held until one of those is delivered
		local startAt = math.max(availableAt, cooker.FreeAt)
		while #cooker.InFlight >= cooker.GrillTier do
			startAt = math.max(startAt, popEarliest(cooker.InFlight))
		end

		item.CollectedAt = startAt + cooker.Notice + cooker.WalkLeg + cooker.Pickup
		table.insert(onStands, item.CollectedAt)

		local grillStart = math.max(item.CollectedAt + cooker.WalkLeg + cooker.Place, grill.FreeAt)
		cooker.FreeAt = grillStart

		local cookTime = GrillerManager:GetCookTime(data, grill.Uid, item.Ingredients)
		-- Never short of the window, as the live pull is floored at the light: raw is not a thing it pulls
		local pullBar = math.max(
			Cooker.GetAimBar(cooker.Skill, cookTime) + Cooker.RollPullError(cooker.Skill, cookTime),
			CookStates.RAW_END * cookTime
		)
		local readyAt = grillStart + pullBar

		item.ReadyAt = readyAt
		grill.FreeAt = readyAt + cooker.Pickup
		table.insert(cooker.InFlight, readyAt + cooker.Pickup + cooker.WalkLeg + cooker.Place)

		settleCook(item, grill.Uid, pullBar, cookTime)
		deliver(item, cooker, readyAt)
	end

	-- Finishes a cook left lit on a grill: the cooker walks up and pulls it on its aim, or the moment it arrives if the aim has already passed -- the honest late pull the live cooker makes on a cook it adopts.
	local function finishCook(item)
		local cooker = earliestFree(cookers)

		if not cooker then
			item.ReadyAt = math.huge
			return
		end

		local startAt = cooker.FreeAt
		while #cooker.InFlight >= cooker.GrillTier do
			startAt = math.max(startAt, popEarliest(cooker.InFlight))
		end

		local saved = item.Cook
		local cookTime = saved.CookTime

		-- Where the bar stands after `elapsed` wall seconds, through the same warps the settle reads it by
		local function barAt(elapsed: number): number
			return CookStates.GetBarElapsed(
				elapsed,
				cookTime,
				saved.CookWindowStretch,
				saved.CookProgress,
				saved.CookInstability,
				saved.CookInstabilityPhase
			)
		end

		local pullBar = math.max(
			Cooker.GetAimBar(cooker.Skill, cookTime) + Cooker.RollPullError(cooker.Skill, cookTime),
			CookStates.RAW_END * cookTime
		)
		local arriveAt = startAt + cooker.Notice + cooker.WalkLeg

		-- No bank means the session ended without its save, the same fallback the resume makes. Bar seconds
		-- stand in for wall seconds on the way to the aim: the wobble integrates out over a cook
		local banked = saved.CookPausedElapsed or 0
		local readyAt = math.max(pullBar - barAt(banked), arriveAt)

		item.ReadyAt = readyAt
		cooker.FreeAt = arriveAt
		item.Grill.FreeAt = readyAt + cooker.Pickup
		table.insert(cooker.InFlight, readyAt + cooker.Pickup + cooker.WalkLeg + cooker.Place)

		settleCook(item, item.Uid, barAt(banked + readyAt), cookTime)
		deliver(item, cooker, readyAt)
	end

	-- Builds the next skewer off the chest, a stick and a stick's worth of ingredients drawn as the maker's star draws them, and times the trips. Returns why it couldn't, or nil on a skewer made.
	local function make(item, maker): string?
		if standCapacity == 0 then
			return STOP.NO_STAND
		end

		-- Ranked once per skewer and drawn down as it goes, rather than re-sorted per pick as the live maker does
		local ingredientsLeft = 0
		for _, hut in huts do
			hut.Ranked = BbqMaker.RankStoredIngredients(hut)

			for _, ingredientId in hut.Ranked do
				ingredientsLeft += hut.Ingredients[ingredientId]
			end
		end

		local stickHut, stickId
		for _, hut in huts do
			stickId = BbqMaker.PickRanked(maker.Skill, BbqMaker.RankStoredSticks(hut))

			if stickId then
				stickHut = hut
				break
			end
		end

		if not stickId then
			return if ingredientsLeft > 0 then STOP.NO_STICKS else STOP.EMPTY
		end

		-- A stick it can't fill is left in the chest, since a part-built stand is nothing a cooker will take
		local capacity = Sticks.GetStickFromId(stickId).Capacity
		if ingredientsLeft < capacity then
			return STOP.NO_INGREDIENTS
		end

		stickHut.Sticks[stickId] -= 1
		item.StickId = stickId
		item.Ingredients = {}
		item.Takes = { { Hut = stickHut.Uid, Kind = "Sticks", Id = stickId } }

		for _ = 1, capacity do
			for _, hut in huts do
				local ingredientId = BbqMaker.PickRanked(maker.Skill, hut.Ranked)
				if not ingredientId then
					continue
				end

				hut.Ingredients[ingredientId] -= 1
				if hut.Ingredients[ingredientId] <= 0 then
					table.remove(hut.Ranked, table.find(hut.Ranked, ingredientId))
				end

				table.insert(item.Ingredients, ingredientId)
				table.insert(item.Takes, { Hut = hut.Uid, Kind = "Ingredients", Id = ingredientId })
				break
			end
		end

		-- Held until a stand frees up when every one is loaded, which is the wait a slow cooker hands the maker
		local startAt = maker.FreeAt
		if #onStands >= standCapacity then
			local freedAt = popEarliest(onStands)
			item.WaitedOnStand = freedAt > startAt
			startAt = math.max(startAt, freedAt)
		end

		local trips = math.ceil(capacity / maker.Carry)
		item.StartAt = startAt
		item.MadeAt = startAt + maker.Notice + trips * (2 * maker.WalkLeg + maker.Pickup) + capacity * maker.Build
		maker.FreeAt = item.MadeAt

		return nil
	end

	local items = {}
	local stopped = nil

	-- The BBQ left on display sells first, unless a custom order's customer is on its way for one of them
	if data.ActiveCustomOrder == nil then
		for index, record in data.SkewerStand do
			local item = { Source = "SellStand", Index = index, Record = record }
			sell(item, 0)
			table.insert(onStand, item.SoldAt)
			table.insert(items, item)
		end
	else
		for _ in data.SkewerStand do
			table.insert(onStand, math.huge)
		end
	end

	for _, seed in seeds do
		if seed.Source == "Grill" then
			finishCook(seed)
		else
			cook(seed, 0)
		end

		table.insert(items, seed)
	end

	-- The stage the chest's skewers would pile up short of, which is what the run reports when it stalls
	local usableGrills = 0
	for _, grill in grills do
		if grill.FreeAt < math.huge then
			usableGrills += 1
		end
	end

	local missing = if #cookers == 0
		then STOP.NO_COOKER
		elseif usableGrills == 0 then STOP.NO_GRILL
		elseif #sellers == 0 then STOP.NO_SELLER
		else nil

	if #makers == 0 then
		local hasStock = false
		for _, hut in huts do
			if #BbqMaker.RankStoredSticks(hut) > 0 or #BbqMaker.RankStoredIngredients(hut) > 0 then
				hasStock = true
			end
		end

		stopped = if hasStock then STOP.NO_MAKER else STOP.EMPTY
	else
		for _ = 1, OfflineEarnings.MAX_SIMULATED_SKEWERS do
			local maker = earliestFree(makers)
			local item = { Source = "New" }

			stopped = make(item, maker)
			if stopped then
				break
			end

			-- Out of time. Held on a full row of stands, the thing behind the row is what stopped it
			if item.StartAt >= horizon then
				stopped = if item.WaitedOnStand then missing else nil
				break
			end

			table.insert(items, item)
			cook(item, item.MadeAt)
		end
	end

	-- Every item settles at the last resting place it reached inside the window: sold, out on the sell stand, or on a stick stand. Anything still in a pair of hands or on a grill is put back where it started, chest stock included
	local report = { WorkedSeconds = 0, Made = 0, Cooked = 0, Sold = 0, Earned = 0, Stopped = stopped }
	local result = {
		Report = report,
		Takes = {}, -- [hutUid] = { Sticks = [id] = n, Ingredients = [id] = n }
		SoldIndexes = {}, -- [index] = true, the BBQ that went off the saved sell stand
		ClearStands = {}, -- [uid] = true, filled stands a cooker picked up
		ClearGrills = {}, -- [uid] = true, lit grills a cooker finished
		OnStands = {}, -- { StickId, Ingredients }, skewers built and waiting on a stand
		Delivered = {}, -- cooked records put out on the sell stand, in the order they landed
		CookStateCounts = {}, -- [cookStateId] = n, every cook settled
		SoldCookStateCounts = {}, -- [cookStateId] = n, every BBQ sold
	}

	local function countCook(record)
		local cookStateId = StickModel.GetCookStateId(record)
		result.CookStateCounts[cookStateId] = (result.CookStateCounts[cookStateId] or 0) + 1
		report.Cooked += 1
	end

	local function countSale(item)
		local cookStateId = StickModel.GetCookStateId(item.Record)
		result.SoldCookStateCounts[cookStateId] = (result.SoldCookStateCounts[cookStateId] or 0) + 1
		report.Sold += 1
		report.Earned += item.Offer
		report.WorkedSeconds = math.max(report.WorkedSeconds, item.SoldAt)
	end

	local function takeStock(item)
		for _, take in item.Takes do
			local hutTakes = result.Takes[take.Hut] or { Sticks = {}, Ingredients = {} }
			result.Takes[take.Hut] = hutTakes
			hutTakes[take.Kind][take.Id] = (hutTakes[take.Kind][take.Id] or 0) + 1
		end
	end

	local delivered = {}

	for _, item in items do
		-- Unset where the pipeline never reached that far, which reads the same as never inside the window
		local sold = (item.SoldAt or math.huge) < horizon
		local wasDelivered = (item.DeliverAt or math.huge) < horizon

		if item.Source == "SellStand" then
			if sold then
				result.SoldIndexes[item.Index] = true
				countSale(item)
			end

			continue
		end

		if wasDelivered then
			if item.Source == "Grill" then
				result.ClearGrills[item.Uid] = true
			elseif item.Source == "Stand" then
				result.ClearStands[item.Uid] = true
			else
				takeStock(item)
				report.Made += 1
			end

			countCook(item.Record)

			if sold then
				countSale(item)
			else
				table.insert(delivered, item)
				report.WorkedSeconds = math.max(report.WorkedSeconds, item.DeliverAt)
			end
		elseif item.Source == "New" and item.MadeAt < horizon and item.CollectedAt >= horizon then
			table.insert(result.OnStands, item)
			report.WorkedSeconds = math.max(report.WorkedSeconds, item.MadeAt)
		end
	end

	table.sort(delivered, function(left, right)
		return left.DeliverAt < right.DeliverAt
	end)

	for _, item in delivered do
		table.insert(result.Delivered, item.Record)
	end

	-- A filled stand the cooker never got to keeps its stand, so the row can come up a place short of what the
	-- pass built on it; whatever doesn't fit goes back to the chest rather than onto a stand already taken
	local freeStands = 0
	for uid, placed in data.Structures do
		if Structures.IsCategory(placed.Type, STAND_CATEGORY) then
			if type(data.StickStands[uid]) ~= "table" or result.ClearStands[uid] then
				freeStands += 1
			end
		end
	end

	while #result.OnStands > freeStands do
		table.remove(result.OnStands)
	end

	for _, item in result.OnStands do
		takeStock(item)
		report.Made += 1
	end

	report.WorkedSeconds = math.min(report.WorkedSeconds, horizon)

	return result
end

-- Writes what a pass moved, through `write(path, value)`: straight into the profile at join, or through the replica when run on a loaded one.
function OfflineEarningManager:ApplyOfflineEarnings(data, result, write: (path: { string }, value: any) -> ())
	for hutUid, kinds in result.Takes do
		for kind, ids in kinds do
			for id, taken in ids do
				local shelf = data.HutStorage[hutUid][kind]
				write({ "HutStorage", hutUid, kind, id }, math.max((shelf[id] or 0) - taken, 0))
			end
		end
	end

	for uid in result.ClearGrills do
		write({ "Grillers", uid }, nil)
	end

	for uid in result.ClearStands do
		write({ "StickStands", uid }, nil)
	end

	-- Onto whichever stands are bare once the collected ones are cleared, in the order they were built
	local onStands = table.clone(result.OnStands)
	for uid, placed in data.Structures do
		if #onStands == 0 then
			break
		end

		if not Structures.IsCategory(placed.Type, STAND_CATEGORY) then
			continue
		end

		if type(data.StickStands[uid]) ~= "table" or result.ClearStands[uid] then
			local item = table.remove(onStands, 1)
			write({ "StickStands", uid }, { StickId = item.StickId, Ingredients = item.Ingredients })
		end
	end

	-- The survivors keep their order, and what the cooker put out follows them
	local sellStand = {}
	for index, record in data.SkewerStand do
		if not result.SoldIndexes[index] then
			table.insert(sellStand, record)
		end
	end
	for _, record in result.Delivered do
		table.insert(sellStand, record)
	end
	write({ "SkewerStand" }, sellStand)

	-- The lifetime counters only. The sale window stays the player's own cooking, so the rating reads their hand rather than their staff's
	local report = result.Report
	if report.Cooked > 0 then
		write({ "SkewersCooked" }, data.SkewersCooked + report.Cooked)

		for cookStateId, count in result.CookStateCounts do
			write({ "CookStateCounts", cookStateId }, (data.CookStateCounts[cookStateId] or 0) + count)
		end
	end

	if report.Sold > 0 then
		write({ "SkewersSold" }, data.SkewersSold + report.Sold)
		write({ "SalesCompleted" }, data.SalesCompleted + report.Sold)

		for cookStateId, count in result.SoldCookStateCounts do
			write({ "SoldCookStateCounts", cookStateId }, (data.SoldCookStateCounts[cookStateId] or 0) + count)
		end
	end
end

-- Whether a profile has anyone at work, which is the one thing a pass can't do without.
local function hasEquippedEmployee(data): boolean
	for _, record in data.Employees do
		if record.Slot then
			return true
		end
	end

	return false
end

-- The join-time pass: measures the time away off the last stamp, runs the workers through it, and writes the result into the profile before anything else reads it. Must not yield.
function OfflineEarningManager:RunOfflineEarnings(player: Player, data)
	local now = workspace:GetServerTimeNow()
	local lastSeenAt = data.LastSeenAt
	data.LastSeenAt = now

	-- Zero is a profile that predates the stamp, and the tutorial wipes the hut on the way out anyway
	local away = now - lastSeenAt
	if lastSeenAt <= 0 or away < OfflineEarnings.MIN_AWAY_SECONDS or not data.TutorialCompleted then
		return
	end

	if not hasEquippedEmployee(data) then
		return
	end

	local credited = math.min(away, OfflineEarnings.MAX_AWAY_SECONDS)
	local result = self:SimulateOfflineEarnings(data, credited * OfflineEarnings.WORK_RATE)
	self:ApplyOfflineEarnings(data, result, function(path, value)
		writeDirect(data, path, value)
	end)

	local report = result.Report
	report.AwaySeconds = credited

	if report.Sold > 0 then
		self._pendingClaims[player] = report
	end

	self.OnOfflineEarningsSimulated:Fire(player, report)
end

-- Puts the claim waiting on a player in front of them, once they're stood on their base to see it.
function OfflineEarningManager:ShowPendingClaim(player: Player)
	local report = self._pendingClaims[player]
	if not report then
		return
	end

	self.ShowOfflineEarningsEvent:FireClient(player, {
		-- The boosted figure, since that's what lands in their balance
		Amount = CurrencyManager:GetBoostedAmount(player, report.Earned),
		BbqSold = report.Sold,
		SecondsAway = report.AwaySeconds,
	})
end

-- Pays the claim out. The plain amount goes in, so the boosts land on it once, exactly as they do on a sale.
function OfflineEarningManager:ClaimOfflineEarnings(player: Player)
	if self._claiming[player] then
		return
	end
	self._claiming[player] = true

	local report = self._pendingClaims[player]
	if not report then
		self._claiming[player] = nil
		self.OfflineEarningsClaimResultEvent:FireClient(player, { Success = false, Amount = 0 })
		return
	end

	-- Cleared before the payout, so a second press can't land on the same report
	self._pendingClaims[player] = nil

	-- Read before the payout, or the early boost prices this claim off a figure this claim just moved
	local payout = CurrencyManager:GetBoostedAmount(player, report.Earned)
	CurrencyManager:IncrementCurrency(player, report.Earned, "OfflineEarnings")

	self._claiming[player] = nil
	self.OfflineEarningsClaimResultEvent:FireClient(player, { Success = true, Amount = payout })
	self.OnOfflineEarningsClaimed:Fire(player, report, payout)
end

-- Pays a claim never pressed straight into the profile on its way out, then stamps when they left. Must not yield.
function OfflineEarningManager:SettleOnLastSave(player: Player, data)
	local report = self._pendingClaims[player]
	if report then
		local payout = CurrencyManager:GetBoostedAmount(player, report.Earned)
		data.Currency += payout
		data.TotalEarned += payout
		self._pendingClaims[player] = nil
	end

	data.LastSeenAt = workspace:GetServerTimeNow()
end

-- Runs the pass on a loaded profile as if they'd been away `seconds`, writing through the replica so the base updates live. For the offlineEarnings command; the join-time pass runs before any of that exists.
function OfflineEarningManager:DebugSimulate(player: Player, seconds: number)
	local data = PlayerDataManager:GetLoadedPlayerData(player)
	if not data then
		return nil
	end

	local credited = math.min(seconds, OfflineEarnings.MAX_AWAY_SECONDS)
	local result = self:SimulateOfflineEarnings(data, credited * OfflineEarnings.WORK_RATE)
	self:ApplyOfflineEarnings(data, result, function(path, value)
		PlayerDataManager:SetPlayerDataKey(player, path, value)
	end)

	local report = result.Report
	report.AwaySeconds = credited

	if report.Sold > 0 then
		self._pendingClaims[player] = report
		self:ShowPendingClaim(player)
	end

	return report
end

function OfflineEarningManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	CurrencyManager = require(script.Parent.CurrencyManager)
	GrillerManager = require(script.Parent.GrillerManager)
	SkewerStandManager = require(script.Parent.SkewerStandManager)
	BaseManager = require(script.Parent.BaseManager)
	BbqMaker = require(script.Parent.EmployeeManager.Roles.BbqMaker)
	Cooker = require(script.Parent.EmployeeManager.Roles.Cooker)
	Seller = require(script.Parent.EmployeeManager.Roles.Seller)

	PlayerDataManager:RegisterPostLoadCallback(function(player: Player, data)
		self:RunOfflineEarnings(player, data)
	end)

	PlayerDataManager:RegisterPreCleanupCallback(function(player: Player, data)
		self:SettleOnLastSave(player, data)
	end)
end

function OfflineEarningManager:OnStart()
	-- Shown once they're stood on their base, so the panel lands on a loaded client rather than a loading one
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:ShowPendingClaim(player)
	end)

	self.ClaimOfflineEarningsEvent:OnServerEvent(function(player: Player)
		self:ClaimOfflineEarnings(player)
	end)

	-- Refreshed while they play, so a server that dies without its last save can't hand the session back as time away
	task.spawn(function()
		while true do
			task.wait(OfflineEarnings.HEARTBEAT_INTERVAL)

			local now = workspace:GetServerTimeNow()
			for _, player in Players:GetPlayers() do
				if PlayerDataManager:GetLoadedPlayerData(player) then
					PlayerDataManager:SetPlayerDataKey(player, "LastSeenAt", now)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._pendingClaims[player] = nil
		self._claiming[player] = nil
	end)
end

return OfflineEarningManager
