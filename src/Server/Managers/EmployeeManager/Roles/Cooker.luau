-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

-- Managers
local Managers = script.Parent.Parent.Parent
local PlayerDataManager = require(Managers.PlayerDataManager)
local GrillerManager = require(Managers.GrillerManager)
local StickStandManager = require(Managers.StickStandManager)
local SkewerStandManager = require(Managers.SkewerStandManager)

-- Shared
local Shared = ReplicatedStorage.Shared
local StickModel = require(Shared.StickModel)
local Sticks = require(Shared.Config.Sticks)
local Structures = require(Shared.Config.Structures)
local CookStates = require(Shared.Config.CookStates)
local Employees = require(Shared.Config.Employees)

-- The category, not one model's id, so a second kind of griller is picked up here unchanged
local GRILLER_CATEGORY = "Grillers"

-- Said while stood at a full sell stand, waiting for a spot to free up
local FULL_VARIANT = "Full"

-- Said at a grill whose cook is already in the window, while it waits on its own aim moment
local READY_VARIANT = "Ready"

-- Said walking back to a grill it already has cooking, after a delivery or an errand
local BACK_VARIANT = "Back"

-- Said handing the owner a raw skewer it has no grill for, rather than holding it while its own cooks burn
local HANDBACK_VARIANT = "HandBack"

-- Its own, so two employees pulling in the same frame don't share a sequence
local rng = Random.new()

-- The cooker: takes a filled stick off a stand, cooks it on a free griller, and puts it out on the sell stand. Its star is the pull -- the aim and the error below are the whole difference between a 1 and a 5. Past GRILL_MARKS it runs several grills at once, fetching the next stick while the last one cooks.

--
local Cooker = {}

-- Where a fresh cooker starts. Named here rather than assumed, since a role's states are its own
Cooker.Initial = "Idle"

-- Whether a stand's stick is loaded to its capacity and ready to be taken away and cooked.
local function isStandReady(record): boolean
	-- A legacy string-shaped entry reads as empty rather than erroring on .Ingredients
	if type(record) ~= "table" or record.Cooked then
		return false
	end

	local stick = Sticks.GetStickFromId(record.StickId)

	return stick ~= nil and #record.Ingredients >= stick.Capacity
end

-- The uid of a stand whose stick is finished and can be taken away now.
local function findReadyStand(employee, data): string?
	for uid, record in data.StickStands do
		if isStandReady(record) and employee:ClaimStation(uid) then
			return uid
		end
	end

	return nil
end

-- The uid of a stand worth walking to: a finished one first, else one still being loaded to go stand ready at. Reading a half-built stick as work about to happen is a practised employee's trick -- see ANTICIPATE_STARS.
local function findWorkableStand(employee, data): string?
	local ready = findReadyStand(employee, data)
	if ready then
		return ready
	end

	if employee:GetStars() < Employees.ANTICIPATE_STARS then
		return nil
	end

	for uid, record in data.StickStands do
		if type(record) ~= "table" or record.Cooked or #record.Ingredients == 0 then
			continue
		end

		if employee:ClaimStation(uid) then
			return uid
		end
	end

	return nil
end

-- The uid of a griller with nothing on it, or nil when every one they own is busy.
local function findFreeGrill(employee, data): string?
	for uid, placed in data.Structures do
		if not Structures.IsCategory(placed.Type, GRILLER_CATEGORY) or data.Grillers[uid] then
			continue
		end

		if employee:ClaimStation(uid) then
			return uid
		end
	end

	return nil
end

-- The uid of a griller already cooking that no employee has taken on, or nil. This is how a skewer the player put down themselves gets finished rather than left to burn.
local function findUnattendedCook(employee, data): string?
	for uid, record in data.Grillers do
		-- Its own claims read as free, so a cook it's already timing is skipped by name
		if record.Cooking and not employee._cooks[uid] and employee:ClaimStation(uid) then
			return uid
		end
	end

	return nil
end

-- Forgets one cook and gives its grill back, for a cook it has pulled or lost.
local function dropCook(employee, uid: string)
	employee._cooks[uid] = nil
	employee:ReleaseStation(uid)
