-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

-- Managers
local CollisionManager = require(script.Parent.Parent.CollisionManager)
local PlayerDataManager = require(script.Parent.Parent.PlayerDataManager)

-- Modules
local NpcRig = require(script.Parent.Parent.Parent.Modules.NpcRig)

-- Shared
local Shared = ReplicatedStorage.Shared
local StickModel = require(Shared.StickModel)
local StickIngredients = require(Shared.StickIngredients)
local Animations = require(Shared.Animations)
local RandomUtil = require(Shared.RandomUtil)
local Sticks = require(Shared.Config.Sticks)
local Ingredients = require(Shared.Config.Ingredients)
local Structures = require(Shared.Config.Structures)
local Plots = require(Shared.Config.Plots)
local Rating = require(Shared.Config.Rating)
local EmployeeHut = require(Shared.Config.EmployeeHut)
local Employees = require(Shared.Config.Employees)

-- Roles
local Roles = {
	[Employees.ROLES.COOKER] = require(script.Parent.Roles.Cooker),
	[Employees.ROLES.SELLER] = require(script.Parent.Roles.Seller),
	[Employees.ROLES.BBQ_MAKER] = require(script.Parent.Roles.BbqMaker),
}

-- Assets
local EmployeeFolder = ServerStorage.Assets:FindFirstChild("Employees")

if not EmployeeFolder then
	warn(`ServerStorage.Assets.Employees is missing, no employee will spawn`)
end

-- Its own, so two employees picking a spot to stroll to in the same frame don't share a sequence
local rng = Random.new()

-- One hired employee: its rig, where it is in its role's state machine, and the skewer in its hands. The manager owns the roster and the tick; this owns one worker.

--
local Employee = {}
Employee.__index = Employee

-- Builds a handle for one hired employee. The rig isn't spawned until Spawn, so a hire off a base is harmless.
function Employee.new(manager, player: Player, uid: string, record: Employees.Employee)
	local states = Roles[record.Role]

	local self = setmetatable({
		Manager = manager, -- the roster owns station claims, so two cookers can't chase one grill
		Player = player,
		Uid = uid,
		Record = record,
		-- The role's own opening state: a seller has no Idle, and starting one there would leave it standing
		-- in a state with no handler, which reads as an employee that simply never does anything
		State = states and states.Initial or "Idle",

		_rig = nil,
		_humanoid = nil,
		-- What it's carrying, above its head: a skewer, or the maker's pile of stock
		_skewerModel = nil,
		_carryTrack = nil, -- the hands-full pose, held for as long as the model above is

		-- A step can yield on a data read, so one in flight is skipped rather than run twice
		_busy = false,
		_dwellUntil = 0,
		-- A wait the billboard counts down that isn't a dwell, so a solved wait can still be spent on its feet
		_countdownUntil = 0,
		_nextPollAt = 0,

		_walkTarget = nil,
		_walkDeadline = 0,

		_wanderTarget = nil, -- where it's strolling to while idle, and when it may pick the next spot
		_wanderPauseUntil = 0,
		_faced = false, -- whether it has already turned to face this state's target
		_nextSpeakAt = 0, -- the earliest it may say something, re-rolled every time it's eligible
		-- A role's own read on its situation, picking a `{Category}{Variant}` sibling over the carried skewer's
		_speakVariant = nil,

		_publishedDeadline = nil, -- the last deadline written to the rig, so a tick only writes on a change

		-- Every cook a cooker is timing, by griller uid: when it comes off, when to reach for it, when its
		-- window opens, and the light it was solved against. More than one only up the GRILL_MARKS ladder
		_cooks = {},
		_standUid = nil, -- the stick stand it has claimed, and the griller this leg is about
		_grillUid = nil,

		_hutUid = nil, -- the hut a maker is drawing from, and the stand it's building on
		_buildUid = nil,

		_servingNpc = nil, -- the customer a seller is dealing with, and where it's got to with them
		_answeredRound = nil,
		_dwellRound = nil,
		_closing = false, -- true once it has taken a deal, so the customer leaving reads as a sale
	}, Employee)

	return self
end

