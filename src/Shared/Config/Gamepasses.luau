--
export type Gamepass = {
	Id: string, -- also the tag ShopManager gives an owner, which is how the game asks who owns what
	Name: string,
	Icon: string?, -- rbxassetid; shop cards carry their own art, so this is only for anything that
	-- wants to draw a pass it hasn't got a card for
	PassId: number,
	GiftProductId: number?,
	OnPurchaseCallback: ((player: Player) -> ())?, -- will only be ran once when you purchase the gamepass
	OnInitializeCallback: ((player: Player) -> ())?, -- this will be ran for when the player purchase the gamepass and everytime the player joins the game
}

local Gamepasses = {}

-- A pass needs no callbacks when what it does is passive: ShopManager tags every owner with the pass's
-- Id, on purchase and again on each join, so the systems it affects just ask for the tag. Doubling
-- lives in CurrencyManager:IncrementCurrency for that reason, and the Id here is the tag it looks for.
Gamepasses.Data = {
	{
		Id = "x2Bux",
		Name = "x2 Bux",
		PassId = 1952486659,
	},
} :: { Gamepass }

table.freeze(Gamepasses.Data)

function Gamepasses.GetGamepassFromId(id: string)
	for _, v in Gamepasses.Data do
		if v.Id == id then
			return v
		end
	end

	return nil
end

function Gamepasses.GetGamepassFromPassId(passId: number)
	for _, v in Gamepasses.Data do
		if v.PassId == passId then
			return v
		end
	end

	return nil
end

function Gamepasses.GetGamepassFromGiftProductId(productId: number)
	for _, v in Gamepasses.Data do
		if v.GiftProductId == productId then
			return v
		end
	end

	return nil
end

function Gamepasses.GetAllGamepasses()
	return Gamepasses.Data
end

return Gamepasses
