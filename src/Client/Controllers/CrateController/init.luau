-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Assets
local UI = ReplicatedStorage.Assets.UI

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local StickIngredients = require(Shared.StickIngredients)
local CratesConfig = require(Shared.Config.Crates)
local Ingredients = require(Shared.Config.Ingredients)
local Sticks = require(Shared.Config.Sticks)

-- Controllers
local EffectController = require(script.Parent.EffectController)
local SoundController = require(script.Parent.SoundController)
local UIController
local NotificationController

-- Modules
local Crate = require(script.Crate)
local EquippedItem = require(script.Parent.Parent.Modules.EquippedItem)

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

--
local CRATE_TAG = "Crate"
local CRATE_TOOL_TAG = "CrateTool"

-- Draws every crate anyone opens off the payout stamped on its model, so an open is watched by everyone; only the owner's client claims. The reveal uses no springs, since spr keeps stepping destroyed instances.

--
local CrateController = {
	OpenCratesEvent = Network.Event("OpenCrates"), -- client -> server (crateId, count)
	ClaimCrateEvent = Network.Event("ClaimCrate"), -- client -> server (uniqueId)

	UI = nil, -- the open panel, or nil until one is authored in the place (see OpenPanel)

	_crates = {}, -- [model] = { Crate, DestroyingConnection }
	_openCooldownUntil = 0,

	_cleaner = Trove.new(),
	_characterCleaner = nil,
}

-- Arcs a crate from its owner's hands onto its slot, as a hand-rolled bezier since the crate is anchored.
function CrateController:_throwToSlot(model: Model, startPosition: Vector3, slotPivot: CFrame)
	local targetPosition = slotPivot.Position
	local rotation = slotPivot.Rotation

	local distance = (targetPosition - startPosition).Magnitude
	local controlPosition = (startPosition + targetPosition) * 0.5
		+ Vector3.new(0, math.max(distance * 0.5, CratesConfig.THROW_ARC_HEIGHT), 0)

	SoundController:PlaySound("CrateFly", model.PrimaryPart, {
		PlaybackSpeed = Random.new():NextNumber(0.98, 1.1),
	})

	local startTime = os.clock()
	while true do
		if not model:IsDescendantOf(workspace) then
			return
		end

		local alpha = math.clamp((os.clock() - startTime) / CratesConfig.THROW_DURATION, 0, 1)
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local inverse = 1 - eased

		local position = startPosition * (inverse * inverse)
			+ controlPosition * (2 * inverse * eased)
			+ targetPosition * (eased * eased)

		model:PivotTo(CFrame.new(position) * rotation)

		-- No sound of its own -- CrateDrop belongs to the slam, and firing it here would spend the impact twice
		if alpha >= 1 then
			EffectController:RunEffect("CrateLand", model)
			return
		end

		RunService.RenderStepped:Wait()
	end
end

-- Throws a fresh crate from its owner's hands to its slot and opens it. Every client runs this for every crate.
function CrateController:_playOpenSequence(crate, model: Model)
	local slotPivot = model:GetPivot()
	local openIndex = model:GetAttribute("OpenIndex") or 1

	local ownerPlayer = Players:GetPlayerByUserId(model:GetAttribute("Owner"))
	local character = ownerPlayer and ownerPlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")

	-- No owner to throw from just means the crate opens where it landed
	if rootPart then
		local startPosition = rootPart.Position + Vector3.new(0, CratesConfig.THROW_START_HEIGHT, 0)
		model:PivotTo(CFrame.new(startPosition) * slotPivot.Rotation)

		-- Held back so a batch leaves one after another rather than all on the same frame
		task.wait((openIndex - 1) * CratesConfig.THROW_STAGGER)

		if not model:IsDescendantOf(workspace) then
			return
		end

		-- Spawned invisible so it can't flash on its slot; now it's in their hands, it's safe to show
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Transparency = descendant:GetAttribute("RevealTransparency") or 0
			end
		end

		self:_throwToSlot(model, startPosition, slotPivot)
	end

	if not model:IsDescendantOf(workspace) then
		return
	end

	-- Seated exactly before the twitch pins itself to wherever the crate is
	model:PivotTo(slotPivot)
	task.wait(CratesConfig.SETTLE_DURATION)

	if not model:IsDescendantOf(workspace) then
		return
	end

	crate:Open()
end