-- This employee's rating as the player reads it, so the star scale is Rating's to own for everyone.
function Employee:GetStars(): number
	return Rating.ToStars(self.Record.Skill)
end

-- One of the config's worst/best/gamma curves, resolved against this employee's skill.
function Employee:GetCurveValue(worst: number, best: number, gamma: number): number
	return Employees.InterpolateBySkill(worst, best, gamma, self.Record.Skill)
end

-- The player's base model, or nil while they have no base in the world.
function Employee:GetBaseModel(): Model?
	local baseId = self.Player:GetAttribute("BaseId")
	return baseId and workspace.Base:FindFirstChild(baseId)
end

-- One of the base's authored Core parts, where the marker parts every NPC system posts to live.
function Employee:GetCorePart(name: string): BasePart?
	local baseModel = self:GetBaseModel()
	local core = baseModel and baseModel:FindFirstChild("Core")

	return core and core:FindFirstChild(name)
end

-- The base's sell stand part, where a cooker puts BBQ out and a seller minds the counter. Nil while the base has no stall.
function Employee:GetSellStandPart(): BasePart?
	local baseModel = self:GetBaseModel()
	local stalls = baseModel and baseModel:FindFirstChild("Stalls")
	local sellStall = stalls and stalls:FindFirstChild("SellStall")

	return sellStall and sellStall:FindFirstChild("SkewerStand")
end

-- A placed structure's model, found by uid. Every structure is named for its uid, so this needs no cache.
function Employee:GetStructureModel(uid: string): Model?
	local baseModel = self:GetBaseModel()
	local folder = baseModel and baseModel:FindFirstChild(Structures.FOLDER_NAME)

	return folder and folder:FindFirstChild(uid)
end

-- The hut they were hired out of, if one is still placed. What a maker hangs around, since its job starts and ends at the store.
function Employee:GetHomeModel(data): Model?
	for uid, placed in data.Structures do
		if placed.Type == EmployeeHut.STRUCTURE_ID then
			local model = self:GetStructureModel(uid)
			if model then
				return model
			end
		end
	end

	return nil
end

-- Where it waits for work: its hut if one is placed, else the base's customer spawn.
function Employee:GetHomePosition(data): Vector3?
	local hut = self:GetHomeModel(data)
	if hut then
		return hut:GetPivot().Position
	end

	local spawnPart = NpcRig.GetBaseParts(self.Player)
	return spawnPart and spawnPart.Position
end

-- A spot just clear of `station`'s edge, so it works a grill from beside rather than standing on top of it. Solved once per walk, since it's measured from wherever the employee set off.
function Employee:GetApproachPosition(station: Instance): Vector3
	local pivot = station:GetPivot()
	local size = if station:IsA("Model") then station:GetExtentsSize() else (station :: BasePart).Size
	local reach = math.max(size.X, size.Z) / 2 + Employees.STATION_CLEARANCE

	-- Approached from whichever side it's already on, so it never crosses the station to reach the far face
	local offset = (self._humanoid.RootPart.Position - pivot.Position) * Vector3.new(1, 0, 1)
	local direction = if offset.Magnitude > 0.1 then offset.Unit else pivot.LookVector

	return pivot.Position + direction * reach
end

-- A spot square on `station`'s front or back face, whichever side it's already on. Measured off the model's own bounding box, so a rotated grill is squared up to rather than the world's axes.
function Employee:GetFacePosition(station: Model): Vector3
	local cframe, size = station:GetBoundingBox()
	local reach = size.Z / 2 + Employees.STATION_CLEARANCE

	-- The station's own depth axis, so front and back are its faces rather than the base's
	local depth = cframe.LookVector
	local side = if (self._humanoid.RootPart.Position - cframe.Position):Dot(depth) >= 0 then 1 else -1

	return cframe.Position + depth * (reach * side)
end

