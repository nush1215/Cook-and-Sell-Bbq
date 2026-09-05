-- Services
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

-- Config
local Sticks = require(script.Parent.Sticks)
local BaseUnlocks = require(script.Parent.BaseUnlocks)
local Plots = require(script.Parent.Plots)
local Crates = require(script.Parent.Crates)
local StarterPack = require(script.Parent.StarterPack)
local BuxPacks = require(script.Parent.BuxPacks)
local Ingredients = require(script.Parent.Ingredients)
local Structures = require(script.Parent.Structures)

--
export type Product = {
	Id: string,
	Name: string,
	Type: "Core" | "Troll" | "Currency" | "Stick",
	Description: string?,
	PurchaseOnce: boolean,
	Icon: string?,
	ProductId: number,
	CurrencyPrice: number?,
	Value: number?, -- this is optional mostly used for reference how much X amount an X thing is
	Callback: (player: Player, toGift: Player?) -> ()?,
}

local Products = {}
Products.Data = {}

-- One product per stick with a real id, generated from the stick config. Every stick is walked -- the diamond has no shop row, which is why it needs one.
for _, stick in Sticks.GetAllSticks() do
	if not stick.RobuxProductId or stick.RobuxProductId == 0 then
		continue
	end

	table.insert(Products.Data, {
		Id = stick.Id,
		Name = `{stick.Name} Stick`,
		Type = "Stick",
		Description = `Instantly get a {stick.Name} Stick`,
		PurchaseOnce = false,
		Icon = stick.Icon,
		ProductId = stick.RobuxProductId,
	})
end

-- One per unlock level with a product. The tier only sets the price -- every one buys the player's next level, so one id can cover a band and a receipt can't skip or repeat.
for _, unlock in BaseUnlocks.Data do
	if not unlock.RobuxProductIds then
		continue
	end

	for level, productId in unlock.RobuxProductIds do
		table.insert(Products.Data, {
			Id = BaseUnlocks.GetProductStringId(unlock.Id, level),
			Name = `{unlock.Name} Upgrade`,
			Type = "Core",
			PurchaseOnce = false,
			ProductId = productId,
			Callback = function(player: Player)
				if RunService:IsClient() then
					return
				end

				-- Lazy require to avoid pulling BaseManager's dependency graph at module load.
				local BaseManager = require(ServerScriptService.Server.Managers.BaseManager)
				BaseManager:PurchaseUnlockUpgrade(player, unlock.Id, true)
			end,
		})
	end
end

-- One per plot. The index only sets the price; which plot was chosen is remembered by BaseManager.
for index, productId in Plots.RobuxProductIds do
	table.insert(Products.Data, {
		Id = Plots.GetProductStringId(index),
		Name = `Plot Upgrade {index}`,
		Type = "Core",
		PurchaseOnce = false,
		ProductId = productId,
		Callback = function(player: Player)
			if RunService:IsClient() then
				return
			end

			-- Lazy require to avoid pulling BaseManager's dependency graph at module load.
			local BaseManager = require(ServerScriptService.Server.Managers.BaseManager)
			BaseManager:GrantPlotFromProduct(player)
		end,
	})
end

-- One per crate bundle. The amount is baked in, so a receipt grants exactly the bundle it was sold as.
for _, crate in Crates.Data do
	if not crate.RobuxProductIds then
		continue
	end

	for amount, productId in crate.RobuxProductIds do
		table.insert(Products.Data, {
			Id = Crates.GetProductStringId(crate.Id, amount),
			Name = `x{amount} {crate.Name}`,
			Type = "Core",
			Description = `Instantly get x{amount} {crate.Name}`,
			PurchaseOnce = false,
			Icon = crate.Icon,
			ProductId = productId,
			Callback = function(player: Player)
				if RunService:IsClient() then
					return
				end

				-- Lazy require, to avoid pulling CrateManager's dependency graph at module load
				local CrateManager = require(ServerScriptService.Server.Managers.CrateManager)
				CrateManager:GrantCrate(player, crate.Id, amount)
			end,
		})
	end
end

-- One per ingredient price band. Which stand the prompt came from is remembered, and the band rides along so a receipt can't buy something dearer.
for tier, productId in Ingredients.RobuxProductIds do
	table.insert(Products.Data, {
		Id = Ingredients.GetProductStringId(tier),
		Name = `Ingredient (Tier {tier})`,
		Type = "Core",
		PurchaseOnce = false,
		ProductId = productId,
		Callback = function(player: Player)
			if RunService:IsClient() then
				return
			end

			-- Lazy require, to avoid pulling IngredientRollingManager's dependency graph at module load
			local IngredientRollingManager = require(ServerScriptService.Server.Managers.IngredientRollingManager)
			IngredientRollingManager:GrantIngredientFromProduct(player, tier)
		end,
	})
