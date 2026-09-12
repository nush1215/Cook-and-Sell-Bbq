-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Employees = require(Shared.Config.Employees)

-- Modules
local BubbleChat = require(script.Parent.Parent.Modules.BubbleChat)

-- Assets
local UI = ReplicatedStorage.Assets.UI

-- The sign over an employee's head: what they're doing, and how long is left of it. Everything it draws comes off the rig's own attributes, so a visitor sees the same as the owner and a rig that streams in part-way through a job draws it straight away.

--
local EmployeeController = {
	EmployeeSayEvent = Network.Event("EmployeeSay"),

	_active = {}, -- [rig] = { Trove, Head, Billboard, RestOffset, Bubbles, Running, State, Timer, Dots, DotsAt }
}

-- Mounts the billboard on an employee's head. Nil only if the rig left the world before its head arrived.
function EmployeeController:_attach(rig: Model)
	if self._active[rig] then
		return
	end

	local template = UI:FindFirstChild(Employees.BILLBOARD_UI)
	if not template then
		warn(`Assets.UI.{Employees.BILLBOARD_UI} is missing, employees won't show what they're doing`)
		return
	end

	-- Held for as long as it takes: under streaming the parts can trail the model by however long the walk over takes
	local head = rig:FindFirstChild("Head")
	while not head and rig.Parent do
		task.wait()
		head = rig:FindFirstChild("Head")
	end

	-- Left while this yielded, or picked up by a second pass in the meantime
	if not head or self._active[rig] then
		return
	end

	local holder = template:Clone()
	local billboard = holder:FindFirstChild(Employees.BILLBOARD_NAME)
	local labels = billboard and billboard:FindFirstChild(Employees.BILLBOARD_HOLDER)
	if not labels then
		holder:Destroy()
		warn(`Assets.UI.{Employees.BILLBOARD_UI} has no {Employees.BILLBOARD_NAME}.{Employees.BILLBOARD_HOLDER}`)
		return
	end

	-- Adorned to the head and parented to the rig, so it goes when the rig does. No buttons here, so it
	-- doesn't need the PlayerGui mounting the customer billboards use to stay clickable
	billboard.Adornee = head

	-- The template's root carries the head offset where it's a positioned instance; otherwise whatever
	-- the billboard itself was authored with already sits where the artist put it
	if holder:IsA("BasePart") or holder:IsA("Attachment") then
		billboard.StudsOffsetWorldSpace = holder.Position
	end

	billboard.Parent = head

	-- Optional, unlike the holder: without it they lose their name badge and still say what they're doing
	local info = labels:FindFirstChild(Employees.BILLBOARD_INFO)

	local trove = Trove.new()
	trove:Add(billboard)

	-- Stopped before it's destroyed (Trove cleans in reverse add order) -- a spring on a dead instance is stepped forever
	trove:Add(function()
		Spr.stop(billboard)
	end)

	local state = {
		Trove = trove,
		Head = head, -- what a chat bubble is spoken over
		Billboard = billboard,
		RestOffset = billboard.StudsOffsetWorldSpace, -- where the raise springs back down to
		Bubbles = 0, -- lines currently up under it, since they can overlap
		Running = true, -- false once detached, so a bubble expiring later doesn't touch a dead billboard
		State = labels:FindFirstChild(Employees.BILLBOARD_STATE),
		Timer = labels:FindFirstChild(Employees.BILLBOARD_TIMER),
		Icon = info and info:FindFirstChild(Employees.BILLBOARD_ROLE_ICON),
		StaffName = info and info:FindFirstChild(Employees.BILLBOARD_STAFF_NAME),
		Dots = 0,
		DotsAt = 0,
	}

	holder:Destroy()
	self._active[rig] = state

	-- A pooled rig would be reparented rather than destroyed, so both are watched
	trove:Connect(rig.AncestryChanged, function()
		if rig.Parent == nil then
			self:_detach(rig)
		end
	end)
	trove:Connect(rig.Destroying, function()
		self:_detach(rig)
	end)

	self:_render(rig, state)
end

function EmployeeController:_detach(rig: Model)
	local state = self._active[rig]
	if not state then
		return
	end

	self._active[rig] = nil
	state.Running = false
	state.Trove:Destroy()
