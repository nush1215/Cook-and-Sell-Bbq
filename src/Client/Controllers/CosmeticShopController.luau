-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Replica = require(Packages.Replica)
local Zone = require(Packages.ZonePlus)

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)
local GuiUtil = require(Shared.GuiUtil)
local Colors = require(Shared.Colors)
local CosmeticShop = require(Shared.Config.CosmeticShop)
local Structures = require(Shared.Config.Structures)

-- Controllers
local UIController = require(script.Parent.UIController)
local PlayerDataController = require(script.Parent.PlayerDataController)
local NotificationController = require(script.Parent.NotificationController)

-- Local Player
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

--
local TIME_LEFT_ATTRIBUTE = "CosmeticShopTimeLeft"
local BUY_DEBOUNCE = 0.3 -- client-side only; the server's _purchasing guard is authoritative

-- The colour the countdown is shown in, matching the other shops' restock titles
local RESTOCK_TIME_COLOR = "#55ff00"

-- The zone out in the world that opens the shop, under workspace.Core.Zones.
local ZONE_NAME = "CosmeticShop"

-- The authored slot frames under Holder each tier fills, in the order the tier's offers were drawn
local TIER_SLOTS = {
	Featured = { "Featured" },
	Great = { "GreatSlot1", "GreatSlot2" },
	Good = { "GoodSlot1", "GoodSlot2", "GoodSlot3" },
}

-- The Cosmetic Shop panel: six fixed slots repainted with whatever this hour's rotation drew, each bought for Gems.
local CosmeticShopController = {
	PurchaseCosmeticEvent = Network.Event("PurchaseCosmetic"), -- client -> server (structureId)
	CosmeticShopOpenedEvent = Network.Event("CosmeticShopOpened"), -- client -> server (no args)
	CosmeticDetailsViewedEvent = Network.Event("CosmeticDetailsViewed"), -- client -> server (structureId)

	_replica = nil,
	_buyDebounce = false,
	_slotOffers = {}, -- [slot frame name] = the structure id it's showing this rotation
}

-- Requests a purchase; the server validates it and says why with a toast when it refuses.
function CosmeticShopController:Buy(structureId: string)
	if self._buyDebounce then
		return
	end

	self._buyDebounce = true
	task.delay(BUY_DEBOUNCE, function()
		self._buyDebounce = false
	end)

	self.PurchaseCosmeticEvent:FireServer(structureId)
end

-- Paints every slot with what this rotation drew into it: icon, name, rarity, how many are left and the price.
function CosmeticShopController:_refreshSlots()
	if not self._replica then
		return
	end

	-- A ledger from an older rotation reads as nothing bought yet, the same as the server treats it
	local data = PlayerDataController:GetData()
	local ledger = data.CosmeticShop
	local bought = if ledger.Seed == self._replica.Data.Seed then ledger.Bought else {}

	for tierId, frameNames in TIER_SLOTS do
		local drawn = self._replica.Data.Offers[tierId]

		for index, frameName in frameNames do
			local frame = self.UI.Holder[frameName]
			local structureId = drawn[index]

			-- Only a tier the config left short of offers draws fewer than its slots, and it warns at load
			self._slotOffers[frameName] = structureId
			frame.Visible = structureId ~= nil
			if not structureId then
				continue
			end

			local offer = CosmeticShop.GetOffer(structureId)
			local structure = Structures.GetStructureFromId(structureId)

			frame.Icon.Image = structure.Icon

			frame.Title.Text = CosmeticShop.GetOfferName(offer)
			frame.Title.TextColor3 = structure.TextColor
			local titleStroke = frame.Title:FindFirstChildWhichIsA("UIStroke")
			if titleStroke then
				titleStroke.Color = structure.StrokeColor
			end

			-- Featured carries no rarity label, being the one slot whose art already says it's special
			local rarity = frame:FindFirstChild("Rarity")
			if rarity then
				rarity.Text = structure.Rarity
				rarity.TextColor3 = Colors[structure.Rarity].TextColor
				local rarityStroke = rarity:FindFirstChildWhichIsA("UIStroke")
				if rarityStroke then
					rarityStroke.Color = Colors[structure.Rarity].StrokeColor
				end
			end

			frame.Stocks.Text = `x{CosmeticShop.STOCK - (bought[structureId] or 0)} Stock`
			frame.GemsPurchase.Holder.Amount.Text = GuiUtil.ConvertNumberWithSuffix(CosmeticShop.GetPrice(offer, data))
		end
	end
