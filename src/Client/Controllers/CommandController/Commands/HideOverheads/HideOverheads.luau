-- Services
local Players = game:GetService("Players")

-- Local Player
local LocalPlayer = Players.LocalPlayer

-- Catches overheads for players who join while hidden; set only while hiding is on.
local addedConnection: RBXScriptConnection? = nil

-- Shows or hides an overhead UI on this client, leaving the local player's own untouched.
local function setOverheadVisible(child: Instance, visible: boolean)
	local owner = child:GetAttribute("Owner")
	if owner and owner ~= LocalPlayer.UserId then
		(child :: BillboardGui).Enabled = visible
	end
end

return {
	Name = "hideOverheads",
	Aliases = { "ho" },
	Description = "Toggles other players' overhead UIs on this client",
	Args = {},

	Run = function()
		local hiding = addedConnection == nil

		if addedConnection then
			addedConnection:Disconnect()
			addedConnection = nil
		else
			addedConnection = workspace.Terrain.ChildAdded:Connect(function(child)
				setOverheadVisible(child, false)
			end)
		end

		for _, child in workspace.Terrain:GetChildren() do
			setOverheadVisible(child, not hiding)
		end

		return if hiding then "Other players' overheads hidden" else "Other players' overheads shown"
	end,
}