-- A random spot on a plot they own, so an idle employee has somewhere to stroll that's always inside the base.
function Employee:PickWanderPoint(data): Vector3?
	local baseModel = self:GetBaseModel()
	local folder = baseModel and baseModel:FindFirstChild(Plots.FOLDER_NAME)
	if not folder then
		return nil
	end

	local floors = {}

	for _, plotModel in folder:GetChildren() do
		-- IsOwned already counts the starting cell as theirs, so this covers a fresh base too
		if not Plots.IsOwned(plotModel.Name, data.Plots) then
			continue
		end

		local floor = plotModel:FindFirstChild(Plots.FLOOR_NAME, true)
		if floor and floor:IsA("BasePart") then
			table.insert(floors, floor)
		end
	end

	local floor = RandomUtil.GetRandomFromArray(floors, nil, rng)

	return floor and NpcRig.RandomPointOn(floor, rng)
end

-- A random spot within `radius` of `center`, for a role that hangs around one place rather than the whole base.
function Employee:PickPointNear(center: Vector3, radius: number): Vector3
	local angle = rng:NextNumber(0, math.pi * 2)

	-- Square-rooted, or the points bunch in the middle rather than spreading over the circle
	local distance = radius * math.sqrt(rng:NextNumber())

	return center + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

-- A random spot in the ring around `station`, clear of its footprint by the same margin it works one from. For a role that hangs about a building rather than standing inside it.
function Employee:PickPointAround(station: Instance, spread: number): Vector3
	local pivot = station:GetPivot()
	local size = if station:IsA("Model") then station:GetExtentsSize() else (station :: BasePart).Size
	local inner = math.max(size.X, size.Z) / 2 + Employees.STATION_CLEARANCE

	local angle = rng:NextNumber(0, math.pi * 2)

	-- Sampled across the squared band, or the points bunch against the inner wall rather than spreading
	local distance = math.sqrt(rng:NextNumber(inner * inner, (inner + spread) * (inner + spread)))

	return pivot.Position + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

-- Strolls between jobs, pausing at each spot, so an employee with nothing to do still looks employed. `pick` overrides where it goes, for a role that stays near its own station rather than roaming the plots.
function Employee:StepWander(now: number, data, pick: (() -> Vector3?)?)
	if self._wanderTarget then
		-- Arrived or gave up: either way it stands a moment before choosing somewhere else
		if self:StepWalk(now, self._wanderTarget) ~= "walking" then
			self._wanderTarget = nil
			self._wanderPauseUntil =
				now + rng:NextNumber(Employees.WANDER_PAUSE_MIN, Employees.WANDER_PAUSE_MAX)
		end

		return
	end

	if now >= self._wanderPauseUntil then
		self._wanderTarget = if pick then pick() else self:PickWanderPoint(data)
	end
end

-- Puts the rig in the world and fades it in. Silently does nothing without a template or a base to stand on.
function Employee:Spawn(data): boolean
	local template = EmployeeFolder and EmployeeFolder:FindFirstChild(self.Record.Body)
	if not template then
		warn(`Assets.Employees.{self.Record.Body} is missing, {self.Record.Name} won't spawn`)
		return false
	end

	local home = self:GetHomePosition(data)
	if not home then
		return false
	end

	local rig = template:Clone()
	rig.Name = self.Record.Name

	-- Passes through players, other NPCs and structures, so a base full of grills never boxes it in
	CollisionManager:SetModelGroup(rig, CollisionManager.NPC)

	-- Whole or not at all: under default mode the tag lands on the client before the head it hangs UI off
	rig.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	-- Worth checking: the templates are authored in the place file rather than synced, so a rig can arrive rigless
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warn(`Assets.Employees.{self.Record.Body} has no Humanoid, {self.Record.Name} can't work`)
		rig:Destroy()
		return false
	end

	humanoid.WalkSpeed =
		self:GetCurveValue(Employees.WALK_SPEED_WORST, Employees.WALK_SPEED_BEST, Employees.WALK_SPEED_GAMMA)

	-- Primed while still parked, so it fades in rather than popping
	NpcRig.Fade(rig, true, Employees.FADE_DURATION)
	rig:PivotTo(CFrame.new(home + Vector3.new(0, 3, 0)))

	-- Stamped before it lands, so it arrives with the rig rather than a frame behind it
	rig:SetAttribute(Structures.OWNER_ATTRIBUTE, self.Player.UserId)
	rig:SetAttribute(Employees.UID_ATTRIBUTE, self.Uid)
	rig:SetAttribute(Employees.ROLE_ATTRIBUTE, self.Record.Role)
	rig:SetAttribute(Employees.STATE_ATTRIBUTE, self.State)
	rig.Parent = workspace

	-- Server-driven movement, so hand the root to the server rather than a nearby client
	local rootPart = rig:FindFirstChild("HumanoidRootPart")
	if rootPart and not rootPart.Anchored then
		rootPart:SetNetworkOwner(nil)
	end

	rig:AddTag(Employees.TAG)

	self._rig = rig
	self._humanoid = humanoid

	-- Dressed once it's landed rather than while it's still parked: applying a look yields, and the guards
	-- inside need a parented rig and a set _rig to tell "still theirs" from "fired while that was in flight"
	self:ApplyCosmetics(rig)

	-- Carrying survives a rejoin, so a rig coming back mid-pipeline picks its skewer straight back up
	if self.Record.Carrying then
		self:GiveSkewer(self.Record.Carrying)
	end

	return true
