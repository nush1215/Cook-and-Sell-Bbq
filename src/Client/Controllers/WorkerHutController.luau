-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local EmployeeHut = require(Shared.Config.EmployeeHut)
local Employees = require(Shared.Config.Employees)
local Rating = require(Shared.Config.Rating)

-- Modules
local ViewportPortrait = require(script.Parent.Parent.Modules.ViewportPortrait)

-- Controllers
local UIController = require(script.Parent.UIController)
local PlayerDataController = require(script.Parent.PlayerDataController)
local NotificationController = require(script.Parent.NotificationController)
local ShopController = require(script.Parent.ShopController)

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- The loader runs every OnInit on one thread, so this waits with a timeout rather than hanging the boot
local UI_TIMEOUT = 10

-- How long the panel's buttons stay down after a request, in case the server turns it down and no data change lands
local REQUEST_TIMEOUT = 3

-- Skill is 0-1 and LayoutOrder an integer, so it's scaled up before being negated into a best-first order
local LAYOUT_ORDER_SCALE = 10_000

-- The Worker Hut panel: the hut's slots, bought in order, and the workers equipped into them. Everything drawn is read off player data; the portraits are baked by the server into this player's own PlayerGui.
local WorkerHutController = {
	PurchaseHutSlotEvent = Network.Event("PurchaseHutSlot"),
	EquipEmployeeEvent = Network.Event("EquipEmployee"),
	UnequipEmployeeEvent = Network.Event("UnequipEmployee"),

	_slots = {}, -- [slot] = { Frame, BuyRobux?, PortraitCleaner, Uid? }
	_selectingSlot = nil, -- the slot the worker list is picking for, while it's up
	_requesting = false, -- the client half of the debounce; the server holds the authoritative one
	_workerCleaner = Trove.new(), -- the worker list's cards, rebuilt every time it's shown
}

-- Fires one of the panel's requests behind the client debounce. Freed by the data change it causes, or by the timeout if the server refuses.
function WorkerHutController:_request(event, ...): boolean
	if self._requesting then
		return false
	end

	self._requesting = true
	event:FireServer(...)

	task.delay(REQUEST_TIMEOUT, function()
		self._requesting = false
	end)

	return true
end

-- Writes one employee onto a panel. The equipped slot's details and every worker card share the same fields.
function WorkerHutController:_drawEmployee(panel, uid: string, record, portraitCleaner)
	panel.EmployeeName.Text = record.Name
	panel.RoleName.Text = Employees.ROLE_NAMES[record.Role]
	panel.Icon.Image = Employees.ROLE_ICONS[record.Role]

	local stars = Rating.ToStars(record.Skill)
	Rating.DrawStars(panel.Stars, stars)
	panel.Rating.Text = Rating.FormatStars(stars)

	portraitCleaner:Clean()

	-- Baked a beat behind the record, so a missing one is normal and the folder's ChildAdded repaints it
	local portraits = PlayerGui:FindFirstChild(Employees.PORTRAIT_FOLDER)
	local portrait = portraits and portraits:FindFirstChild(uid)
	if portrait then
		portraitCleaner:Add(ViewportPortrait.Show(panel.ViewportFrame, portrait))
	end
end

-- Paints every slot as unlocked, next in line to buy, or locked behind the one before it.
function WorkerHutController:RefreshSlots()
	local unlocked = PlayerDataController:GetKey("HutSlotsUnlocked")
	local employees = PlayerDataController:GetKey("Employees")

	-- [slot] = uid, gathered in one pass rather than a scan per slot
	local equipped = {}
	for uid, record in employees do
		if record.Slot then
			equipped[record.Slot] = uid
		end
	end

	for slot, state in self._slots do
		local frame = state.Frame
		local isUnlocked = EmployeeHut.IsSlotUnlocked(slot, unlocked)
		local buyable = slot == unlocked + 1
		local uid = if isUnlocked then equipped[slot] else nil

		state.Uid = uid

		frame.Title.Visible = buyable
		frame.Price.Visible = buyable
		frame.Buy.Visible = buyable

		if state.BuyRobux then
			state.BuyRobux.Visible = buyable
		end
		frame.Select.Visible = isUnlocked and uid == nil
		frame.EquippedDetails.Visible = uid ~= nil

		-- Only a slot that can sit behind a locked one carries this: slot 2 is always unlocked or next in line
		local locked = frame:FindFirstChild("Locked")
		if locked then
			locked.Visible = not isUnlocked and not buyable
		end

		if uid then
			self:_drawEmployee(frame.EquippedDetails, uid, employees[uid], state.PortraitCleaner)
		else
			state.PortraitCleaner:Clean()
		end
	end