end

-- Gives back the stand and grill this leg held, keeping any grill it has cooking. Always Idle: it may still be carrying, and Idle is the router that lands that first.
local function abandonRun(employee): string
	if employee._standUid then
		employee:ReleaseStation(employee._standUid)
		employee._standUid = nil
	end

	if employee._grillUid and not employee._cooks[employee._grillUid] then
		employee:ReleaseStation(employee._grillUid)
	end
	employee._grillUid = nil

	return "Idle"
end

-- Walks toward a station, giving up on a route it can't finish. Returns the state to move to, or nil to keep walking.
local function walkToStation(employee, now: number, uid: string, arrived: string, dwell: number?): string?
	local model = employee:GetStructureModel(uid)
	if not model then
		return abandonRun(employee)
	end

	-- Solved once: StepWalk holds the target, so it isn't re-measured from a position that's moved
	local result = employee:StepWalk(now, employee._walkTarget or employee:GetApproachPosition(model))
	if result == "arrived" then
		employee:FaceTowards(model:GetPivot().Position)

		if dwell then
			employee:Dwell(now, dwell)
		end

		return arrived
	end

	-- Stuck on scenery: this leg's claims go back so another employee can try the same station
	if result == "timeout" then
		return abandonRun(employee)
	end

	return nil
end

-- Wall seconds from a cook's start until its bar reaches `bar`, through this grill's own warps.
local function getElapsedForCookBar(record, bar: number): number
	return CookStates.GetElapsedForBar(
		bar,
		record.CookTime,
		record.CookWindowStretch,
		record.CookProgress,
		record.CookInstability,
		record.CookInstabilityPhase
	)
end

-- Where a cook of `skill` aims to pull a `cookTime` bar, in bar seconds: a fraction of the perfect window up to 1, and past 1 that far again toward the moment a full bar stops reading Cooked -- see Config.Employees.
function Cooker.GetAimBar(skill: number, cookTime: number): number
	local windowStart = CookStates.RAW_END * cookTime
	local windowEnd = CookStates.GetPerfectEnd(cookTime) * cookTime
	local aim =
		Employees.InterpolateBySkill(Employees.COOK_AIM_WORST, Employees.COOK_AIM_BEST, Employees.COOK_AIM_GAMMA, skill)

	return if aim <= 1
		then windowStart + (windowEnd - windowStart) * aim
		else windowEnd + (cookTime + CookStates.GetOvertimeStart() - windowEnd) * (aim - 1)
end

-- How far off its aim a cook of `skill` pulls, in wall seconds. Scaled by the window's half-width so it means the same on a long cook as a short one.
function Cooker.RollPullError(skill: number, cookTime: number): number
	local halfWindow = (CookStates.GetPerfectEnd(cookTime) - CookStates.RAW_END) * cookTime / 2
	local spread = Employees.InterpolateBySkill(
		Employees.COOK_ERROR_WORST,
		Employees.COOK_ERROR_BEST,
		Employees.COOK_ERROR_GAMMA,
		skill
	)

	return rng:NextNumber(-1, 1) * spread * halfWindow
end

-- Solves when a cook should come off, when to start reaching for it and when its window opens, off this employee's star. One hand times every cook: its own, one it takes over, and the estimate an errand is judged by.
local function solveCookTimes(employee, record, now: number)
	-- A skewer whose ingredients add up to no cook sits there unlit, so there's nothing to time
	if not (record and record.Cooking) then
		return { PullAt = now, ReachAt = now, ReadyAt = now }
	end

	local cookTime = record.CookTime
	local skill = employee.Record.Skill

	-- Solved through the same warp the player's bar is drawn from, so an unstable grill throws it off too
	local targetElapsed = getElapsedForCookBar(record, Cooker.GetAimBar(skill, cookTime))

	-- Floored at `now`, which is the light for its own cook and the walk-up for one it takes over. Without
	-- it, adopting a long-neglected cook would settle at a moment that has passed and hand back a Perfect
	-- skewer off a burnt grill
	local pullAt = math.max(record.CookStartedAt + targetElapsed + Cooker.RollPullError(skill, cookTime), now)

	return {
		PullAt = pullAt,
		-- It reaches an action early so the skewer leaves the grill on the moment solved above, rather than
		-- the bar running past the window while it takes it
		ReachAt = math.max(pullAt - employee:GetPickupOverhead(), record.CookStartedAt),
		-- Not floored at `now`: a cook it takes over that's already in the window is ready the moment it walks up
		ReadyAt = record.CookStartedAt + getElapsedForCookBar(record, CookStates.RAW_END * cookTime),
		-- The light it was solved against, so a grill re-lit under it while it was away is timed afresh
		StartedAt = record.CookStartedAt,
	}