-- Draws a crate's payout: rewards rise into a centred row, hover, then fly into the owner one by one.
function CrateController:RevealContents(model: Model, originCFrame: CFrame)
	local rewards = HttpService:JSONDecode(model:GetAttribute("Rewards"))
	if #rewards == 0 then
		return
	end

	local uniqueId = model:GetAttribute("UniqueId")
	local owner = model:GetAttribute("Owner")

	-- No owner means they fly to whoever is watching, and nobody claims -- the server hands them over itself
	local targetPlayer = (owner and Players:GetPlayerByUserId(owner)) or LocalPlayer

	local cleaner = Trove.new()
	local items = {}

	for index, reward in rewards do
		local isIngredient = reward.Type == "Ingredient"
		local entry = if isIngredient
			then Ingredients.GetIngredientFromId(reward.Id)
			else Sticks.GetStickFromId(reward.Id)

		local rewardModel = entry.Model:Clone()
		cleaner:Add(rewardModel)

		-- One size for everything, so a grape and a gold stick read as equals. Measured before the scale, seated after
		local displayScale = rewardModel:GetScale()
			* (CratesConfig.REWARD_DISPLAY_SIZE / StickIngredients.GetMaxExtent(rewardModel))
		rewardModel:ScaleTo(displayScale)

		-- Seated on the bounding-box centre -- a stick's pivot is on its grip, which would hang it off the row
		local seatOffset = StickIngredients.GetPivotToCenter(rewardModel):Inverse()

		-- The same billboard a rolling stand uses. Built at full display scale, so it seats off the final size
		local info = UI.IngredientInfo:Clone()
		local billboard = info.UI

		billboard.IngredientName.Text = if isIngredient then entry.Name else `{entry.Name} Stick`

		-- Name only: the odds line would mean the stand's chance, not the crate's, and a reward isn't for sale
		billboard.Rarity.Visible = false
		billboard.Price.Visible = false

		info.CFrame = CFrame.new(0, rewardModel:GetExtentsSize().Y / 2, 0)
		info.Parent = rewardModel

		for _, descendant in rewardModel:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
			end
		end

		-- Centred on the crate, so each extra reward shifts the whole row. The slot already faces the player
		local offsetX = (index - (#rewards + 1) / 2) * CratesConfig.REWARD_HOVER_SPACING
		local startCFrame = originCFrame * CFrame.new(0, CratesConfig.REWARD_START_LIFT, 0)

		items[index] = {
			Model = rewardModel,
			DisplayScale = displayScale,
			SeatOffset = seatOffset,
			StartCFrame = startCFrame,
			RestCFrame = originCFrame * CFrame.new(offsetX, CratesConfig.REWARD_HOVER_HEIGHT, 0),
			CollectFrom = nil,
			Done = false,
		}

		rewardModel:ScaleTo(displayScale * CratesConfig.REWARD_START_SCALE)
		rewardModel:PivotTo(startCFrame * seatOffset)
		rewardModel.Parent = workspace

		-- Trails the reward appearing, so the burst reads as coming off it rather than being it
		task.delay(CratesConfig.SHOW_LOOT_DELAY, function()
			if rewardModel:IsDescendantOf(workspace) then
				EffectController:RunEffect("CrateShowLoot", rewardModel)
			end
		end)
	end

	-- Once as the row leaves the flash -- the arrival is the beat worth marking, not the settling
	SoundController:PlaySound("CrateReveal", originCFrame, {
		PlaybackSpeed = Random.new():NextNumber(0.99, 1.01),
	}, true)

	local riseEnd = CratesConfig.REWARD_RISE_DURATION
	local hoverEnd = riseEnd + CratesConfig.REWARD_HOVER_DURATION
	local startTime = os.clock()
	local pending = #items

	cleaner:Add(RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startTime
		local character = targetPlayer.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")

		-- One spin for the whole row from the moment they leave, so the rise hands over to the hover with no jump
		local spin = CFrame.Angles(0, elapsed * CratesConfig.REWARD_SPIN_SPEED, 0)

		-- Faded in across the rise, or each reward climbs toward an already-displaced target and reads as a wobble
		local bobRamp = math.min(elapsed / riseEnd, 1)

		for index, item in items do
			if item.Done then
				continue
			end

			-- Phase-offset per reward so the row undulates rather than pulsing as one block
			local bob = math.sin(elapsed * CratesConfig.REWARD_BOB_SPEED + index)
				* CratesConfig.REWARD_BOB_AMPLITUDE
				* bobRamp

			local hoverPose = item.RestCFrame * CFrame.new(0, bob, 0) * spin

			if elapsed < riseEnd then
				-- Quad/Out is what a thrown thing follows; Back/Out would overshoot and read as a jolt
				local eased = TweenService:GetValue(elapsed / riseEnd, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				local scale = CratesConfig.REWARD_START_SCALE + (1 - CratesConfig.REWARD_START_SCALE) * eased

				item.Model:ScaleTo(item.DisplayScale * scale)
				item.Model:PivotTo(item.StartCFrame:Lerp(hoverPose, eased) * item.SeatOffset)
				continue
			end

			local collectStart = hoverEnd + (index - 1) * CratesConfig.REWARD_COLLECT_STAGGER
			if elapsed < collectStart then
				item.Model:PivotTo(hoverPose * item.SeatOffset)
				continue
			end

			-- Nobody to fly into, so drop it -- the server hands the rewards over if this client never claims
			if not rootPart then
				item.Done = true
				item.Model:Destroy()
				pending -= 1
				continue
			end

			-- Pinned on the first collect frame so the arc starts where the reward was, bob and all
			if not item.CollectFrom then
				item.CollectFrom = hoverPose.Position

				-- Left where it set off, since the model is destroyed on arrival and would cut a 3D sound short
				SoundController:PlaySound("CrateFly", item.CollectFrom, {
					PlaybackSpeed = Random.new():NextNumber(1, 1.12),
				}, true)
			end

			local alpha = math.clamp((elapsed - collectStart) / CratesConfig.REWARD_COLLECT_DURATION, 0, 1)
			local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local inverse = 1 - eased

			-- Recomputed every frame so the arc tracks the player if they walk off mid-collect
			local targetPosition = rootPart.Position
			local distance = (targetPosition - item.CollectFrom).Magnitude
			local controlPosition = (item.CollectFrom + targetPosition) * 0.5
				+ Vector3.new(0, math.max(distance * 0.25, CratesConfig.REWARD_COLLECT_ARC_HEIGHT), 0)

			local position = item.CollectFrom * (inverse * inverse)
				+ controlPosition * (2 * inverse * eased)
				+ targetPosition * (eased * eased)

			item.Model:ScaleTo(item.DisplayScale * math.max(inverse, 0.35))
			item.Model:PivotTo(CFrame.new(position) * spin * item.SeatOffset)

			if alpha >= 1 then
				item.Done = true
				item.Model:Destroy()
				pending -= 1
			end
		end

		if pending > 0 then
			return
		end

		-- Destroys this connection along with everything else the reveal owns
		cleaner:Destroy()

		if owner == LocalPlayer.UserId then
			self.ClaimCrateEvent:FireServer(uniqueId)
		end
	end))
end

-- Picks up a crate that's just replicated in and starts whatever it was spawned to do.
function CrateController:_initCrate(model: Model)
	if self._crates[model] then
		return
	end

	local crate = Crate.new(model)

	self._crates[model] = {
		Crate = crate,
		DestroyingConnection = model.Destroying:Connect(function()
			self:_cleanupCrate(model)
		end),
	}

	-- Somebody just opened this one, so it throws itself out of their hands and opens where it lands
	if model:GetAttribute("Owner") then
		task.spawn(function()
			self:_playOpenSequence(crate, model)
		end)
		return
	end

	-- The bob pins to wherever the crate is, so the crash owner starts it on landing. Keyed on PlayCrash, so a rejoin still bobs
	local playingCrash = model:GetAttribute("PlayCrash")
		and model:GetAttribute("CrashOwner") == LocalPlayer.UserId

	if model:GetAttribute("AutoIdle") and not playingCrash then
		crate:SetState("Idle")
	end
end

-- Starts the resting bob on an already-tracked crate, for the meteor crash once it has settled.
function CrateController:IdleCrate(model: Model)
	local entry = self._crates[model]
	if entry then
		entry.Crate:SetState("Idle")
	end
end

-- Plays the open on an already-tracked crate, for the tutorial crate the whole base watches.
function CrateController:OpenCrate(model: Model)
	local entry = self._crates[model]
	if entry then
		entry.Crate:Open()
	end
end

function CrateController:_cleanupCrate(model: Model)
	local entry = self._crates[model]
	if not entry then
		return
	end

	self._crates[model] = nil
	entry.DestroyingConnection:Disconnect()
	entry.Crate:Destroy()
end

-- Opens the how-many panel, or opens a single crate if the place has never authored one.
function CrateController:OpenPanel()
	local tool = EquippedItem.GetCrate()
	if not tool then
		return
	end

	local crate = CratesConfig.GetCrateFromId(tool:GetAttribute("CrateId"))
	if not crate then
		return
	end

	if not self.UI then
		self:RequestOpen(1)
		return
	end

	local holder = self.UI.Holder
	holder.Title.RichText = true
	holder.Title.Text = `Open {GuiUtil.Colorize(crate.Name, crate.Color)}`
	holder.Buttons.OpenAll.Amount.Text = `x{tool:GetAttribute("Count") or 1}`

	UIController:OpenFrame(holder)
end

-- Asks the server to open some of the crates the local player is holding.
function CrateController:RequestOpen(desired: number)
	local tool = EquippedItem.GetCrate()
	if not tool then
		return
	end

	local count = tool:GetAttribute("Count") or 0
	local toOpen = math.min(desired, count, CratesConfig.MAX_OPEN_AT_ONCE)
	if toOpen <= 0 then
		return
	end

	-- Client-side only, so the buttons can't be mashed; the server's cooldown is the authoritative one
	if os.clock() < self._openCooldownUntil then
		NotificationController:NotifyNormal({
			Text = "You're opening crates too fast!",
			Duration = 3,
			Sound = "Reject",
			Effect = "Error",
		})
		return
	end

	if toOpen < math.min(desired, count) then
		NotificationController:NotifyNormal({
			Text = `You can only open {CratesConfig.MAX_OPEN_AT_ONCE} crates at a time`,
			Duration = 3,
		})
	end

	self._openCooldownUntil = os.clock() + CratesConfig.GetOpenCooldown(toOpen)
	self.OpenCratesEvent:FireServer(tool:GetAttribute("CrateId"), toOpen)

	if self.UI then
		UIController:CloseFrame(self.UI.Holder)
	end
end

-- Watches for the local player equipping a crate, which parents the tool into the character.
function CrateController:_watchCharacter(character: Model)
	self._characterCleaner:Clean()

	-- Apart from the character's cleaner, so putting the crate away doesn't tear down the equip watch
	local toolCleaner = self._characterCleaner:Extend()

	local function bind(child: Instance)
		if not (child:IsA("Tool") and child:HasTag(CRATE_TOOL_TAG)) then
			return
		end

		toolCleaner:Connect(child.Activated, function()
			self:OpenPanel()
		end)
	end

	local function unbind(child: Instance)
		if not (child:IsA("Tool") and child:HasTag(CRATE_TOOL_TAG)) then
			return
		end

		toolCleaner:Clean()

		-- Only the crate's own panel, so putting one away can't pull an unrelated frame shut
		if self.UI and self.UI.Holder.Visible then
			UIController:CloseFrame(self.UI.Holder)
		end
	end

	self._characterCleaner:Connect(character.ChildAdded, bind)
	self._characterCleaner:Connect(character.ChildRemoved, unbind)

	-- They may already have it out, on a re-bind or a controller reload
	for _, child in character:GetChildren() do
		bind(child)
	end
end

function CrateController:OnInit()
	UIController = require(script.Parent.UIController)
	NotificationController = require(script.Parent.NotificationController)

	-- FindFirstChild, since the loader runs every OnInit on one thread and yielding would hang the boot
	self.UI = PlayerGui:FindFirstChild("CrateUI")
	self._characterCleaner = self._cleaner:Extend()
end

function CrateController:OnStart()
	if self.UI then
		local holder = self.UI.Holder
		holder.Visible = false

		UIController:BindButtonClick(holder.Exit, function()
			UIController:CloseFrame(holder)
		end, true)

		UIController:BindButtonClick(holder.Buttons.Open1, function()
			self:RequestOpen(1)
		end, true)

		-- Asks for everything rather than the cap, so an over-cap stack is told it only opened part of itself
		UIController:BindButtonClick(holder.Buttons.OpenAll, function()
			self:RequestOpen(math.huge)
		end, true)
	end

	for _, model in CollectionService:GetTagged(CRATE_TAG) do
		self:_initCrate(model)
	end

	CollectionService:GetInstanceAddedSignal(CRATE_TAG):Connect(function(model)
		self:_initCrate(model)
	end)

	CollectionService:GetInstanceRemovedSignal(CRATE_TAG):Connect(function(model)
		self:_cleanupCrate(model)
	end)

	if LocalPlayer.Character then
		self:_watchCharacter(LocalPlayer.Character)
	end

	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_watchCharacter(character)
	end)
end

return CrateController
