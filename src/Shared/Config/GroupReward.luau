--
export type GroupRewardItem = {
	Type: "Stick" | "Ingredient", -- which manager grants it; Id keys into Sticks or Ingredients
	Id: string,
	Amount: number,
}

--
local GroupReward = {}

-- The group required to claim, checked server-side. The public community group, not the staff one
GroupReward.GROUP_ID = 984015744

-- The place to favorite. Client-only, AvatarEditorService having no server side, so it's a nudge
GroupReward.FAVORITE_ASSET_ID = 87637454837254

-- One claim per player, forever. Config order is both the grant order and the icon layout
GroupReward.Data = {
	{ Type = "Stick", Id = "BambooStick", Amount = 1 },
	{ Type = "Ingredient", Id = "Tomato", Amount = 1 },
	{ Type = "Ingredient", Id = "Zucchini", Amount = 1 },
}
table.freeze(GroupReward.Data)

return GroupReward