end

-- Studs between two points over the ground, the line an employee walks: it passes through scenery and never climbs.
local function flatDistance(a: Vector3, b: Vector3): number
	return ((a - b) * Vector3.new(1, 0, 1)).Magnitude
end

-- Whether every pull stays on time if `legs` are walked first and the cook at their end joins the round: each grill in reach order, then the sell stand, at this employee's own pace. `record` is the cook it would take over, or the one it would light there, stamped as lit when it arrives.
local function fitsSchedule(employee, now: number, legs: { { Position: Vector3, Overhead: number } }, record): boolean
	local stand = employee:GetSellStandPart()
	if not stand then
		return false
	end

	local speed = employee._humanoid.WalkSpeed
	local pickup = employee:GetPickupOverhead()
	local place = employee:GetPlaceOverhead()
	local position = employee._humanoid.RootPart.Position
	local at = now

	for _, leg in legs do
		at += flatDistance(position, leg.Position) / speed + leg.Overhead
		position = leg.Position
	end

	-- Lit where the legs end, unless it's already burning
	record.CookStartedAt = record.CookStartedAt or at

	local round = { { Position = position, ReachAt = solveCookTimes(employee, record, at).ReachAt } }
	for uid, cook in employee._cooks do
		table.insert(round, { Position = employee:GetStructureModel(uid):GetPivot().Position, ReachAt = cook.ReachAt })
	end

	table.sort(round, function(a, b)
		return a.ReachAt < b.ReachAt
	end)

	for _, stop in round do
		local walk = flatDistance(position, stop.Position) / speed
		at += walk

		-- Slack only where it has to get somewhere: a grill it's already stood at is worked from where it stands
		if walk > 0 and at + Employees.GRILL_ERRAND_MARGIN > stop.ReachAt then
			return false
		end

		-- The reach, then the trip to put the skewer out
		at = math.max(at, stop.ReachAt) + pickup
		at += flatDistance(stop.Position, stand.Position) / speed + place
		position = stand.Position
	end

	return true
end

-- An errand that fits between its pulls, claimed and ready to walk: a cook nobody's minding first, else a finished stick and a free grill to cook it on. Nil, with nothing claimed, when none fits.
local function pickErrand(employee, data, now: number): string?
	-- A free colleague takes the next job; this one only juggles once everyone's busy
	if employee:HasFreeColleague() then
		return nil
	end

	local grillUid = findUnattendedCook(employee, data)
	if grillUid then
		local grill = employee:GetStructureModel(grillUid)
		local legs = grill and { { Position = grill:GetPivot().Position, Overhead = 0 } }

		if legs and fitsSchedule(employee, now, legs, data.Grillers[grillUid]) then
			employee._grillUid = grillUid
			return "ToTend"
		end

		employee:ReleaseStation(grillUid)
	end

	local standUid = findReadyStand(employee, data)
	if not standUid then
		return nil
	end

	-- Claimed before it sets off, so Await has a grill waiting rather than a wait of its own
	grillUid = findFreeGrill(employee, data)

	local stand = employee:GetStructureModel(standUid)
	local grill = grillUid and employee:GetStructureModel(grillUid)

	if stand and grill then
		local cookTime = GrillerManager:GetCookTime(data, grillUid, data.StickStands[standUid].Ingredients)

		-- Await's dwell before the collect and ToGrill's before the place, the two stops on the way
		local legs = {
			{ Position = stand:GetPivot().Position, Overhead = employee:GetPickupOverhead() },
			{ Position = grill:GetPivot().Position, Overhead = employee:GetPlaceOverhead() },
		}

		if fitsSchedule(employee, now, legs, { Cooking = if cookTime > 0 then true else nil, CookTime = cookTime }) then
			employee._standUid = standUid
			employee._grillUid = grillUid
			return "ToStand"
		end
	end

	employee:ReleaseStation(standUid)

	if grillUid then
		employee:ReleaseStation(grillUid)
	end

	return nil