end

-- Springs the billboard clear of the bubbles stacked under it, and back down as they expire.
function EmployeeController:_updateRaise(state)
	local lift = state.RestOffset + Vector3.new(0, Employees.BUBBLE_CLEARANCE * state.Bubbles, 0)

	Spr.target(
		state.Billboard,
		Employees.BUBBLE_RAISE_DAMPING,
		Employees.BUBBLE_RAISE_FREQUENCY,
		{ StudsOffsetWorldSpace = lift }
	)
end

-- Speaks one line over an employee and lifts its sign clear for as long as the bubble is up.
function EmployeeController:_speak(state, category: string, variant: string?)
	local duration = BubbleChat.SayRandom(state.Head, category, variant)

	-- Nil back means the category had no lines, so nothing was said and nothing should move
	if not duration then
		return
	end

	state.Bubbles += 1
	self:_updateRaise(state)

	task.delay(duration, function()
		if state.Running then
			state.Bubbles -= 1
			self:_updateRaise(state)
		end
	end)
end

-- Repaints one employee's sign off the rig's attributes. Called every frame, so it only touches text that moved.
function EmployeeController:_render(rig: Model, state)
	-- The rig is stamped before it's tagged, but its client copy can carry the tag ahead of the stamp
	local stateId = rig:GetAttribute(Employees.STATE_ATTRIBUTE)
	if not stateId then
		return
	end

	local role = rig:GetAttribute(Employees.ROLE_ATTRIBUTE)

	-- Neither of these moves once the rig is stamped, so they're written on a change rather than every frame
	local icon = state.Icon and Employees.ROLE_ICONS[role]
	if icon and state.Icon.Image ~= icon then
		state.Icon.Image = icon
	end

	-- Off the rig's own name, which the server names for the employee when it spawns it
	if state.StaffName and state.StaffName.Text ~= rig.Name then
		state.StaffName.Text = rig.Name
	end

	if state.State then
		local label = Employees.GetStateLabel(role, stateId, rig:GetAttribute(Employees.VARIANT_ATTRIBUTE))

		state.State.Text = label .. string.rep(".", state.Dots)
	end

	if not state.Timer then
		return
	end

	-- Absolute and on the synced clock, so this counts down without the server saying anything more
	local deadline = rig:GetAttribute(Employees.DEADLINE_ATTRIBUTE)
	local remaining = if deadline then deadline - workspace:GetServerTimeNow() else 0

	-- Hidden rather than blanked, so the list layout closes the gap on a job that isn't on a clock
	state.Timer.Visible = remaining > 0
	if remaining > 0 then
		state.Timer.Text = string.format(Employees.TIMER_FORMAT, remaining)
	end
end

function EmployeeController:OnInit()
	-- An employee on any base wires itself up here, whether it landed before this client or streams in later
	CollectionService:GetInstanceAddedSignal(Employees.TAG):Connect(function(rig: Model)
		task.spawn(function()
			self:_attach(rig)
		end)
	end)

	CollectionService:GetInstanceRemovedSignal(Employees.TAG):Connect(function(rig: Model)
		self:_detach(rig)
	end)

	-- _attach waits on the rig's head, so the sweep is kept off this thread
	for _, rig in CollectionService:GetTagged(Employees.TAG) do
		task.spawn(function()
			self:_attach(rig)
		end)
	end
end

function EmployeeController:OnStart()
	-- The server drives when they speak, since it owns the state machine they're talking about
	self.EmployeeSayEvent:OnClientEvent(function(rig: Model, category: string, variant: string?)
		local state = self._active[rig]
		if state then
			self:_speak(state, category, variant)
		end
	end)

	RunService.Heartbeat:Connect(function()
		local now = os.clock()

		for rig, state in self._active do
			-- The dots cycle on their own clock; the countdown wants every frame it can get
			if now - state.DotsAt >= Employees.STATE_DOT_INTERVAL then
				state.DotsAt = now
				state.Dots = state.Dots % Employees.STATE_MAX_DOTS + 1
			end

			self:_render(rig, state)
		end
	end)
end

return EmployeeController
