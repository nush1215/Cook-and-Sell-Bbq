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

-- Its own, so two employees pulling in the same frame don't share a sequence
local rng = Random.new()

-- The cooker: takes a filled stick off a stand, cooks it on a free griller, and puts it out on the sell stand. Its star is the pull -- the aim and the error below are the whole difference between a 1 and a 5.

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
		if record.Cooking and employee:ClaimStation(uid) then
			return uid
		end
	end

	return nil
end

-- Walks toward a station, giving up on a route it can't finish. Returns the state to move to, or nil to keep walking.
local function walkToStation(employee, now: number, uid: string, arrived: string, dwell: number?): string?
	local model = employee:GetStructureModel(uid)
	if not model then
		employee:ReleaseStations()
		return "Idle"
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

	-- Stuck on scenery: the claims go back so another employee can try the same station
	if result == "timeout" then
		employee:ReleaseStations()
		return "Idle"
	end

	return nil
end

-- Decides what to do next. Everything routes through here, so what it's carrying is enough to resume a rejoin.
-- Solves when a cook should come off and when to start reaching for it, off this employee's star. Shared by the cook it lights itself and one it takes over, so a player's cook is timed by exactly the same hand.
local function scheduleCook(employee, record, now: number)
	-- A skewer whose ingredients add up to no cook sits there unlit, so there's nothing to time
	if not (record and record.Cooking) then
		employee._pullAt = now
		employee._reachAt = now
		return
	end

	local cookTime = record.CookTime
	local perfectEnd = CookStates.GetPerfectEnd(cookTime)

	-- Where in the perfect window it aims. A poor cooker aims early on purpose -- see Config.Employees
	local aim = employee:GetCurveValue(Employees.COOK_AIM_WORST, Employees.COOK_AIM_BEST, Employees.COOK_AIM_GAMMA)
	local targetBar = (CookStates.RAW_END + (perfectEnd - CookStates.RAW_END) * aim) * cookTime

	-- Solved through the same warp the player's bar is drawn from, so an unstable grill throws it off too
	local targetElapsed = CookStates.GetElapsedForBar(
		targetBar,
		cookTime,
		record.CookWindowStretch,
		record.CookProgress,
		record.CookInstability,
		record.CookInstabilityPhase
	)

	-- Error in wall seconds, scaled by the window's half-width so it means the same on a long cook as a short one
	local halfWindow = (perfectEnd - CookStates.RAW_END) * cookTime / 2
	local spread =
		employee:GetCurveValue(Employees.COOK_ERROR_WORST, Employees.COOK_ERROR_BEST, Employees.COOK_ERROR_GAMMA)

	-- Floored at `now`, which is the light for its own cook and the walk-up for one it takes over. Without
	-- it, adopting a long-neglected cook would settle at a moment that has passed and hand back a Perfect
	-- skewer off a burnt grill
	employee._pullAt = math.max(record.CookStartedAt + targetElapsed + rng:NextNumber(-1, 1) * spread * halfWindow, now)

	-- It reaches an action early so the skewer leaves the grill on the moment solved above, rather than
	-- the bar running past the window while it takes it
	employee._reachAt = math.max(employee._pullAt - employee:GetActionOverhead(), record.CookStartedAt)
end

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

	if employee:ShouldPoll(now) then
		if carrying then
			employee._grillUid = findFreeGrill(employee, data)

			if employee._grillUid then
				return "ToGrill"
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
		employee:ReleaseStations()
		return "Idle"
	end

	if not isStandReady(record) then
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

	-- Ready, but nowhere to cook it yet: it holds the stand so the stick isn't left for a patrol to rediscover
	employee._grillUid = findFreeGrill(employee, data)
	if not employee._grillUid then
		return nil
	end

	employee:Dwell(now, employee:GetActionOverhead())

	return "Collect"
end

-- Lifts the stick off the stand. The record is carried rather than pocketed, so no tool appears in the owner's backpack.
Cooker.Collect = function(employee, _now: number): string?
	local record = StickStandManager:TakeStickFromStand(employee.Player, employee._standUid)

	-- The player got there first, or took it while this one was walking
	if not record then
		employee:ReleaseStations()
		return "Idle"
	end

	-- Only the stand goes back; the grill stays claimed, since that's where this skewer is headed
	employee:ReleaseStation(employee._standUid)
	employee._standUid = nil

	-- Minted here because a stand hands over a new skewer, the same rule the player's own take follows
	record.Uid = HttpService:GenerateGUID(false)
	employee:SetCarrying(record)

	return "ToGrill"