end

-- Dresses the rig in the hair and face it was hired wearing. Spawned rather than awaited: applying a look yields on the asset fetch, and Spawn is stepped down a whole roster on one thread.
function Employee:ApplyCosmetics(rig: Model)
	local cosmetics = self.Record.Cosmetics
	if not (cosmetics.Hair or cosmetics.Hat or cosmetics.Head or cosmetics.Skin) then
		return
	end

	task.spawn(function()
		-- Guarded, since these are catalogue ids: one bad one would otherwise strand the rig half-dressed
		local success, err = NpcRig.ApplyLook(rig, cosmetics)

		-- That yields, and a fire, a leave or a base handover in the meantime has already replaced this rig.
		-- Both checks earn their place: the first catches a respawn, the second a plain destroy
		if self._rig ~= rig or rig.Parent == nil then
			return
		end

		if not success then
			warn(`[EmployeeManager] {self.Record.Name}'s cosmetics wouldn't apply: {err}`)
			return
		end

		-- Applying a look rebuilds the rig's accessory parts, so the collision group has to be stamped again
		CollisionManager:SetModelGroup(rig, CollisionManager.NPC)

		-- Only what just arrived: the body has already faded in, and fading it again reads as a flicker
		NpcRig.Fade(rig, true, Employees.FADE_DURATION, true)
	end)
end

-- Puts the carried skewer in its hand. Reuses the customer tool, so it's held exactly as a customer holds one.
function Employee:GiveSkewer(record: StickModel.StickRecord)
	self:DropSkewer()

	-- Over the head rather than on the tool, which is where a player carries theirs anyway. A handled tool
	-- rides the arm's Motor6D, so the carry pose lays the skewer flat the moment it plays
	local model = StickModel.BuildStickModel(record)
	if not model then
		return
	end

	model:ScaleTo(Employees.CARRY_SKEWER_SCALE)

	self._skewerModel = NpcRig.GiveOverhead(self._rig, model, Employees.CARRY_HOLD_HEIGHT)

	self:PlayCarryPose()
end

-- Puts the hands-full pose on. Held until DropSkewer takes it off, so it covers the whole walk rather than firing once at the pickup.
function Employee:PlayCarryPose()
	self._carryTrack = NpcRig.PlayAnimationId(self._rig, Animations.EmployeeCarry, "EmployeeCarry")
end

-- Takes whatever it's holding out of its hand. Safe to call empty-handed, which is how every state clears up.
function Employee:DropSkewer()
	NpcRig.StopAnimationTrack(self._carryTrack)
	self._carryTrack = nil

	if self._skewerModel then
		self._skewerModel:Destroy()
		self._skewerModel = nil
	end
end

