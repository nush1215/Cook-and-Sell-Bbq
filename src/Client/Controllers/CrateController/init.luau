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

--[[
    Draws every crate anyone opens, and drives the local player's own.

    Opening is a server call that spawns one model per crate in a ring around the player, each with
    its payout already rolled and stamped onto it as an attribute. Every client then animates every
    one of those models off those attributes -- the throw out of the owner's hands, the twitch, the
    pop and the row of rewards that comes out of it are all local, so an open is something the people
    around you watch rather than something only you see. Only the owner's client fires the claim at
    the end, and the server checks that it is the owner before it grants.

    A crate carrying an Owner is one somebody just opened, so it throws itself and opens on arrival.
    One carrying AutoIdle instead sits and hops where it was spawned until something opens it --
    nothing spawns those yet; that's the post-tutorial playtime crate.

    The reveal deliberately uses no springs. The rewards are short-lived clones and spr keeps
    stepping springs on destroyed instances, so all four are driven through their rise, hover and
    collect by one render loop that ends when the last of them lands.
]]

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

-- Arcs a crate out of its owner's hands and onto its slot on the ground. A hand-rolled quadratic
-- bezier rather than physics, since the crate is anchored and everything else about it moves by
-- pivoting too.
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

		-- Dust and a flash, no sound of its own -- CrateDrop belongs to the slam at the end of the
		-- rattle, and firing it here too would spend the impact twice in one open
		if alpha >= 1 then
			EffectController:RunEffect("CrateLand", model)
			return
		end

		RunService.RenderStepped:Wait()
	end
end