end

-- One per structure with a product, its Id being the structure's. No Callback -- GrillStandShopManager already grants off PlayerPurchased.
for _, structure in Structures.Data do
	if not structure.RobuxProductId or structure.RobuxProductId == 0 then
		continue
	end

	table.insert(Products.Data, {
		Id = structure.Id,
		Name = structure.Name,
		Type = "Core",
		Description = `Instantly get a {structure.Name}`,
		PurchaseOnce = false,
		Icon = structure.Icon,
		ProductId = structure.RobuxProductId,
	})
end

-- The starter pack. PurchaseOnce stops a second buy and pulls the card; the offer also times out.
if StarterPack.RobuxProductId ~= 0 then
	table.insert(Products.Data, {
		Id = StarterPack.Id,
		Name = StarterPack.Name,
		Type = "Core",
		Description = `A one-time bundle for new players`,
		PurchaseOnce = true,
		ProductId = StarterPack.RobuxProductId,
		Callback = function(player: Player)
			if RunService:IsClient() then
				return
			end

			-- Lazy require: ShopManager requires this file, so a top-level one would be a cycle outright
			local ShopManager = require(ServerScriptService.Server.Managers.ShopManager)
			ShopManager:GrantStarterPack(player)
		end,
	})
end

-- One per Bux pack. Value carries the Bux granted, which the currency upsell sorts on.
for _, pack in BuxPacks.Data do
	if pack.RobuxProductId == 0 then
		continue
	end

	table.insert(Products.Data, {
		Id = pack.Id,
		Name = pack.Name,
		Type = "Currency",
		Description = `Instantly get ${pack.Amount} Bux`,
		PurchaseOnce = false,
		ProductId = pack.RobuxProductId,
		Value = pack.Amount,
		Callback = function(player: Player)
			if RunService:IsClient() then
				return
			end

			-- Lazy require: ShopManager requires this file, so a top-level one would be a cycle outright
			local ShopManager = require(ServerScriptService.Server.Managers.ShopManager)
			ShopManager:GrantBuxPack(player, pack.Id)
		end,
	})
end

-- Finishes the cook the prompt was opened from, settled perfect. Which grill is remembered by GrillerManager -- the receipt names only the buyer.
table.insert(Products.Data, {
	Id = "SkipCook",
	Name = "Skip Cooking",
	Type = "Core",
	Description = "Instantly finish the BBQ you're cooking, perfectly cooked",
	PurchaseOnce = false,
	ProductId = 3709026482,
	Callback = function(player: Player)
		if RunService:IsClient() then
			return
		end

		-- Lazy require, to avoid pulling GrillerManager's dependency graph at module load
		local GrillerManager = require(ServerScriptService.Server.Managers.GrillerManager)
		GrillerManager:GrantSkipCookFromProduct(player)
	end,
})

table.insert(Products.Data, {
	Id = "StickShopRestock",
	Name = "Stick Shop Restock",
	Type = "Core",
	Description = "Restock the Stick Shop for everyone in the server",
	PurchaseOnce = false,
	ProductId = 3709026355,
	Callback = function(player: Player)
		if RunService:IsClient() then
			return
		end

		-- Lazy require, to avoid pulling StickShopManager's dependency graph at module load
		local StickShopManager = require(ServerScriptService.Server.Managers.StickShopManager)
		StickShopManager:RestockShop(player)
	end,
})

table.insert(Products.Data, {
	Id = "GrillStandShopRestock",
	Name = "Grill & Stand Shop Restock",
	Type = "Core",
	Description = "Restock the Grill & Stand Shop for everyone in the server",
	PurchaseOnce = false,
	ProductId = 3709814926,
	Callback = function(player: Player)
		if RunService:IsClient() then
			return
		end

		-- Lazy require, to avoid pulling GrillStandShopManager's dependency graph at module load
		local GrillStandShopManager = require(ServerScriptService.Server.Managers.GrillStandShopManager)
		GrillStandShopManager:RestockShop(player)
	end,
})

table.freeze(Products.Data)

function Products.GetProductFromId(id: string): Product?
	for _, v in Products.Data do
		if v.Id == id then
			return v
		end
	end

	return nil
end

function Products.GetProductFromProductId(productId: number): Product?
	for _, v in Products.Data do
		if v.ProductId == productId then
			return v
		end
	end

	return nil
end

function Products.GetProductsByType(productType: "Core" | "Troll" | "Currency" | "Stick"): { Product }
	local products = {}
	for _, v in Products.Data do
		if v.Type == productType then
			table.insert(products, v)
		end
	end

	return products
end

function Products.GetProducts(): { Product }
	return Products.Data
end

return Products