-- Builds the pile a maker walks with: the stick laid flat, the ingredients stacked over it. Every piece is normalised to one size first, or a grape and a gold stick would read as wildly different things.
function Employee:BuildLoadModel(load): Model?
	local container = Instance.new("Model")
	container.Name = "CarriedLoad"

	local height = 0

	-- Seats one piece at `height` up the pile and returns where the next one starts
	local function stack(source: Model, rotation: CFrame?): number
		local piece = source:Clone()
		local turn = rotation or CFrame.identity

		local _, size = piece:GetBoundingBox()

		-- How tall it stands once turned, rather than how long it is. A bounding box is measured along the
		-- model's own pivot and travels with it, so turning one first tells you nothing: the sides have to be
		-- projected onto the pile's axis instead. A stick laid flat takes the room it's thick, not its length
		local rise = math.abs(turn.XVector.Y) * size.X
			+ math.abs(turn.YVector.Y) * size.Y
			+ math.abs(turn.ZVector.Y) * size.Z

		local seat = CFrame.new(0, height + rise / 2, 0) * turn
		piece:PivotTo(seat * StickIngredients.GetPivotToCenter(piece):Inverse())
		piece.Parent = container

		return height + rise * Employees.CARRY_STACK_STEP
	end

	-- The stick goes on the bottom, laid across the stack rather than standing up it: sticks are authored
	-- along the same axis the pile grows, so an upright one is nearly as tall as the rig carrying it
	local stick = load.StickId and Sticks.GetStickFromId(load.StickId)
	if stick then
		height = stack(stick.Model, Employees.CARRY_STICK_ROTATION)
	end

	for _, ingredientId in load.Ingredients do
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)
		if ingredient then
			height = stack(ingredient.Model, nil)
		end
	end

	if height == 0 then
		container:Destroy()
		return nil
	end

	-- A root of its own, sat in the frame the pile was built in. Borrowing a piece's part instead makes the
	-- pivot carry whatever rotation that ingredient was authored at, which lays the whole stack on its side
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.one * 0.1
	root.Transparency = 1
	root.CanCollide = false
	root.CFrame = CFrame.identity
	root.Parent = container

	container.PrimaryPart = root

	return container
end