end

-- Builds one card per worker not in a slot, best first, each equipping into `slot`. Returns how many it built.
function WorkerHutController:_buildWorkerCards(slot: number): number
	self._workerCleaner:Clean()

	local built = 0

	for uid, record in PlayerDataController:GetKey("Employees") do
		if record.Slot then
			continue
		end

		built += 1

		local card = self._workerCleaner:Clone(self._workerTemplate)
		local holder = card.Holder

		-- Authored hidden, so it has to be switched on with the clone rather than left to show on its own
		card.Visible = true

		-- A grid sorts ascending, so the rating is negated to put the best worker first
		card.LayoutOrder = -math.round(record.Skill * LAYOUT_ORDER_SCALE)

		self:_drawEmployee(holder, uid, record, self._workerCleaner:Construct(Trove))

		-- A fresh card measures zero until it's laid out, so its first framing waits for a size
		self._workerCleaner:Connect(holder.ViewportFrame:GetPropertyChangedSignal("AbsoluteSize"), function()
			ViewportPortrait.Reframe(holder.ViewportFrame)
		end)

		-- The card's Holder springs under the press, not the template root around it
		self._workerCleaner:Add(UIController:BindButtonClick(holder.Button, function()
			if self:_request(self.EquipEmployeeEvent, uid, slot) then
				self:ShowSlots()
			end
		end, true, false, { ShowFrame = holder }).Disconnect)

		card.Parent = self._workerList
	end

	return built
end

-- Swaps the slots for the list of workers not in one, to pick who goes in `slot`. Stays on the slots with a word if there's nobody to pick.
function WorkerHutController:ShowWorkerList(slot: number)
	if self:_buildWorkerCards(slot) == 0 then
		NotificationController:NotifyNormal({
			Text = "No available Workers",
			Effect = "Error",
			Duration = 3,
			Sound = "Reject",
		})
		return
	end

	self._selectingSlot = slot
	self.UI.Holder.SlotContainer.Visible = false
	self.UI.Holder.WorkerContainer.Visible = true
end

-- Puts the slots back up in place of the worker list.
function WorkerHutController:ShowSlots()
	self._workerCleaner:Clean()
	self._selectingSlot = nil

	self.UI.Holder.WorkerContainer.Visible = false
	self.UI.Holder.SlotContainer.Visible = true

	self:RefreshSlots()
end

-- Repaints whichever view is up. Skipped while the panel is shut, since opening it repaints on the way in.
function WorkerHutController:Refresh()
	if not self.UI.Holder.Visible then
		return
	end

	-- The list is rebuilt in place, and emptied out from under them it falls back to the slots
	if self._selectingSlot then
		if self:_buildWorkerCards(self._selectingSlot) == 0 then
			self:ShowSlots()
		end

		return
	end

	self:RefreshSlots()
end

-- Opens the panel on its slots. Shuts it again on a repeat, since OpenFrame toggles.
function WorkerHutController:Open()
	if not self.UI then
		return
	end

	self:ShowSlots()
	UIController:OpenFrame(self.UI.Holder)
end