end

-- Decides what to do next. Everything routes through here, so what it's carrying is enough to resume a rejoin.
Cooker.Idle = function(employee, now: number): string?
	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
	if not data then
		return nil
	end

	local carrying = employee.Record.Carrying

	-- A cooked skewer only has to be put out; a raw one still needs a grill under it
	if carrying and carrying.Cooked then
		return "ToSell"
	end

	-- With cooks on the go every choice is made at the grill rather than on a stroll
	if not carrying and next(employee._cooks) then
		return "Tend"
	end

	if employee:ShouldPoll(now) then
		if carrying then
			employee._grillUid = findFreeGrill(employee, data)

			if employee._grillUid then
				return "ToGrill"
			end

			-- No grill for it and cooks to mind: handed to the owner rather than held, since a pull needs
			-- empty hands and every cook it has would burn waiting on one
			if next(employee._cooks) then
				employee.Manager:ReturnEmployeeStock(employee.Player, employee.Uid, employee.Record)
				employee:SetCarrying(nil)
				employee:Say("Idle", HANDBACK_VARIANT)

				return "Tend"
			end
		else
			-- Ahead of the stands: a cook is running down whether anyone watches it or not, where a stick
			-- on a stand will wait. This is what picks up a skewer the player put on a grill themselves
			employee._grillUid = findUnattendedCook(employee, data)

			if employee._grillUid then
				return "ToTend"
			end

			-- The grill is claimed at the stand rather than here, so a base with every grill busy still
			-- sends someone to stand ready instead of leaving the stick sitting there
			employee._standUid = findWorkableStand(employee, data)

			if employee._standUid then
				return "ToStand"
			end
		end
	end

	-- Nothing to do, so stroll the plots rather than standing wherever the last job left it
	employee:StepWander(now, data)

	return nil
end

Cooker.ToStand = function(employee, now: number): string?
	return walkToStation(employee, now, employee._standUid, "Await")
end

-- Stands at the stand until there's something to take and somewhere to cook it. This is what makes a stick put down half-built get picked up the moment it's finished, rather than on the next patrol.
Cooker.Await = function(employee, now: number): string?
	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
	if not data then
		return nil
	end

	local model = employee:GetStructureModel(employee._standUid)
	if model then
		employee:FaceTowards(model:GetPivot().Position)
	end

	-- Taken away, or the stand picked up out from under it
	local record = data.StickStands[employee._standUid]
	if not model or type(record) ~= "table" or #record.Ingredients == 0 then
		return abandonRun(employee)
	end

	if not isStandReady(record) then
		-- With cooks running there's nothing to wait for: the hub sent it to a finished stick and picks the next errand itself
		if next(employee._cooks) then
			return abandonRun(employee)
		end

		-- A stand finished elsewhere beats waiting on this one, or a stick left half-built parks it forever
		if employee:ShouldPoll(now) then
			local readyUid = findReadyStand(employee, data)

			if readyUid then
				employee:ReleaseStation(employee._standUid)
				employee._standUid = readyUid

				return "ToStand"
			end
		end

		-- Still being loaded, so it waits rather than walking off and coming back
		return nil
	end

	-- Ready, but nowhere to cook it yet: it holds the stand so the stick isn't left for a patrol to rediscover.
	-- Already claimed by the hub when cooks are running, so a base with every grill busy still gets someone stood ready
	employee._grillUid = employee._grillUid or findFreeGrill(employee, data)
	if not employee._grillUid then
		return nil
	end

	employee:Dwell(now, employee:GetPickupOverhead())

	return "Collect"
