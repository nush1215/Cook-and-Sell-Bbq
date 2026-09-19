-- Every update's changes as the Update Log lists them. Newest first: the first entry is what the log opens on and what returning players are shown on join.

--
export type UpdateLog = {
	Title: string, -- the log button's label and the details header; also the seen stamp, so renaming a shipped one shows it again
	Icon: string, -- rbxassetid for the log button's Icon
	Changes: { string }, -- one line each, in order. RichText with keywords coloured (Config.Keywords), so write & as &amp;
}

--
local UpdateLogs = {}

-- The ScreenGui the log is shown on
UpdateLogs.UI_NAME = "UpdateLogsUI"

UpdateLogs.TOPBAR_ICON = "rbxassetid://125038232865596"

UpdateLogs.Data = {
	{
		Title = "Update 1.0",
		Icon = "rbxassetid://114320586328216",
		Changes = {
			"- 30 New Ingredients",
			"- Gems",
			"- Cosmetics/Decorations",
			"- Tables",
			"- Quests",
			"- Bug Fixes + QOL",
			"USE CODE: UPDATE1",
		},
	},
} :: { UpdateLog }

table.freeze(UpdateLogs.Data)

return UpdateLogs
