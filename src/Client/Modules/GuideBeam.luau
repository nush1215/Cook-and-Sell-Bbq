-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--
local LocalPlayer = Players.LocalPlayer

-- Authored in the place file, so a miss is a build problem -- warn rather than hang the caller
local ASSET_TIMEOUT = 10

-- Handed back when the template is missing, so a caller can call Destroy without checking.
local EMPTY_HANDLE = {
	Destroy = function() end,
}

-- The beam that points the player at something: one authored template, drawn from their root to a goal and hidden once they're close enough to act on it. Shared, so the tutorial and a waiting customer point the same way.

--
local GuideBeam = {}

-- The authored template. Cached as false on a miss too, or every call would sit through its own timeout
local template: Beam | false | nil = nil

-- Resolves the authored beam template, warning the first time it isn't there.
local function getTemplate(): Beam?
	if template ~= nil then
		return template or nil
	end

	local folder = ReplicatedStorage.Assets:WaitForChild("Tutorial", ASSET_TIMEOUT)
	local asset = folder and folder:WaitForChild("TutorialBeam", ASSET_TIMEOUT)

	if not asset then
		warn("GuideBeam: ReplicatedStorage.Assets.Tutorial.TutorialBeam is missing")
	end

	template = asset or false
	return asset
end

-- Resolves a beam endpoint to whatever carries a world position. An attachment resolves to itself.
local function resolveAnchor(target: Instance): (BasePart | Attachment)?
	if target:IsA("BasePart") or target:IsA("Attachment") then
		return target
	end

	-- Descendants, not children -- a structure is a model of models, so a shallow search comes back empty
	if target:IsA("Model") then
		return target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
	end

	return target:FindFirstChildWhichIsA("BasePart", true)
end

-- Where a resolved anchor sits in the world.
local function getAnchorPosition(anchor: BasePart | Attachment): Vector3
	return if anchor:IsA("Attachment") then anchor.WorldPosition else anchor.Position
end

-- Draws a beam to a goal, hidden within hideDistance. Beam and attachment live on Terrain, so streaming can't wipe them.
function GuideBeam.Create(target: Instance | (() -> Instance?), hideDistance: number): { Destroy: () -> () }
	local asset = getTemplate()
	if not asset then
		return EMPTY_HANDLE
	end

	-- Wrapped so the rest of the function always resolves through a function
	local resolveTarget: () -> Instance? = if type(target) == "function"
		then target :: () -> Instance?
		else function()
			return target :: Instance
		end

	-- A static target with no anchor is a wiring bug; a resolver may legitimately return nil
	if type(target) ~= "function" and not resolveAnchor(target :: Instance) then
		warn(`GuideBeam.Create: no BasePart or Attachment found for {(target :: Instance):GetFullName()}`)
	end

	local beam = asset:Clone()
	local goalAttachment = beam:FindFirstChild("0") :: Attachment
	local playerTemplate = beam:FindFirstChild("1") :: Attachment

	goalAttachment.Parent = workspace.Terrain
	beam.Attachment0 = goalAttachment
	beam.Attachment1 = nil
	beam.Enabled = false
	beam.Parent = workspace.Terrain

	local playerAttachment
	local function bindCharacter(character: Model)
		local root = character:WaitForChild("HumanoidRootPart", 5)
		if not root then
			return
		end

		if playerAttachment then
			playerAttachment:Destroy()
		end

		playerAttachment = playerTemplate:Clone()
		playerAttachment.Parent = root
		beam.Attachment1 = playerAttachment
	end

	if LocalPlayer.Character then
		bindCharacter(LocalPlayer.Character)
	end
	local characterAdded = LocalPlayer.CharacterAdded:Connect(bindCharacter)

	-- Cached so the per-frame cost is the resolver call, re-resolved when the instance changes
	local goalInstance: Instance? = nil
	local goalAnchor: (BasePart | Attachment)? = nil
	local function currentGoalAnchor(): (BasePart | Attachment)?
		local instance = resolveTarget()
		if instance ~= goalInstance or (goalAnchor and not goalAnchor.Parent) then
			goalInstance = instance
			goalAnchor = if instance then resolveAnchor(instance) else nil
		end

		return goalAnchor
	end

	local heartbeat = RunService.Heartbeat:Connect(function()
		local anchor = currentGoalAnchor()
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not anchor or not root or not playerAttachment or playerAttachment.Parent ~= root then
			beam.Enabled = false
			return
		end

		-- Pin the goal-side attachment onto the (possibly re-resolved) goal.
		local position = getAnchorPosition(anchor)
		goalAttachment.WorldPosition = position
		beam.Enabled = (root.Position - position).Magnitude > hideDistance
	end)

	return {
		Destroy = function()
			characterAdded:Disconnect()
			heartbeat:Disconnect()
			if playerAttachment then
				playerAttachment:Destroy()
			end
			goalAttachment:Destroy()
			beam:Destroy()
		end,
	}
end

return GuideBeam
