-- Services
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

-- Config
local Sticks = require(script.Parent.Sticks)
local BaseUnlocks = require(script.Parent.BaseUnlocks)
local Crates = require(script.Parent.Crates)
local StarterPack = require(script.Parent.StarterPack)
local BuxPacks = require(script.Parent.BuxPacks)
local CookSpeed = require(script.Parent.CookSpeed)
local Ingredients = require(script.Parent.Ingredients)

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

-- Stick Robux products, one per stick that has a real RobuxProductId (buying it grants the stick, see
-- StickShopManager). Generated from the stick config so name/icon stay in one place; a stick still on
-- the placeholder id of 0 is skipped, so its RobuxPurchase button stays disabled.
-- Every stick is walked rather than only the restockable ones: the diamond has no shop row and can't
-- be bought with currency at all, which is exactly why it needs a product to be gettable.
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

-- Base-unlock Robux products, one per level a dev product was made for (see BaseUnlocks.RobuxProductIds).
-- The tier only sets the price: every one of these buys the player's *next* level of that unlock, so a
-- receipt that lands out of order can't skip a level or hand out one they already own.
for _, unlock in BaseUnlocks.Data do
	if not unlock.RobuxProductIds then
		continue
	end

	for level, productId in unlock.RobuxProductIds do
		table.insert(Products.Data, {
			Id = BaseUnlocks.GetProductStringId(unlock.Id, level),
			Name = `{unlock.Name} (Level {level})`,
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

-- Crate Robux products, one per bundle a dev product was made for (see Crates.RobuxProductIds). The
-- amount is baked into the product rather than asked for at purchase time, so a receipt grants exactly
-- the bundle it was sold as.
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

				-- Lazy require to avoid pulling CrateManager's dependency graph at module load.
				local CrateManager = require(ServerScriptService.Server.Managers.CrateManager)
				CrateManager:GrantCrate(player, crate.Id, amount)
			end,
		})
	end
end

-- Cook-speed Robux products, one per price band (see CookSpeed.RobuxProductIds). The band only sets the
-- price: every one of these buys the next cook-speed level on whichever grill the player opened the
-- prompt from, which GrillerManager remembers, so a receipt that lands out of order can't skip a level.
for tier, productId in CookSpeed.RobuxProductIds do
	table.insert(Products.Data, {
		Id = CookSpeed.GetProductStringId(tier),
		Name = `Cook Speed Upgrade (Tier {tier})`,
		Type = "Core",
		PurchaseOnce = false,
		ProductId = productId,
		Callback = function(player: Player)
			if RunService:IsClient() then
				return
			end

			-- Lazy require to avoid pulling GrillerManager's dependency graph at module load.
			local GrillerManager = require(ServerScriptService.Server.Managers.GrillerManager)
			GrillerManager:GrantCookSpeedUpgradeFromProduct(player)
		end,
	})
end

-- Ingredient Robux products, one per price band (see Ingredients.RobuxProductIds). The band only sets
-- the price: every one of these buys whatever ingredient is sitting on the stand the player raised the
-- prompt from, which IngredientRollingManager remembers, so a receipt can't be spent on something dearer
-- than the band it was sold as. The band rides along to the grant for exactly that check.
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

			-- Lazy require to avoid pulling IngredientRollingManager's dependency graph at module load.
			local IngredientRollingManager = require(ServerScriptService.Server.Managers.IngredientRollingManager)
			IngredientRollingManager:GrantIngredientFromProduct(player, tier)
		end,
	})
end

-- The starter pack, if a dev product has been made for it yet. PurchaseOnce is what stops a second
-- buy server-side and what the shop card reads to pull itself the moment it's taken; the offer also
-- times out, which the card handles off the player's StarterPackStart stamp.
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

			-- Lazy require to avoid pulling ShopManager's dependency graph at module load -- and it
			-- requires this file, so a top-level require would be a cycle outright.
			local ShopManager = require(ServerScriptService.Server.Managers.ShopManager)
			ShopManager:GrantStarterPack(player)
		end,
	})
end

-- Bux packs, one product per pack a dev product was made for (see BuxPacks). Value carries the Bux
-- the pack hands over, which is what ShopManager:PromptCurrencyPurchase sorts on to find the cheapest
-- pack that covers what a player is short -- these are the first Currency-typed products in the game,
-- so that upsell only starts doing anything now.
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

			-- Lazy require to avoid pulling ShopManager's dependency graph at module load -- and it
			-- requires this file, so a top-level require would be a cycle outright.
			local ShopManager = require(ServerScriptService.Server.Managers.ShopManager)
			ShopManager:GrantBuxPack(player, pack.Id)
		end,
	})
end

-- Instantly finishes the cook the player opened the prompt from, settled perfect. Which grill that was
-- is remembered by GrillerManager rather than carried on the product, the same as the cook-speed bands:
-- the receipt arrives with nothing on it but the buyer.
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

		-- Lazy require to avoid pulling GrillerManager's dependency graph at module load.
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

		-- Lazy require to avoid pulling StickShopManager's dependency graph at module load.
		local StickShopManager = require(ServerScriptService.Server.Managers.StickShopManager)
		StickShopManager:RestockShop(player)
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
