-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Managers
local NotificationManager = require(script.Parent.NotificationManager)

-- Modules
local Employee = require(script.Employee)
local NpcRig = require(script.Parent.Parent.Modules.NpcRig)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local RandomUtil = require(Shared.RandomUtil)
local Employees = require(Shared.Config.Employees)
local Rating = require(Shared.Config.Rating)
local EmployeeHut = require(Shared.Config.EmployeeHut)

-- Assets
local EmployeeFolder = ServerStorage.Assets:FindFirstChild("Employees")

--
local PlayerDataManager
local BaseManager
local StickManager
local IngredientManager

-- The hired staff: the roster, the claims that stop two of them chasing one station, and the tick that steps every state machine. One employee's own behaviour lives on the Employee class.

--
local EmployeeManager = {
	EmployeeSayEvent = Network.Event("EmployeeSay"),
	EquipEmployeeEvent = Network.Event("EquipEmployee"), -- client -> server (uid, slot)
	UnequipEmployeeEvent = Network.Event("UnequipEmployee"), -- client -> server (uid)

	_employees = {}, -- [player] = { [uid] = Employee }, the equipped ones only
	-- [player] = { ["<role>:<structureUid>"] = employeeUid }, so a station is worked by one of each role
	_claims = {},
	_equipping = {}, -- [player] = true across an equip's read -> write window, so a mashed card equips once
}

-- Puts a line in an employee's chat bubble. The category and the rig go out; the client owns picking the line and drawing it, as the customers' own dialogue does.
function EmployeeManager:SpeakEmployee(rig: Model, category: string, variant: string?)
	self.EmployeeSayEvent:FireAllClients(rig, category, variant)
end

-- Takes a station for one employee, within its own role. False when another of that role already holds it, which is the caller's cue to look elsewhere.
function EmployeeManager:ClaimStation(player: Player, role: string, uid: string, employeeUid: string): boolean
	local claims = self._claims[player]
	if not claims then
		claims = {}
		self._claims[player] = claims
	end

	-- Scoped by role, since two roles wanting one station isn't a conflict but a pipeline: a cooker stood
	-- waiting at a stand is exactly the stand a maker should be filling. Two of the same role still collide
	local key = `{role}:{uid}`

	if claims[key] and claims[key] ~= employeeUid then
		return false
	end

	claims[key] = employeeUid

	return true
end

-- Where one employee sits among the player's others of its role, 1 upward, oldest hire first. The roster is a dictionary, so it's counted rather than iterated for -- an order that shuffles between ticks would have two of them swapping places at a shared post forever.
function EmployeeManager:GetRoleIndex(player: Player, role: string, uid: string): number
	local employees = self._employees[player]
	local employee = employees and employees[uid]
	if not employee then
		return 1
	end

	local hiredAt = employee.Record.HiredAt or 0
	local index = 1

	for otherUid, other in employees do
		if otherUid == uid or other.Record.Role ~= role then
			continue
		end

		-- The uid breaks the tie, so two hired in the same tick still land on an order both agree on
		local otherHiredAt = other.Record.HiredAt or 0
		if otherHiredAt < hiredAt or (otherHiredAt == hiredAt and otherUid < uid) then
			index += 1
		end
	end

	return index
end

function EmployeeManager:ReleaseStation(player: Player, role: string, uid: string)
	local claims = self._claims[player]
	if claims then
		claims[`{role}:{uid}`] = nil
	end
end

-- Drops every station one employee holds, so an abandoned run never strands a grill nobody can use.
function EmployeeManager:ReleaseStations(player: Player, employeeUid: string)
	local claims = self._claims[player]
	if not claims then
		return
	end

	for uid, holder in claims do
		if holder == employeeUid then
			claims[uid] = nil
		end
	end
end

-- The uid of whoever is equipped in `slot`, or nil while it's empty. Scanned rather than stored, so a slot can never disagree with the worker in it.
function EmployeeManager:GetEmployeeInSlot(data, slot: number): string?
	for uid, record in data.Employees do
		if record.Slot == slot then
			return uid
		end
	end

	return nil
end

-- Puts one equipped employee on the roster and its rig in the world. An unequipped one is left off entirely, so equipping it later is an ordinary add.
function EmployeeManager:AddEmployee(player: Player, uid: string, record: Employees.Employee, data)
	if not record.Slot then
		return
	end

	local employees = self._employees[player]
	if not employees then
		employees = {}
		self._employees[player] = employees
	end

	-- Already on the roster: a second base handover shouldn't clone a rig for someone already working
	if employees[uid] then
		return
	end

	local employee = Employee.new(self, player, uid, record)
	employees[uid] = employee

	employee:Spawn(data)
end