end

-- Lifts the stick off the stand. The record is carried rather than pocketed, so no tool appears in the owner's backpack.
Cooker.Collect = function(employee, _now: number): string?
	local record = StickStandManager:TakeStickFromStand(employee.Player, employee._standUid)

	-- The player got there first, or took it while this one was walking
	if not record then
		return abandonRun(employee)
	end

	-- Only the stand goes back; the grill stays claimed, since that's where this skewer is headed
	employee:ReleaseStation(employee._standUid)
	employee._standUid = nil

	-- Minted here because a stand hands over a new skewer, the same rule the player's own take follows
	record.Uid = HttpService:GenerateGUID(false)
	employee:SetCarrying(record)

	return "ToGrill"
end

-- Walks to a cook: one someone else started, timed on arrival so it can only pull from the moment it got there, or one of its own it's coming back to.
Cooker.ToTend = function(employee, now: number): string?
	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
	local record = data and data.Grillers[employee._grillUid]

	-- Taken off, or settled by the player while this one was walking over
	if not record then
		dropCook(employee, employee._grillUid)
		return abandonRun(employee)
	end

	-- Its own, so the sign says it's coming back rather than helping out. Set every tick, since the state
	-- change cleared it on entry; it early-outs once set
	local cook = employee._cooks[employee._grillUid]
	if cook then
		employee:SetVariant(BACK_VARIANT)
	end

	local result = walkToStation(employee, now, employee._grillUid, "Tend")
	if result ~= "Tend" then
		return result
	end

	if not cook then
		employee._cooks[employee._grillUid] = solveCookTimes(employee, record, now)
	elseif now - cook.ReachAt > Employees.TICK_INTERVAL then
		-- Back late: the pull lands when a reach started now ends, so the trip costs the cook rather than
		-- crediting a moment it wasn't here for. A tick's jitter is still forgiven
		cook.PullAt = now + employee:GetPickupOverhead()
	end

	return result
end

Cooker.ToGrill = function(employee, now: number): string?
	return walkToStation(employee, now, employee._grillUid, "Place", employee:GetPlaceOverhead())
end

-- Lights the cook and solves when to pull it, once, off this employee's star.
Cooker.Place = function(employee, now: number): string?
	if not GrillerManager:PlaceSkewerOnGriller(employee.Player, employee._grillUid, employee.Record.Carrying) then
		-- Refused for a moment rather than for good while the grill is still theirs and bare: the owner is
		-- mid-toggle somewhere, so it holds the skewer and tries again next tick
		local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
		if
			data
			and GrillerManager:OwnsGrillerStructure(data, employee._grillUid)
			and not data.Grillers[employee._grillUid]
		then
			return nil
		end

		return abandonRun(employee)
	end

	employee:SetCarrying(nil)

	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
	employee._cooks[employee._grillUid] = solveCookTimes(employee, data and data.Grillers[employee._grillUid], now)

	return "Tend"
end

