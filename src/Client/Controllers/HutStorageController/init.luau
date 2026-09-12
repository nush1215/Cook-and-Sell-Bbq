-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local Structures = require(Shared.Config.Structures)
local EmployeeHut = require(Shared.Config.EmployeeHut)
local Sticks = require(Shared.Config.Sticks)
local Ingredients = require(Shared.Config.Ingredients)

-- Modules
local HutStorage = require(script.HutStorage)

-- Controllers
local WorkerHutController = require(script.Parent.WorkerHutController)
local FreeWorkersController = require(script.Parent.FreeWorkersController)
local UIController = require(script.Parent.UIController)
local PlayerDataController = require(script.Parent.PlayerDataController)

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- The child a hut needs to host a prompt. Waited on, since a placed hut replicates mid-session
local CHILD_TIMEOUT = 10

-- The loader runs every OnInit on one thread, so this waits with a timeout rather than hanging the boot
local UI_TIMEOUT = 10

-- How long a withdraw stays locked after it's asked for, in case the server turns it down and no data change lands
local REQUEST_TIMEOUT = 3

-- One HutStorage per placed hut, found off the Huts tag since a repaired hut is built rather than authored. A base can carry several, and each fills its own store -- the prompt sends its uid so the server knows which.

--
local HutStorageController = {
	StoreItemEvent = Network.Event("StoreHutItem"),
	WithdrawItemEvent = Network.Event("WithdrawHutItem"),

	_huts = {}, -- [model: Model] = HutStorage
	_viewingUid = nil, -- the hut whose store the panel is showing
	_withdrawing = false, -- the client half of the debounce; the server holds the authoritative one
	_rowCleaner = Trove.new(), -- the panel's rows, rebuilt on every draw
	_cleaner = Trove.new(),
}

-- Builds a HutStorage for a placed hut, unless one already tracks it.
function HutStorageController:_addHut(model: Model)
	if self._huts[model] then
		return
	end

	-- Belt-and-braces under streaming, but a hut tracked without one can never host its prompt
	if not model:WaitForChild(Structures.HITBOX_NAME, CHILD_TIMEOUT) then
		warn(`[HutStorage] {model.Name} has no {Structures.HITBOX_NAME}, it won't offer storage`)
		return
	end

	-- Waiting above yields, so the hut can have been taken away in the meantime
	if not model.Parent or self._huts[model] then
		return
	end

	-- Read after the wait, not before: the category is shared, and a hut that arrived a frame ahead of its
	-- attributes would be skipped for good rather than merely late. A second Huts entry gets no prompt
	if model:GetAttribute(Structures.TYPE_ATTRIBUTE) ~= EmployeeHut.STRUCTURE_ID then
		return
	end

	local hut = HutStorage.new(model)
	self._huts[model] = hut
	self._cleaner:Add(hut)
end

-- Drops the HutStorage for a hut that's been taken away.
function HutStorageController:_removeHut(model: Model)
	local hut = self._huts[model]
	if not hut then
		return
	end

	self._cleaner:Remove(hut)
	self._huts[model] = nil
end

-- Asks the server to put what they're holding into this hut, the whole stack if `storeAll`. It decides what, and whether they may.
function HutStorageController:RequestStore(uid: string, storeAll: boolean?)
	self.StoreItemEvent:FireServer(uid, storeAll == true)
end

-- Opens the storage panel on one hut's stock. Shuts it again on a repeat, since OpenFrame toggles.
function HutStorageController:RequestOpenStorage(uid: string)
	if not self.UI then
		return
	end

	self._viewingUid = uid
	self:_buildStorageRows()

	UIController:OpenFrame(self.UI.Holder)
end

-- Asks the server to hand one of a stored item back to the inventory. Freed by the store changing, or by the timeout if the server refuses.
function HutStorageController:RequestWithdrawStoredItem(kind: string, id: string)
	if self._withdrawing then
		return
	end

	self._withdrawing = true
	self.WithdrawItemEvent:FireServer(self._viewingUid, kind, id)

	task.delay(REQUEST_TIMEOUT, function()
		self._withdrawing = false
	end)
end

