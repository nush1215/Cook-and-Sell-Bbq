-- Services
local ServerScriptService = game:GetService("ServerScriptService")

-- Managers
local Managers = ServerScriptService.Server.Managers
local StickManager = require(Managers.StickManager)
local IngredientManager = require(Managers.IngredientManager)

export type Code = {
	Code: string, -- what the player types, matched case-insensitively
	OnClaimMessage: string, -- second notification after the generic success one, spelling out the reward
	Callback: (player: Player) -> (),
}

--
local Codes = {}
Codes.Data = {
	{
		Code = "RELEASE",
		OnClaimMessage = "Enjoy a Wooden Stick, Tomato, and Zucchini on the house! 😋",
		Callback = function(player: Player)
			StickManager:GrantStick(player, "WoodenStick")
			IngredientManager:GrantIngredient(player, "Tomato")
			IngredientManager:GrantIngredient(player, "Zucchini")
		end,
	},
}

function Codes.GetCodeFromCode(code: string): Code?
	for _, v in Codes.Data do
		if v.Code:lower() == code:lower() then
			return v
		end
	end

	return nil
end

return Codes