end

-- Walks over to a cook someone else started and takes it on. The timing is solved on arrival, so it can only ever pull from the moment it actually got there.
Cooker.ToTend = function(employee, now: number): string?
	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
	local record = data and data.Grillers[employee._grillUid]

	-- Taken off, or settled by the player while this one was walking over
	if not record then
		employee:ReleaseStations()
		return "Idle"
	end

	local result = walkToStation(employee, now, employee._grillUid, "Tend")
	if result == "Tend" then
		scheduleCook(employee, record, now)
	end

	return result
end

Cooker.ToGrill = function(employee, now: number): string?
	return walkToStation(employee, now, employee._grillUid, "Place", employee:GetActionOverhead())
end

-- Lights the cook and solves when to pull it, once, off this employee's star.
Cooker.Place = function(employee, now: number): string?
	if not GrillerManager:PlaceSkewerOnGriller(employee.Player, employee._grillUid, employee.Record.Carrying) then
		employee:ReleaseStations()
		return "Idle"
	end

	employee:SetCarrying(nil)

	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
	scheduleCook(employee, data and data.Grillers[employee._grillUid], now)

	return "Tend"
end

-- Waits out the cook. The griller is re-read every tick, since the player can pick it up out from under it.
Cooker.Tend = function(employee, now: number): string?
	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
	if not (data and data.Grillers[employee._grillUid]) then
		employee:ReleaseStations()
		return "Idle"
	end

	-- Waits square on the grill's front or back rather than wherever it walked up from, so a line of
	-- them reads as staff working a row of grills. Solved once: StepWalk holds the target
	local model = employee:GetStructureModel(employee._grillUid)
	if model then
		local result = employee:StepWalk(
			now,
			employee._walkTarget or employee:GetFacePosition(model),
			Employees.TEND_ARRIVE_DISTANCE
		)

		if result ~= "walking" then
			employee:FaceTowards(model:GetPivot().Position)
		end
	end

	if now < employee._reachAt then
		return nil
	end

	-- The reach is an action like any other, so it costs the same overhead and shows its own countdown
	employee:Dwell(now, employee:GetActionOverhead())

	return "Pull"
end

-- Takes the cook off and settles it. Nil back means the player pulled it first, which costs this run and nothing else.
Cooker.Pull = function(employee, _now: number): string?
	-- The moment solved at Place, not the moment the reach ended, so a tick's jitter can't cost the cook
	local record =
		GrillerManager:TakeSkewerFromGriller(employee.Player, employee._grillUid, employee._pullAt)

	if not record then
		employee:ReleaseStations()
		return "Idle"
	end

	employee:ReleaseStations()

	-- A grill mints too, so the estimate the customer is shown can't be re-rolled off the old skewer's uid
	record.Uid = HttpService:GenerateGUID(false)
	employee:SetCarrying(record)

	-- Said outright rather than left to the chatter roll: the state flips to ToSell in the same tick, so a
	-- roll would almost never catch the skewer in hand, and reacting to the cook is the payoff of the whole run
	employee:Say("Pull", StickModel.GetCookStateId(record))

	return "ToSell"
end

Cooker.ToSell = function(employee, now: number): string?
	local baseModel = employee:GetBaseModel()
	local stalls = baseModel and baseModel:FindFirstChild("Stalls")
	local sellStall = stalls and stalls:FindFirstChild("SellStall")
	local stand = sellStall and sellStall:FindFirstChild("SkewerStand")

	-- Nothing to walk to, so it holds on to the skewer and tries again rather than dropping it
	if not stand then
		return "Idle"
	end

	local result = employee:StepWalk(now, employee._walkTarget or employee:GetApproachPosition(stand))
	if result == "arrived" then
		employee:FaceTowards(stand.Position)
		employee:Dwell(now, employee:GetActionOverhead())
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

	if SkewerStandManager:PlaceSkewerRecord(employee.Player, data, employee.Record.Carrying) then
		employee:SetCarrying(nil)
	end

	return "Idle"
end

return Cooker