-- Lists the viewed hut's stock, one row per item: sticks first, then ingredients, each group priciest first.
function HutStorageController:_buildStorageRows()
	self._rowCleaner:Clean()

	-- Missing for a hut nothing has gone into yet, or one that's been picked up and handed its store back
	local store = PlayerDataController:GetKey("HutStorage")[self._viewingUid]
	if not store then
		return
	end

	local entries = {}

	-- A count sits at 0 once an employee takes the last, and an id can outlive its config entry
	for stickId, amount in store.Sticks do
		local stick = Sticks.GetStickFromId(stickId)
		if amount > 0 and stick then
			table.insert(entries, {
				Kind = "Sticks",
				Id = stickId,
				Price = stick.Price,
				Name = `{stick.Name} Stick`,
				Icon = stick.Icon,
				TextColor = stick.TextColor,
				StrokeColor = stick.StrokeColor,
				Amount = amount,
			})
		end
	end

	for ingredientId, amount in store.Ingredients do
		local ingredient = Ingredients.GetIngredientFromId(ingredientId)
		if amount > 0 and ingredient then
			table.insert(entries, {
				Kind = "Ingredients",
				Id = ingredientId,
				Price = ingredient.Price,
				Name = ingredient.Name,
				Icon = ingredient.Icon,
				TextColor = ingredient.Color,
				Amount = amount,
			})
		end
	end

	-- Name last, so two items at the same price don't swap places between draws
	table.sort(entries, function(a, b)
		if a.Kind ~= b.Kind then
			return a.Kind == "Sticks"
		end

		if a.Price ~= b.Price then
			return a.Price > b.Price
		end

		return a.Name < b.Name
	end)

	for order, entry in entries do
		local row = self._rowCleaner:Clone(self._rowTemplate)
		local holder = row.Holder

		-- Switched on with the clone, in case the template is authored hidden
		row.Visible = true
		row.LayoutOrder = order

		holder.Icon.Image = entry.Icon
		holder.ItemName.Text = entry.Name
		holder.ItemName.TextColor3 = entry.TextColor
		holder.Amount.Text = `x{entry.Amount}`

		-- Only sticks carry a stroke colour; an ingredient keeps the template's
		local stroke = entry.StrokeColor and holder.ItemName:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			stroke.Color = entry.StrokeColor
		end

		self._rowCleaner:Add(UIController:BindButtonClick(holder, function()
			self:RequestWithdrawStoredItem(entry.Kind, entry.Id)
		end, true, false, { ShowFrame = holder }).Disconnect)

		row.Parent = self._rowList
	end
end

-- Opens the Worker Hut panel, where the hut's slots are bought and its workers equipped. The first open goes to the three free Workers instead, and the hut's own panel follows once one has been taken.
function HutStorageController:RequestOpenWorkerHut()
	if FreeWorkersController:ShouldOffer() then
		FreeWorkersController:Open()
		return
	end

	WorkerHutController:Open()
end

-- Re-checks every hut's prompt. Cheap, and what it offers depends on what the player is holding.
function HutStorageController:_refreshPrompts()
	for _, hut in self._huts do
		hut:RefreshPrompt()
	end
end

-- Watches the local character's tools, so the "Store {Item}" verb tracks what they equip.
function HutStorageController:_watchCharacter(character: Model)
	self._characterCleaner:Clean()

	self._characterCleaner:Connect(character.ChildAdded, function(child)
		if child:IsA("Tool") then
			self:_refreshPrompts()
		end
	end)
	self._characterCleaner:Connect(character.ChildRemoved, function(child)
		if child:IsA("Tool") then
			self:_refreshPrompts()
		end
	end)

	self:_refreshPrompts()
end

function HutStorageController:OnInit()
	-- Timed out rather than waited on, since the loader runs every OnInit on one thread
	self.UI = PlayerGui:WaitForChild(EmployeeHut.STORAGE_UI_NAME, UI_TIMEOUT)

	if not self.UI then
		warn(`[HutStorage] PlayerGui.{EmployeeHut.STORAGE_UI_NAME} is missing, so hut storage can't be viewed`)
	end
end

function HutStorageController:OnStart()
	self._characterCleaner = self._cleaner:Construct(Trove)

	if self.UI then
		local holder = self.UI.Holder
		holder.Visible = false

		self._rowList = holder.WorkerContainer.ScrollingFrame
		self._rowTemplate = self._rowList.Template
		self._rowTemplate.Parent = nil

		UIController:BindButtonClick(holder.Exit, function()
			UIController:CloseFrame(holder)
		end, true)
	end

	-- A hut placed on any base wires itself up here, before this client started or while it runs
	self._cleaner:Connect(CollectionService:GetInstanceAddedSignal(EmployeeHut.CATEGORY), function(model)
		self:_addHut(model)
	end)

	self._cleaner:Connect(CollectionService:GetInstanceRemovedSignal(EmployeeHut.CATEGORY), function(model)
		self:_removeHut(model)
	end)

	-- _addHut waits on the hut's Hitbox, so keep the sweep off the main thread
	for _, model in CollectionService:GetTagged(EmployeeHut.CATEGORY) do
		task.spawn(function()
			self:_addHut(model)
		end)
	end

	-- Equipping or dropping an ingredient changes whether a hut should be offering to take it
	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end

	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_watchCharacter(character)
	end)

	-- Spawned, since ListenForChange awaits the replica. Storing one leaves the rest of the stack equipped, so only the count says when Store all should go
	task.spawn(function()
		PlayerDataController:ListenForChange("Ingredients", function()
			self:_refreshPrompts()
		end)

		PlayerDataController:ListenForChange("Sticks", function()
			self:_refreshPrompts()
		end)

		-- The change a withdraw waits on has landed. Redrawn only while it's up, so an employee taking stock shows live
		PlayerDataController:ListenForChange("HutStorage", function()
			self._withdrawing = false

			if self.UI and self.UI.Holder.Visible then
				self:_buildStorageRows()
			end
		end)
	end)
end

return HutStorageController
