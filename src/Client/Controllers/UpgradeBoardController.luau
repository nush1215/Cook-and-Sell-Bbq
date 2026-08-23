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
local BaseUnlocks = require(Shared.Config.BaseUnlocks)

-- Controllers
local NotificationController = require(script.Parent.NotificationController)
local PlayerDataController
local UIController
local ShopController

-- Assets
local UI = ReplicatedStorage.Assets.UI

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- Drives the always-on upgrade board adorned to the owner's Base.Upgrades.Board part. Each section
-- buys the next level of a BaseUnlocks group by firing the existing PurchaseUnlockUpgrade remote --
-- the server owns all validation, currency, and the world re-render, so this is display + a fire.
-- It also raises the owner-only icon on the base nameplate, the one piece of that plate the server
-- can't put up itself, since it has to show to the owner and nobody else.
-- Its second job is the affordability nudge: the board only ever shows a price, so without this the
-- player has to keep coming back to it to find out whether they can afford anything yet.
local UpgradeBoardController = {
	PurchaseUnlockUpgradeEvent = Network.Event("PurchaseUnlockUpgrade"),

	_baseCleaner = Trove.new(), -- board clone, button bindings and data listeners for the current base

	-- [unlockId] = the next level we've already told the player they can afford, so crossing the same
	-- threshold twice stays quiet. Buying the level makes the stored number stale and re-arms the next.
	_notifiedLevels = {},

	_sections = {}, -- { frame, unlock } per section of the board currently mounted; empty off a base
}

-- The one ScreenGui the board lives under. It sits in PlayerGui (adorned back onto the world board)
-- rather than in the world, because that's what makes its buttons clickable.
local function getScreenGui(): ScreenGui
	local screenGui = PlayerGui:FindFirstChild("UpgradeBoard")
	if screenGui == nil then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "UpgradeBoard"
		screenGui.ResetOnSpawn = false
		screenGui.Parent = PlayerGui
	end

	return screenGui
end

-- Paints one section from current player data: the title ("Stick Stands (2)"), the level line ("2>3"
-- or "Max (5)"), the currency price, and hides the buy buttons once the stand is maxed so a
-- fully-upgraded one can't be fired at.
function UpgradeBoardController:_refreshSection(frame: Frame, unlock: BaseUnlocks.Unlock)
	local unlocks = PlayerDataController:GetKey("Unlocks") or {}
	local level = unlocks[unlock.Id] or 0
	-- Gate on Limit, not #Costs: RollingStands keeps costs dense past its cap.
	local isMax = level >= unlock.Limit

	frame.Title.Text = `{unlock.Name} ({level})`
	frame.Level.Text = if isMax then `Max ({unlock.Limit})` else `{level}>{level + 1}`
	frame.Buttons.Visible = not isMax

	if isMax then
		return
	end

	-- Matches the server's Costs[currentLevel + 1] next-level cost.
	frame.Buttons.CurrencyPurchase.Title.Text = `${GuiUtil.ConvertNumberWithSuffix(unlock.Costs[level + 1])}`

	-- Robux is only offered on a level a dev product was actually made for, so a stand whose top step
	-- has no product (the sixth rolling stand) shows the currency button on its own.
	local productId = unlock.RobuxProductIds and unlock.RobuxProductIds[level + 1]
	frame.Buttons.RobuxPurchase.Visible = productId ~= nil

	if productId then
		-- "-" until the MarketplaceService lookup lands (or if it failed), matching ShopController:GetPrice.
		local stringId = BaseUnlocks.GetProductStringId(unlock.Id, level + 1)
		frame.Buttons.RobuxPurchase.Title.Text = `{GuiUtil.ROBUX_ICON}{ShopController:GetCachedPrice(stringId) or "-"}`
	end
end

-- Wires a section's buy buttons once. Currency fires the upgrade remote, Robux prompts that level's dev
-- product; either way the server is the one that decides what the next level is and grants it.
function UpgradeBoardController:_bindSection(frame: Frame, unlock: BaseUnlocks.Unlock)
	local currencyBinding = UIController:BindButtonClick(frame.Buttons.CurrencyPurchase, function()
		self.PurchaseUnlockUpgradeEvent:FireServer(unlock.Id)
	end, true)
	self._baseCleaner:Add(currencyBinding.Disconnect)

	local robuxBinding = UIController:BindButtonClick(frame.Buttons.RobuxPurchase, function()
		self:_onRobuxPurchase(unlock.Id)
	end, true)
	self._baseCleaner:Add(robuxBinding.Disconnect)
end

-- Buys the next level of a stand with Robux. The product is per level -- the tier only sets the price,
-- the server grants whatever the player's next level is -- so the one to prompt is read off the level
-- they're on, the same way the currency button's price is.
function UpgradeBoardController:_onRobuxPurchase(unlockId: string)
	local unlock = BaseUnlocks.GetUnlockFromId(unlockId)
	local level = (PlayerDataController:GetKey("Unlocks") or {})[unlockId] or 0

	-- The button hides on a level with no product, so this only catches a press that raced the refresh.
	if not unlock.RobuxProductIds or not unlock.RobuxProductIds[level + 1] then
		return
	end

	ShopController:PromptProductPurchaseFromId(BaseUnlocks.GetProductStringId(unlockId, level + 1))
end