-- Takes a freshly spawned crate from its owner's hands out to its slot and opens it there. Every
-- client runs this for every crate, so the throw comes from the right player's hands whoever is
-- watching.
function CrateController:_playOpenSequence(crate, model: Model)
	local slotPivot = model:GetPivot()
	local openIndex = model:GetAttribute("OpenIndex") or 1

	local ownerPlayer = Players:GetPlayerByUserId(model:GetAttribute("Owner"))
	local character = ownerPlayer and ownerPlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")

	-- No owner to throw from (they left, or their character hasn't loaded on this client) just means
	-- the crate opens where it landed rather than nothing happening at all.
	if rootPart then
		local startPosition = rootPart.Position + Vector3.new(0, CratesConfig.THROW_START_HEIGHT, 0)
		model:PivotTo(CFrame.new(startPosition) * slotPivot.Rotation)

		-- Held back so a batch leaves one after another rather than all on the same frame
		task.wait((openIndex - 1) * CratesConfig.THROW_STAGGER)

		if not model:IsDescendantOf(workspace) then
			return
		end

		-- The server spawns an owner's crate invisible so it can't flash on its slot before the throw.
		-- Now that it's in their hands, it's safe to show.
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

-- Draws what a crate paid out: every reward rises out of the pop at once into a row centred on where
-- the crate stood, hovers there, then flies into the owner one after another. Called by the crate
-- class on the frame it pops, and `originCFrame` is the crate's own slot rather than the pose it
-- happened to be mid-jolt at.
function CrateController:RevealContents(model: Model, originCFrame: CFrame)
	local rewards = HttpService:JSONDecode(model:GetAttribute("Rewards"))
	if #rewards == 0 then
		return
	end

	local uniqueId = model:GetAttribute("UniqueId")
	local owner = model:GetAttribute("Owner")

	-- A crate nobody opened has no owner to fly its rewards into, so they go to whoever is watching --
	-- and nobody claims it, which leaves the server to hand the rewards over itself
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

		-- Every reward is drawn at one size whatever it actually is, so a grape and a gold stick read
		-- as equals in the row. Measured before the scale, seated after it, since the offset from a
		-- model's authored pivot to its centre scales along with the model.
		local displayScale = rewardModel:GetScale()
			* (CratesConfig.REWARD_DISPLAY_SIZE / StickIngredients.GetMaxExtent(rewardModel))
		rewardModel:ScaleTo(displayScale)

		-- Rewards are seated on their bounding-box centre, not their authored pivot -- a stick's is on
		-- its grip, so pivoting it onto a slot would hang it off the end of the row.
		local seatOffset = StickIngredients.GetPivotToCenter(rewardModel):Inverse()

		-- The same billboard a rolling stand puts over what it landed on, so a reward out of a crate is
		-- labelled the way the player already reads one. Built here, while the model is still at full
		-- display scale, so it's seated off the size it ends up at rather than the 0.2x it launches from.
		local info = UI.IngredientInfo:Clone()
		local billboard = info.UI

		billboard.IngredientName.Text = if isIngredient then entry.Name else `{entry.Name} Stick`

		-- The name and nothing else. The odds line means the ingredient's own roll chance off a stand,
		-- and what got this here was the crate's slot chance -- a different number, so printing one and
		-- meaning the other is exactly what Config.Rarity exists to stop. The price is off because a
		-- reward isn't for sale: quoting what it would have cost only reads as what it's worth.
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

		-- The row is centred on the crate: one reward sits dead centre, and each extra one shifts the
		-- whole row so it stays that way. The crate's slot already faces the player, so this spreads
		-- left to right across their view.
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

		-- Trails the reward appearing rather than firing with it, so the burst reads as coming off the
		-- thing rather than being the thing
		task.delay(CratesConfig.SHOW_LOOT_DELAY, function()
			if rewardModel:IsDescendantOf(workspace) then
				EffectController:RunEffect("CrateShowLoot", rewardModel)
			end
		end)
	end

	-- Once, as the row comes out of the flash -- not when it settles. The rewards arriving is the beat
	-- worth marking; them coming to rest is just the end of it.
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

		-- One spin shared by the whole row, running from the moment they leave the crate, so there's no
		-- jump where the rise hands over to the hover
		local spin = CFrame.Angles(0, elapsed * CratesConfig.REWARD_SPIN_SPEED, 0)

		-- The bob is faded in across the rise rather than running from the first frame. At full strength
		-- from the start, every reward is climbing toward a target that's already displaced and moving --
		-- and since each one's phase is offset, they're displaced by different amounts. That's what made
		-- the climb read as a wobble instead of a float. By the time it's at full strength the rewards
		-- are already at rest, so nothing jumps at the handover.
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
				-- Quad/Out is the curve something thrown upward actually follows -- quick off the mark,
				-- decelerating the whole way into the row. Deliberately not Back/Out, which overshoots the
				-- target and snaps back: on a reward this size that reads as a jolt rather than a float.
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

			-- Nobody left to fly into: drop the reward rather than leaving it hanging. The server hands
			-- the rewards over on its own if this client never gets to claim.
			if not rootPart then
				item.Done = true
				item.Model:Destroy()
				pending -= 1
				continue
			end

			-- Pinned on the first collect frame so the arc starts where the reward actually was, bob and
			-- all, rather than at its rest pose
			if not item.CollectFrom then
				item.CollectFrom = hoverPose.Position

				-- Left where the reward set off from rather than riding it in: the model is destroyed the
				-- moment it reaches the player, which would cut a 3D sound parented to it short
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

	-- A crate that waits where it was put instead of being thrown. The bob pins itself to wherever the
	-- crate is, so it must not start on the one client that's about to yank this into the sky for the
	-- crash -- that client starts it once the crate lands. Keyed on PlayCrash rather than on being the
	-- crash owner, so a crate restored on a rejoin still bobs for the player it belongs to.
	local playingCrash = model:GetAttribute("PlayCrash")
		and model:GetAttribute("CrashOwner") == LocalPlayer.UserId

	if model:GetAttribute("AutoIdle") and not playingCrash then
		crate:SetState("Idle")
	end
end

-- Starts the resting bob on a crate that's already been picked up by the tag sweep. Used by the
-- meteor crash, so the bob only begins once the crate has settled at its landing spot.
function CrateController:IdleCrate(model: Model)
	local entry = self._crates[model]
	if entry then
		entry.Crate:SetState("Idle")
	end
end

-- Plays the open on a crate that's already been picked up by the tag sweep. Used by the tutorial
-- crate, whose open is broadcast to every client so the whole base sees it rather than just its
-- owner -- the reveal reads Owner off the model to decide who claims and who it flies to.
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

-- Opens the panel that asks how many to open. Until one is authored in the place there's nothing to
-- choose between, so activating the tool just opens a single crate.
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

-- Watches for the local player pulling a crate out, since a crate is used by clicking it rather than
-- by walking up to something with it. Equipping parents the tool into the character, so that's the
-- one signal both halves come off.
function CrateController:_watchCharacter(character: Model)
	self._characterCleaner:Clean()

	-- Held apart from the character's own cleaner so putting the crate away drops its Activated
	-- binding without tearing down the equip watch that would put it back
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

		-- Only ever closes the crate's own panel, so putting a crate away while some other frame is
		-- open doesn't pull that one shut (or snap the camera's field of view back) with it
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

	-- FindFirstChild rather than WaitForChild: the loader runs every OnInit on one thread, so yielding
	-- here for a panel that hasn't been authored yet would hang the whole client boot.
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

		-- Asks for everything rather than for the cap, so someone holding more than the cap is told
		-- they've only opened part of their stack instead of it silently opening ten
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