-- Takes one employee's rig out of the world and off the roster, letting go of any station it held.
function EmployeeManager:RemoveFromRoster(player: Player, uid: string)
	local employees = self._employees[player]
	local employee = employees and employees[uid]
	if not employee then
		return
	end

	self:ReleaseStations(player, uid)
	employee:Destroy()
	employees[uid] = nil
end

-- Equips one employee into a hut slot, or unequips it with a nil `slot`. The seam the hut panel drives; nothing else about them changes.
function EmployeeManager:SetEmployeeSlot(player: Player, uid: string, slot: number?): boolean
	if self._equipping[player] then
		return false
	end
	self._equipping[player] = true

	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	local record = hasData and data.Employees[uid]
	if not record then
		self._equipping[player] = nil
		return false
	end

	-- Refused without a toast: the panel only offers an unlocked empty slot, and only workers not already in one
	local refused = if slot == nil
		then record.Slot == nil
		else type(slot) ~= "number"
			or slot % 1 ~= 0
			or slot < 1
			or slot > #EmployeeHut.SLOT_PRICES
			or not data.HutRepaired
			or not EmployeeHut.IsSlotUnlocked(slot, data.HutSlotsUnlocked)
			or record.Slot ~= nil
			or self:GetEmployeeInSlot(data, slot) ~= nil

	if refused then
		self._equipping[player] = nil
		return false
	end

	PlayerDataManager:SetPlayerDataKey(player, { "Employees", uid, "Slot" }, slot)

	-- Carrying and Load stay on the record while unequipped, so a worker put back picks up what it was holding
	if slot then
		self:AddEmployee(player, uid, data.Employees[uid], data)
	else
		self:RemoveFromRoster(player, uid)
	end

	self._equipping[player] = nil

	NotificationManager:NotifyNormal(player, {
		Text = if slot then `Equipped {record.Name}!` else `Unequipped {record.Name}`,
		Duration = 3,
		Sound = "Notify",
		Effect = "Success",
	})

	return true
end

-- Bakes one employee's portrait into its owner's PlayerGui, for the hut panel to draw. Yields on the dress, so callers spawn it.
function EmployeeManager:BakeEmployeePortrait(player: Player, uid: string, record: Employees.Employee)
	local template = EmployeeFolder and EmployeeFolder:FindFirstChild(record.Body)
	if not template then
		return
	end

	-- A second base handover resumes the roster again, and one portrait per worker is all the panel needs
	local existing = player.PlayerGui:FindFirstChild(Employees.PORTRAIT_FOLDER)
	if existing and existing:FindFirstChild(uid) then
		return
	end

	local baked, err = NpcRig.BakePortrait(template, record.Cosmetics)

	if err then
		warn(`[EmployeeManager] {record.Name}'s portrait couldn't be dressed: {err}`)
	end

	if not baked then
		return
	end

	-- The dress yields, and they can have left or fired this one in the meantime
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData or not data.Employees[uid] or not player.Parent then
		baked:Destroy()
		return
	end

	local folder = player.PlayerGui:FindFirstChild(Employees.PORTRAIT_FOLDER)
	if not folder then
		-- A ScreenGui rather than a Folder, so ResetOnSpawn can keep the portraits through a respawn
		folder = Instance.new("ScreenGui")
		folder.Name = Employees.PORTRAIT_FOLDER
		folder.ResetOnSpawn = false
		folder.Enabled = false
		folder.Parent = player.PlayerGui
	end

	-- Two bakes racing past the check above both land here, so the later one replaces rather than doubles
	local stale = folder:FindFirstChild(uid)
	if stale then
		stale:Destroy()
	end

	baked.Name = uid
	baked.Parent = folder
end

-- Hires one employee, unequipped. `stars` is on the 0-5 scale the player reads. `options` carries what the board already showed them -- the name and look it displayed -- and `Equip` to put one straight into the first empty slot, which is the admin grant's business and not the shop's.
function EmployeeManager:HireEmployee(
	player: Player,
	role: string,
	body: string,
	stars: number,
	options: { Name: string?, Cosmetics: { Hair: string?, Hat: string?, Head: string?, Skin: string? }?, Equip: boolean? }?
): (boolean, string?)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return false, "Their data hasn't loaded yet."
	end

	-- Unlocks aren't checked, so a grant still goes to work on a base with no hut to have unlocked one
	local slot = nil
	if options and options.Equip then
		for index = 1, #EmployeeHut.SLOT_PRICES do
			if not self:GetEmployeeInSlot(data, index) then
				slot = index
				break
			end
		end
	end

	local uid = HttpService:GenerateGUID(false)
	local record = {
		Role = role,
		-- Stored 0-1, so Rating owns the star scale and retuning it moves everyone already hired
		Skill = math.clamp(stars / Rating.MAX_STARS, 0, 1),
		Body = body,
		Name = options and options.Name or RandomUtil.GetRandomFromArray(Employees.GetNames(body)),
		Cosmetics = options and options.Cosmetics or {},
		Slot = slot,
		HiredAt = workspace:GetServerTimeNow(),
	}

	PlayerDataManager:SetPlayerDataKey(player, { "Employees", uid }, record)

	self:AddEmployee(player, uid, record, data)

	task.spawn(function()
		self:BakeEmployeePortrait(player, uid, record)
	end)

	return true, `Hired {record.Name}, a {Rating.ToStars(record.Skill)} star {role}, for {player.Name}.`