-- Writes the stock it fetched, so a rejoin or a crash mid-trip can't destroy what it took out of a hut.
function Employee:SetLoad(load)
	self.Record.Load = load
	PlayerDataManager:SetPlayerDataKey(self.Player, { "Employees", self.Uid, "Load" }, load)

	self:DropSkewer()

	if load and (load.StickId or #load.Ingredients > 0) then
		local model = self:BuildLoadModel(load)

		-- Over the head rather than in the hands: a pile is what a player carries their own stock as, and
		-- nothing about an arm's hold pose can lean it over
		if model then
			self._skewerModel = NpcRig.GiveOverhead(self._rig, model, Employees.CARRY_HOLD_HEIGHT)
			self:PlayCarryPose()
		end
	end
end

-- Writes what it's carrying, so a crash or a rejoin mid-pipeline resumes rather than destroying the skewer.
function Employee:SetCarrying(record: StickModel.StickRecord?)
	self.Record.Carrying = record
	PlayerDataManager:SetPlayerDataKey(self.Player, { "Employees", self.Uid, "Carrying" }, record)

	if record then
		self:GiveSkewer(record)
	else
		self:DropSkewer()
	end
end

-- Takes a station for this employee's use within its role. False when another of the same role holds it.
function Employee:ClaimStation(uid: string): boolean
	return self.Manager:ClaimStation(self.Player, self.Record.Role, uid, self.Uid)
end

-- Where it sits among the player's others of the same role, 1 upward. Stable between ticks, so a shared post hands it the same slot every time.
function Employee:GetRoleIndex(): number
	return self.Manager:GetRoleIndex(self.Player, self.Record.Role, self.Uid)
end

-- Whether it's between jobs: in its role's opening state with nothing in hand and no cook on the go.
function Employee:IsFree(): boolean
	local states = Roles[self.Record.Role]

	return self.State == (states and states.Initial or "Idle")
		and not self.Record.Carrying
		and not self.Record.Load
		and next(self._cooks) == nil
end

-- Whether another of its role is free for work, so a busy one leaves the next job to them rather than hoarding it.
function Employee:HasFreeColleague(): boolean
	return self.Manager:HasFreeEmployee(self.Player, self.Record.Role, self.Uid)
end

-- Gives one station back while keeping the rest, for a run that's finished with a station but not with its work.
function Employee:ReleaseStation(uid: string)
	self.Manager:ReleaseStation(self.Player, self.Record.Role, uid)
end

-- Drops every station this employee holds, which is how each abandoned run puts its claims back.
function Employee:ReleaseStations()
	self.Manager:ReleaseStations(self.Player, self.Uid)

	self._cooks = {}
	self._standUid = nil
	self._grillUid = nil
	self._buildUid = nil
	self._hutUid = nil
end

-- Moves it to the next state and republishes that onto the rig, which is the only view a debugger gets.
function Employee:SetState(state: string)
	self.State = state
	self._walkTarget = nil
	self._wanderTarget = nil
	self._faced = false
	self._countdownUntil = 0

	self:SetVariant(nil)

	if self._rig then
		self._rig:SetAttribute(Employees.STATE_ATTRIBUTE, state)
	end
end

-- Why it's in the state it's in, where one state covers several reasons. Read by the sign over its head and the line it says, so naming it once keeps the two agreeing.
function Employee:SetVariant(variant: string?)
	if self._speakVariant == variant then
		return
	end

	self._speakVariant = variant

	if self._rig then
		self._rig:SetAttribute(Employees.VARIANT_ATTRIBUTE, variant)
	end
end

-- Mirrors when the current job finishes onto the rig, so the billboard counts down on its own. Written only on a change, since this is read every tick.
function Employee:PublishDeadline(now: number)
	-- Only a wait whose end is already solved gets a clock. A cook still coming up to its window has the
	-- griller's own bar over it, and two clocks on one wait read as two different things happening
	local waitUntil = math.max(self._dwellUntil, self._countdownUntil)
	local deadline = if waitUntil > now then waitUntil else nil

	if deadline ~= self._publishedDeadline then
		self._publishedDeadline = deadline
		self._rig:SetAttribute(Employees.DEADLINE_ATTRIBUTE, deadline)
	end
end

-- Puts a line in its bubble now, whatever the chatter clock says. `variant` picks a `{Category}{Variant}` sibling where one exists, and falls back to the state's own lines where it doesn't.
function Employee:Say(state: string, variant: string?)
	self._nextSpeakAt = workspace:GetServerTimeNow()
		+ rng:NextNumber(Employees.SPEAK_INTERVAL_MIN, Employees.SPEAK_INTERVAL_MAX)

	self.Manager:SpeakEmployee(self._rig, Employees.DIALOGUE_PREFIX .. state, variant)
end

-- Says something about what it's doing, now and then. Rolled on its own clock, so a row of them chatters unevenly rather than in chorus.
function Employee:TrySpeak(now: number)
	if now < self._nextSpeakAt then
		return
	end

	-- Re-rolled whether or not it speaks, or a failed roll would retry every tick until one landed
	self._nextSpeakAt = now + rng:NextNumber(Employees.SPEAK_INTERVAL_MIN, Employees.SPEAK_INTERVAL_MAX)

	if not RandomUtil.RollChance(Employees.SPEAK_CHANCE, rng) then
		return
	end

	-- A role's own reading wins: a seller minding an empty stall has nothing in hand to describe its situation
	local carrying = self.Record.Carrying

	self:Say(self.State, self._speakVariant or (carrying and StickModel.GetCookStateId(carrying)))
end

-- Turns to face `position`, so a station is worked side-on rather than back-to. Once per state: a pivot every tick fights the humanoid's own physics.
function Employee:FaceTowards(position: Vector3)
	if self._faced then
		return
	end

	local pivot = self._rig:GetPivot()
	local look = (position - pivot.Position) * Vector3.new(1, 0, 1)

	-- Standing exactly on it leaves no direction to take, and lookAt would throw on a zero vector
	if look.Magnitude < 0.1 then
		return
	end

	self._faced = true

	-- Told to stop where it stands first, or the tail of the last MoveTo turns it straight back
	self._humanoid:MoveTo(self._humanoid.RootPart.Position)
	self._rig:PivotTo(CFrame.lookAt(pivot.Position, pivot.Position + look.Unit))
end

-- Holds the employee where it is for `seconds`, which is what makes a low star visibly slower at every station.
function Employee:Dwell(now: number, seconds: number)
	self._dwellUntil = now + seconds
end

function Employee:IsDwelling(now: number): boolean
	return now < self._dwellUntil
end

-- Counts the billboard down to `deadline` without holding the employee still, for a wait it spends on its feet.
function Employee:CountDownTo(deadline: number)
	self._countdownUntil = deadline
end

-- Seconds this employee spends taking something off a station, off its star.
function Employee:GetPickupOverhead(): number
	return self:GetCurveValue(
		Employees.PICKUP_OVERHEAD_WORST,
		Employees.PICKUP_OVERHEAD_BEST,
		Employees.PICKUP_OVERHEAD_GAMMA
	)
end

-- Seconds this employee spends putting something down on a station, off its star.
function Employee:GetPlaceOverhead(): number
	return self:GetCurveValue(
		Employees.PLACE_OVERHEAD_WORST,
		Employees.PLACE_OVERHEAD_BEST,
		Employees.PLACE_OVERHEAD_GAMMA
	)
end

-- Steps a walk toward `position`, re-issuing MoveTo so the target can change between ticks -- which is the whole reason NpcRig.WalkTo isn't used here. Returns "walking", "arrived" or "timeout".
function Employee:StepWalk(now: number, position: Vector3, arriveDistance: number?): string
	if self._walkTarget ~= position then
		self._walkTarget = position
		self._walkDeadline = now + Employees.WALK_TIMEOUT
	end

	local rootPart = self._humanoid.RootPart
	local flat = (rootPart.Position - position) * Vector3.new(1, 0, 1)

	if flat.Magnitude <= (arriveDistance or Employees.ARRIVE_DISTANCE) then
		return "arrived"
	end

	-- Given up on rather than retried forever, so one employee stuck on scenery can't stall the pipeline
	if now >= self._walkDeadline then
		return "timeout"
	end

	self._humanoid:MoveTo(position)

	return "walking"
end

-- Whether it's time to look for work again. The gap is its own, so a poor employee is visibly slow to notice a stand fill up rather than merely slow to walk there.
function Employee:ShouldPoll(now: number): boolean
	if now < self._nextPollAt then
		return false
	end

	self._nextPollAt = now
		+ self:GetCurveValue(Employees.NOTICE_WORST, Employees.NOTICE_BEST, Employees.NOTICE_GAMMA)

	return true
end

-- Holds off the next look for work, for a poll that found something it can't act on yet. Not a Dwell: an idle wait has no countdown worth showing, and it should keep strolling rather than stand frozen.
function Employee:DelayPoll(now: number, seconds: number)
	self._nextPollAt = math.max(self._nextPollAt, now + seconds)
end

-- Runs one step of this employee's role. Guarded, since a state can yield on a data read and a throw would strand the rig.
function Employee:Step(now: number)
	if not self._rig then
		return
	end

	self:PublishDeadline(now)
	self:TrySpeak(now)

	if self._busy or self:IsDwelling(now) then
		return
	end

	local states = Roles[self.Record.Role]
	if not states then
		return
	end

	local handler = states[self.State]

	-- A state with no handler is a dead employee, so it's put back on its feet rather than left standing
	if not handler then
		warn(`[EmployeeManager] {self.Record.Name} has no {self.Record.Role} handler for {self.State}`)
		self:SetState(states.Initial or "Idle")

		return
	end

	self._busy = true

	task.spawn(function()
		local success, result = xpcall(handler, debug.traceback, self, now)

		-- The rig can be despawned by a leave while the step above was yielding
		if not success then
			warn(`[EmployeeManager] {self.Record.Name} failed in state {self.State}:\n{result}`)
		elseif result and self._rig then
			self:SetState(result)
		end

		self._busy = false
	end)
end

-- Takes the rig out of the world. The employee itself stays in player data -- this is a despawn, not a firing.
function Employee:Destroy()
	self:DropSkewer()

	-- Fired or despawned mid-haggle: the claim goes back, or the owner's answer buttons stay hidden on a
	-- customer nobody is dealing with any more and the offer just lapses
	if self._servingNpc then
		self._servingNpc:SetAttribute(Employees.SERVED_BY_ATTRIBUTE, nil)
		self._servingNpc = nil
	end

	if self._rig then
		self._rig:Destroy()
		self._rig = nil
	end

	self._humanoid = nil
end

return Employee