-- Minds its cooks: every grill it has going is checked, the earliest pull is where it stands, and with room for another it looks for an errand that fits between them.
Cooker.Tend = function(employee, now: number): string?
	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
	if not data then
		return nil
	end

	local count = 0
	local earliestUid, earliest

	for uid, cook in employee._cooks do
		local record = data.Grillers[uid]

		-- Pulled by the player, or the grill picked up: off the list, or it'd walk back to nothing
		if not (record and employee:GetStructureModel(uid)) then
			dropCook(employee, uid)
			continue
		end

		-- Re-lit under it while it was away, so the new cook is timed rather than pulled on the old clock
		if record.Cooking and record.CookStartedAt ~= cook.StartedAt then
			cook = solveCookTimes(employee, record, now)
			employee._cooks[uid] = cook
		end

		count += 1

		if not earliest or cook.ReachAt < earliest.ReachAt then
			earliestUid, earliest = uid, cook
		end
	end

	if not earliestUid then
		return abandonRun(employee)
	end

	-- Spare hands past its grill mark: the next job is fetched while these cook, so long as every pull still
	-- lands on time
	if Employees.GetTierFromStars(Employees.GRILL_MARKS, employee:GetStars()) > count and employee:ShouldPoll(now) then
		local errand = pickErrand(employee, data, now)
		if errand then
			return errand
		end
	end

	-- The earliest pull is where it stands; anywhere else, it heads back
	if employee._grillUid ~= earliestUid then
		employee._grillUid = earliestUid
		return "ToTend"
	end

	-- Waits square on the grill's front or back rather than wherever it walked up from, so a line of
	-- them reads as staff working a row of grills. Solved once: StepWalk holds the target
	local model = employee:GetStructureModel(employee._grillUid)
	local result = employee:StepWalk(
		now,
		employee._walkTarget or employee:GetFacePosition(model),
		Employees.TEND_ARRIVE_DISTANCE
	)

	if result ~= "walking" then
		employee:FaceTowards(model:GetPivot().Position)
	end

	-- The bar the player is watching has turned green, so it stops reading as waiting and counts down its pull
	if now >= earliest.ReadyAt then
		employee:SetVariant(READY_VARIANT)
		employee:CountDownTo(earliest.PullAt)
	end

	if now < earliest.ReachAt then
		return nil
	end

	-- The reach is an action like any other, so it costs the same overhead and shows its own countdown
	employee:Dwell(now, employee:GetPickupOverhead())

	return "Pull"
end

-- Takes the cook off and settles it. Nil back means the player pulled it first, which costs this run and nothing else.
Cooker.Pull = function(employee, _now: number): string?
	local uid = employee._grillUid

	-- The moment solved at Place, not the moment the reach ended, so a tick's jitter can't cost the cook
	local record = GrillerManager:TakeSkewerFromGriller(employee.Player, uid, employee._cooks[uid].PullAt)

	dropCook(employee, uid)

	if not record then
		return abandonRun(employee)
	end

	employee._grillUid = nil

	-- A grill mints too, so the estimate the customer is shown can't be re-rolled off the old skewer's uid
	record.Uid = HttpService:GenerateGUID(false)
	employee:SetCarrying(record)

	-- Said outright rather than left to the chatter roll: the state flips to ToSell in the same tick, so a
	-- roll would almost never catch the skewer in hand, and reacting to the cook is the payoff of the whole run
	employee:Say("Pull", StickModel.GetCookStateId(record))

	return "ToSell"
end

Cooker.ToSell = function(employee, now: number): string?
	local stand = employee:GetSellStandPart()

	-- Nothing to walk to, so it holds on to the skewer and tries again rather than dropping it
	if not stand then
		return "Idle"
	end

	local result = employee:StepWalk(now, employee._walkTarget or employee:GetApproachPosition(stand))
	if result == "arrived" then
		employee:FaceTowards(stand.Position)
		employee:Dwell(now, employee:GetPlaceOverhead())
		return "Deliver"
	end

	return if result == "timeout" then "Idle" else nil
end

-- Puts the skewer out, which is what calls a customer over. A full stand is waited at, never toasted about.
Cooker.Deliver = function(employee, _now: number): string?
	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
	if not data then
		return "Idle"
	end

	-- Checked here rather than left to PlaceSkewerRecord, whose rejection toast is meant for the player
	if #data.SkewerStand >= SkewerStandManager.MAX_SKEWERS then
		-- Said outright on the first tick of the wait, since a customer can free a spot before the chatter roll comes round
		if employee._speakVariant ~= FULL_VARIANT then
			employee:SetVariant(FULL_VARIANT)
			employee:Say("Deliver", FULL_VARIANT)
		end

		-- Held at the stand rather than sent back round Idle, so it puts the BBQ out the tick a spot frees
		return nil
	end

	if SkewerStandManager:PlaceSkewerRecord(employee.Player, data, employee.Record.Carrying, true) then
		employee:SetCarrying(nil)
	end

	return "Idle"
end

return Cooker
