--
export type GroupRewardItem = {
	Type: "Stick" | "Ingredient", -- which manager grants it; Id keys into Sticks or Ingredients
	Id: string,
	Amount: number,
}

--
local GroupReward = {}

-- The group a player has to be in to claim. Checked server-side off GroupService, so it's the
-- authoritative half of the requirement. This is the public community group, not the staff group
-- the admin commands gate on.
GroupReward.GROUP_ID = 984015744

-- The place players have to favorite. Only ever read on the client -- AvatarEditorService has no
-- server equivalent -- so this half of the requirement is a nudge rather than a guarantee.
GroupReward.FAVORITE_ASSET_ID = 87637454837254

-- One claim per player, forever. Config order is the order the reward is granted in, which is also
-- the order the (static) reward icons are laid out in on GroupRewardUI.
GroupReward.Data = {
	{ Type = "Stick", Id = "BambooStick", Amount = 1 },
	{ Type = "Ingredient", Id = "Tomato", Amount = 1 },
	{ Type = "Ingredient", Id = "Zucchini", Amount = 1 },
}
table.freeze(GroupReward.Data)

return GroupReward