end

-- Fires one employee for good, equipped or not. Anything in their hands goes back to the player rather than off the books.
function EmployeeManager:FireEmployee(player: Player, uid: string): boolean
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	local record = hasData and data.Employees[uid]
	if not record then
		return false
	end

	-- Skipped equipping: they're being handed a skewer they didn't ask for, mid-whatever they were doing
	if record.Carrying then
		StickManager:AddFilledStick(player, record.Carrying, true)
	end

	-- A maker's fetched load goes to the player rather than back to the hut, which may since have been picked up
	local load = record.Load
	if load then
		if load.StickId then
			StickManager:GrantStick(player, load.StickId, 1, true)
		end

		for _, ingredientId in load.Ingredients do
			IngredientManager:GrantIngredient(player, ingredientId, 1)
		end
	end

	self:RemoveFromRoster(player, uid)

	local portraits = player.PlayerGui:FindFirstChild(Employees.PORTRAIT_FOLDER)
	local portrait = portraits and portraits:FindFirstChild(uid)
	if portrait then
		portrait:Destroy()
	end

	PlayerDataManager:SetPlayerDataKey(player, { "Employees", uid }, nil)

	return true
end

-- Fires the player's whole roster, so testing doesn't mean wiping their data. Returns how many went.
function EmployeeManager:FireAllEmployees(player: Player): number
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return 0
	end

	local fired = 0

	-- Over a snapshot, since firing removes from the table being walked
	local uids = {}
	for uid in data.Employees do
		table.insert(uids, uid)
	end

	for _, uid in uids do
		if self:FireEmployee(player, uid) then
			fired += 1
		end
	end

	return fired
end

-- Puts the player's equipped staff back to work and bakes every worker's portrait. Off the base handover, since a rig needs somewhere to stand.
function EmployeeManager:ResumeEmployees(player: Player)
	local hasData, data = PlayerDataManager:GetPlayerData(player):await()
	if not hasData then
		return
	end

	for uid, record in data.Employees do
		self:AddEmployee(player, uid, record, data)

		-- Each off its own thread, since a dress yields on its asset fetch
		task.spawn(function()
			self:BakeEmployeePortrait(player, uid, record)
		end)
	end
end

-- Takes a leaving player's rigs out of the world. What they were carrying stays in their data, so it comes back with them.
function EmployeeManager:_cleanupPlayer(player: Player)
	local employees = self._employees[player]
	if employees then
		for _, employee in employees do
			employee:Destroy()
		end

		self._employees[player] = nil
	end

	self._claims[player] = nil
	self._equipping[player] = nil
end

function EmployeeManager:OnInit()
	PlayerDataManager = require(script.Parent.PlayerDataManager)
	BaseManager = require(script.Parent.BaseManager)
	StickManager = require(script.Parent.StickManager)
	IngredientManager = require(script.Parent.IngredientManager)
end

function EmployeeManager:OnStart()
	self.EquipEmployeeEvent:OnServerEvent(function(player: Player, uid: string, slot: number)
		self:SetEmployeeSlot(player, uid, slot)
	end)

	self.UnequipEmployeeEvent:OnServerEvent(function(player: Player, uid: string)
		self:SetEmployeeSlot(player, uid, nil)
	end)

	-- Off the handover rather than PlayerAdded, since a rig has to be stood somewhere on a base they own
	BaseManager.OnBaseAssigned:Connect(function(player: Player)
		self:ResumeEmployees(player)
	end)

	-- This manager can load after a player is already on a base, so sweep whoever is here
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:ResumeEmployees(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_cleanupPlayer(player)
	end)

	-- One loop for every employee in the server. A step can yield, so each guards itself and is skipped while busy
	task.spawn(function()
		while true do
			task.wait(Employees.TICK_INTERVAL)

			-- The synced clock, not os.clock: these deadlines are published for a client to count down
			local now = workspace:GetServerTimeNow()

			for _, employees in self._employees do
				for _, employee in employees do
					employee:Step(now)
				end
			end
		end
	end)
end

return EmployeeManager
