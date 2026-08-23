-- Services
local Players = game:GetService("Players")

--
local GlobalUtil = {}

--
function GlobalUtil.CreateAttachment(part0: BasePart): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = "Attachment"
	attachment.Parent = part0

	return attachment
end

-- Gets the first value in the table
function GlobalUtil.Weld(part0: BasePart, part1: BasePart)
	-- Create Weld
	local weldConstraint = Instance.new("WeldConstraint")
	weldConstraint.Part0 = part0
	weldConstraint.Part1 = part1
	weldConstraint.Parent = part0
end

-- Welds the model parts to the model primary part
function GlobalUtil.WeldModel(model: Model, anchorPrimary: boolean?)
	local primaryPart = model.PrimaryPart

	for _, v in model:GetDescendants() do
		if not v:IsA("BasePart") then
			continue
		end

		v.Anchored = false
		GlobalUtil.Weld(primaryPart, v)
	end

	primaryPart.Anchored = anchorPrimary
end

-- Gets all the players in the game
function GlobalUtil.GetAllCharacters(): { Model }
	local characters = {}

	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(characters, player.Character)
		end
	end

	return characters
end

function GlobalUtil.ConvertSecondsToHHMMSS(totalSeconds: number): string
	local hours = math.floor(totalSeconds / 3600)
	local minutes = math.floor((totalSeconds % 3600) / 60)
	local seconds = totalSeconds % 60

	return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

return GlobalUtil