-- Warms ShopController's price cache for every unlock level a dev product was made for, since GetPrice
-- yields on its first MarketplaceService call for an id and the buttons are painted from a data change.
-- Repaints the board afterwards so a section drawn while the lookups were in flight picks its price up.
-- Walks the whole config rather than the board's sections, the same way _notifyAffordableUpgrades does,
-- so the grillers -- priced on their own unlock sign, with no section here -- are warmed by this too.
function UpgradeBoardController:_cacheRobuxPrices()
	for _, unlock in BaseUnlocks.Data do
		if not unlock.RobuxProductIds then
			continue
		end

		for level in unlock.RobuxProductIds do
			ShopController:GetPrice(BaseUnlocks.GetProductStringId(unlock.Id, level))
		end
	end

	self:_refreshSections()
end

-- Repaints every section of the mounted board. Nothing to do before a base is claimed, since the board
-- is only ever mounted on the local player's own.
function UpgradeBoardController:_refreshSections()
	for _, section in self._sections do
		self:_refreshSection(section.frame, section.unlock)
	end
end

-- Tells the player when their balance first covers the next level of a base upgrade, so they know to
-- go and buy it rather than having to re-read the prices themselves. Latched per level: the next
-- level already announced is remembered, so a balance that dips under the cost and climbs back stays
-- quiet, while buying the level makes the stored number stale and re-arms the one after it.
-- Walks the whole config rather than the board's sections, so the grillers -- bought out at their own
-- unlock sign, with no section here -- are covered too.
function UpgradeBoardController:_notifyAffordableUpgrades(currency: number)
	local unlocks = PlayerDataController:GetKey("Unlocks") or {}

	for _, unlock in BaseUnlocks.Data do
		local level = unlocks[unlock.Id] or 0
		local nextLevel = level + 1

		-- Same gate as the board and the server: past Limit (or the last cost) is fully upgraded.
		local cost = unlock.Costs[nextLevel]
		if nextLevel > unlock.Limit or not cost then
			continue
		end

		if currency < cost or self._notifiedLevels[unlock.Id] == nextLevel then
			continue
		end

		self._notifiedLevels[unlock.Id] = nextLevel

		NotificationController:NotifyNormal({
			Text = `{unlock.Name} upgrade available for ${GuiUtil.ConvertNumberWithSuffix(cost)}!`,
			Duration = 4,
			Sound = "CanPurchase",
			Effect = "Success",
		})
	end
end

-- Rebuilds the board on whichever base the local player currently owns. Owner-only: Unlocks only
-- replicate to the owner, so the board only mounts on their own base.
function UpgradeBoardController:_setupBase()
	self._baseCleaner:Clean()

	-- The clean above destroyed the frames these point at, so they're dropped with them rather than
	-- left for a refresh to index.
	self._sections = {}

	local baseId = LocalPlayer:GetAttribute("BaseId")
	if not baseId then
		return
	end

	local base = workspace.Base[baseId]

	-- The "this one's yours" marker on the base nameplate. The server puts the plate up for everyone
	-- with this piece down, since it's the only part of it that differs per viewer. Waited on rather
	-- than indexed: the plate is made the moment the base is claimed, so it can still be in flight
	-- when BaseId lands here.
	task.spawn(function()
		local baseIcon = base.BaseAttachment:WaitForChild("BaseUI").BaseIcon
		baseIcon.Visible = true

		self._baseCleaner:Add(function()
			baseIcon.Visible = false
		end)
	end)

	local board = base.Upgrades.Board

	local clone = UI.MainUpgradesUI:Clone()
	clone.Adornee = board
	clone.Active = true
	clone.Parent = getScreenGui()
	self._baseCleaner:Add(clone)

	self._sections = {
		{ frame = clone.IngredientRolls, unlock = BaseUnlocks.GetUnlockFromId("RollingStands") },
		{ frame = clone.StickStands, unlock = BaseUnlocks.GetUnlockFromId("StickStand") },
	}

	for _, section in self._sections do
		self:_bindSection(section.frame, section.unlock)
	end

	-- GetKey awaits the replica, so keep the first refresh and the listener off the setup thread.
	task.spawn(function()
		self:_refreshSections()

		self._baseCleaner:Add(PlayerDataController:ListenForChange("Unlocks", function()
			self:_refreshSections()
		end))
	end)
end

function UpgradeBoardController:OnInit()
	PlayerDataController = require(script.Parent.PlayerDataController)
	UIController = require(script.Parent.UIController)
	ShopController = require(script.Parent.ShopController)
end

function UpgradeBoardController:OnStart()
	LocalPlayer:GetAttributeChangedSignal("BaseId"):Connect(function()
		self:_setupBase()
	end)

	-- Sweep once, since BaseId may already be set by the time we start.
	self:_setupBase()

	task.spawn(function()
		self:_cacheRobuxPrices()
	end)

	-- Kept off the base cleaner on purpose: the latch and this listener outlive a base being handed
	-- back and reassigned, since the unlocks they track are the player's rather than the base's.
	-- ListenForChange awaits the replica, so keep it off the start thread. Only gains are checked: a
	-- purchase drops the balance and raises the level together, so re-checking on the way down would
	-- stack the next level's notification straight on top of the "Upgraded!" one the server just sent.
	task.spawn(function()
		PlayerDataController:ListenForChange("Currency", function(new, old)
			if new <= old then
				return
			end

			self:_notifyAffordableUpgrades(new)
		end)
	end)
end

return UpgradeBoardController