end

-- Writes the rotation's time left into the timer. Every unit always shown, so the last stretch reads "0h 0m 9s".
function CosmeticShopController:_refreshTimer()
	local timeLeft = ReplicatedStorage:GetAttribute(TIME_LEFT_ATTRIBUTE) or 0
	local hours = math.floor(timeLeft / 3600)
	local minutes = math.floor(timeLeft % 3600 / 60)
	local seconds = math.floor(timeLeft % 60)

	self.UI.Holder.Timer.Text = `Restocks in <font color="{RESTOCK_TIME_COLOR}">{hours}h {minutes}m {seconds}s</font>`
end

function CosmeticShopController:OnInit()
	self.UI = PlayerGui:WaitForChild("CosmeticShopUI")

	Replica.OnNew("CosmeticShop", function(replica)
		self._replica = replica
		replica:OnChange(function()
			self:_refreshSlots()
		end)
		self:_refreshSlots()
	end)
end

function CosmeticShopController:OnStart()
	local holder = self.UI.Holder
	holder.Visible = false

	-- Bound once per slot rather than per rotation: each acts on whatever its slot is showing when pressed
	for _, frameNames in TIER_SLOTS do
		for _, frameName in frameNames do
			UIController:BindButtonClick(holder[frameName].GemsPurchase, function()
				local structureId = self._slotOffers[frameName]
				if structureId then
					self:Buy(structureId)
				end
			end, true)

			UIController:BindButtonClick(holder[frameName].Details, function()
				local structureId = self._slotOffers[frameName]
				if structureId then
					NotificationController:NotifyNormal({ Text = Structures.GetStructureFromId(structureId).Description })
					-- Every tap is sent; the server is what counts only the first on each offer
					self.CosmeticDetailsViewedEvent:FireServer(structureId)
				end
			end, true)
		end
	end

	-- The server mirrors the seconds left onto the attribute once a second
	holder.Timer.RichText = true
	self:_refreshTimer()
	ReplicatedStorage:GetAttributeChangedSignal(TIME_LEFT_ATTRIBUTE):Connect(function()
		self:_refreshTimer()
	end)

	-- Looked up rather than waited on -- an unauthored zone would silently strand the rest of this
	local zonePart = workspace:WaitForChild("Core"):WaitForChild("Zones"):FindFirstChild(ZONE_NAME)
	if zonePart then
		local zone = Zone.new(zonePart)
		zone.localPlayerEntered:Connect(function()
			UIController:OpenFrame(holder)
			self.CosmeticShopOpenedEvent:FireServer()
		end)
		zone.localPlayerExited:Connect(function()
			UIController:CloseFrame(holder)
		end)
	else
		warn(`No Core.Zones.{ZONE_NAME} in the place file, the Cosmetic Shop can't be walked into`)
	end

	UIController:BindButtonClick(holder.Exit, function()
		UIController:CloseFrame(holder)
	end, true)

	-- First paint + keep the stock live. Deferred: the ledger read awaits the player-data replica.
	task.spawn(function()
		self:_refreshSlots()

		PlayerDataController:ListenForChange("CosmeticShop", function()
			self:_refreshSlots()
		end)

		-- Every grant lands here, and a climbing offer's price is only right against what they own
		PlayerDataController:ListenForChange("OwnedStructures", function()
			self:_refreshSlots()
		end)
	end)
end

return CosmeticShopController