function WorkerHutController:OnInit()
	-- Timed out rather than waited on, since the loader runs every OnInit on one thread
	self.UI = PlayerGui:WaitForChild(EmployeeHut.SLOTS_UI_NAME, UI_TIMEOUT)

	if not self.UI then
		warn(`[WorkerHut] PlayerGui.{EmployeeHut.SLOTS_UI_NAME} is missing, so workers can't be equipped`)
	end
end

function WorkerHutController:OnStart()
	if not self.UI then
		return
	end

	local holder = self.UI.Holder
	holder.Visible = false

	self._workerList = holder.WorkerContainer.ScrollingFrame
	self._workerTemplate = self._workerList.WorkerTemplate
	self._workerTemplate.Parent = nil

	UIController:BindButtonClick(holder.Exit, function()
		UIController:CloseFrame(holder)
	end, true)

	-- Bound once here rather than per open: a hidden button can't be pressed, so the bindings stay live
	for slot, price in EmployeeHut.SLOT_PRICES do
		local frame = holder.SlotContainer[tostring(slot)]
		local details = frame.EquippedDetails

		-- Only a slot sold for Robux carries that button, and slot 1 never is: it comes with the repair
		local state = {
			Frame = frame,
			BuyRobux = if EmployeeHut.SLOT_PRODUCT_IDS[slot] then frame.BuyRobux else nil,
			PortraitCleaner = Trove.new(),
			Uid = nil,
		}
		self._slots[slot] = state

		-- A price never moves, so it's written once rather than repainted
		frame.Price.Text = `${GuiUtil.ConvertNumberWithCommas(price)}`

		-- Left pressable when they can't afford it, so the server is the one that says why
		UIController:BindButtonClick(frame.Buy, function()
			self:_request(self.PurchaseHutSlotEvent, slot)
		end, true)

		if state.BuyRobux then
			local stringId = EmployeeHut.GetSlotProductStringId(slot)

			UIController:BindButtonClick(state.BuyRobux, function()
				ShopController:PromptProductPurchaseFromId(stringId)
			end, true)

			-- The first read of a price yields, so it's fetched off this thread with "-" holding its place
			state.BuyRobux.Title.Text = `{GuiUtil.ROBUX_ICON}-`
			task.spawn(function()
				state.BuyRobux.Title.Text = `{GuiUtil.ROBUX_ICON}{ShopController:GetPrice(stringId)}`
			end)
		end

		-- Select is an invisible button laid over the slot, so the slot itself springs under the press
		UIController:BindButtonClick(frame.Select, function()
			self:ShowWorkerList(slot)
		end, true, false, { ShowFrame = frame })

		UIController:BindButtonClick(details.Unequip, function()
			if state.Uid then
				self:_request(self.UnequipEmployeeEvent, state.Uid)
			end
		end, true)

		-- A viewport measures zero until it's been laid out once, so the first framing waits for a size
		details.ViewportFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			ViewportPortrait.Reframe(details.ViewportFrame)
		end)
	end

	-- Spawned, since ListenForChange awaits the data replica
	task.spawn(function()
		PlayerDataController:ListenForChange("Employees", function(_, _, changedPath)
			-- A working employee writes what it's carrying every few seconds, and none of that is drawn here
			if changedPath[3] and changedPath[3] ~= "Slot" then
				return
			end

			self._requesting = false
			self:Refresh()
		end)

		PlayerDataController:ListenForChange("HutSlotsUnlocked", function()
			self._requesting = false
			self:Refresh()
		end)
	end)

	-- Made by the server on the first portrait it bakes, so it can land after this runs
	local function watchPortraits(folder: Instance)
		folder.ChildAdded:Connect(function()
			self:Refresh()
		end)

		self:Refresh()
	end

	local portraits = PlayerGui:FindFirstChild(Employees.PORTRAIT_FOLDER)
	if portraits then
		watchPortraits(portraits)
	else
		local connection
		connection = PlayerGui.ChildAdded:Connect(function(child)
			if child.Name == Employees.PORTRAIT_FOLDER then
				connection:Disconnect()
				watchPortraits(child)
			end
		end)
	end
end

return WorkerHutController
