-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local Spr = require(Packages.Spr)

-- Shared
local Shared = ReplicatedStorage.Shared
local SellNpc = require(Shared.Config.SellNpc)

-- Modules
local BubbleChat = require(script.Parent.BubbleChat)

-- Assets
local UI = ReplicatedStorage.Assets.UI

--
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- The billboard rises BUBBLE_CLEARANCE studs per active bubble, so it clears the stack and steps back
local BUBBLE_CLEARANCE = 0
local RAISE_DAMPING = 0.7
local RAISE_FREQUENCY = 3

-- The Title's pulse per swap. The flip decelerates, so the pulses come fast then settle on the verdict
local PULSE_START_INITIAL = 0.9 -- the bubble's first appearance
local PULSE_START_SWAP = 0.9 -- every verdict swap after the first
local PULSE_TARGET = 1
local PULSE_DAMPING = 0.5 -- < 1 for a little overshoot, so each swap pops
local PULSE_FREQUENCY = 6

-- The two verdicts the Title flips between (and lands on).
local INTERESTED = {
	Text = "Interested",
	TextColor = Color3.fromRGB(0, 255, 0),
	StrokeColor = Color3.fromRGB(0, 42, 0),
}
local NOT_INTERESTED = {
	Text = "Not Interested",
	TextColor = Color3.fromRGB(255, 0, 0),
	StrokeColor = Color3.fromRGB(85, 0, 0),
}

-- Mounts an NPC's billboards and speaks its lines. Shared by every customer, since the mounting is what makes the buttons clickable and getting it wrong is invisible until a touch tap misses.

--
local NpcBillboard = {}

-- The billboards' ScreenGui. In PlayerGui adorned back onto the NPC, which is what makes buttons clickable.
local function getScreenGui(): ScreenGui
	local screenGui = PlayerGui:FindFirstChild("NpcBillboards")
	if screenGui == nil then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "NpcBillboards"
		screenGui.ResetOnSpawn = false
		screenGui.Parent = PlayerGui
	end

	return screenGui
end

-- Paints the Title with one verdict. Direct assignment, so a fast flip lands crisply rather than smearing.
local function applyVerdict(title: TextLabel, stroke: UIStroke, verdict)
	title.Text = verdict.Text
	title.TextColor3 = verdict.TextColor
	stroke.Color = verdict.StrokeColor
end

-- Snaps the Title scale down to `startScale`, then springs it back to 1 -- the per-swap pop.
local function pulseScale(scale: UIScale, startScale: number)
	Spr.stop(scale, "Scale")
	scale.Scale = startScale
	Spr.target(scale, PULSE_DAMPING, PULSE_FREQUENCY, { Scale = PULSE_TARGET })
end

-- Mounts `templateName`'s billboards on the NPC's head and returns the state a caller drives them through, or nil if the rig has no head yet. `billboards` is every BillboardGui the template held, by name.
function NpcBillboard.Attach(npc: Model, templateName: string, dialogueVariant: string?, dialoguePrefix: string)
	local head = npc:FindFirstChild("Head") or npc:FindFirstChild("HumanoidRootPart")
	if not head then
		return nil
	end

	-- Cloned only to read the billboards and the authored head offset, then dropped
	local holder = UI[templateName]:Clone()
	local restOffset = holder.Position

	local billboards = {}
	for _, child in holder:GetChildren() do
		if child:IsA("BillboardGui") then
			billboards[child.Name] = child
		end
	end

	-- Adorned to the head, not an attachment -- an Attachment adornee cost the offer buttons every touch tap
	local screenGui = getScreenGui()
	for _, billboard in billboards do
		billboard.Adornee = head
		billboard.StudsOffsetWorldSpace = restOffset
		-- Zeroed: both scale with adornee size, so what did nothing on an Attachment would shift it on a head
		billboard.ExtentsOffset = Vector3.zero
		billboard.ExtentsOffsetWorldSpace = Vector3.zero
		billboard.Active = true
		billboard.Parent = screenGui
	end

	holder:Destroy()

	local trove = Trove.new()
	-- Added, since the billboards live in PlayerGui and nothing on the NPC takes them down with it
	for _, billboard in billboards do
		trove:Add(billboard)
	end
	-- Stop the springs before they're destroyed (Trove cleans in reverse add order)
	trove:Add(function()
		for _, billboard in billboards do
			Spr.stop(billboard)
		end
	end)

	local state = {
		trove = trove,
		running = true,
		bubbleCount = 0,
		dialogueVariant = dialogueVariant,
		dialoguePrefix = dialoguePrefix,
		billboards = billboards,
	}

	-- Springs the billboards clear of the current bubble stack, settling back as they expire
	local function updateRaise()
		local lift = restOffset + Vector3.new(0, BUBBLE_CLEARANCE * state.bubbleCount, 0)
		for _, billboard in billboards do
			Spr.target(billboard, RAISE_DAMPING, RAISE_FREQUENCY, { StudsOffsetWorldSpace = lift })
		end
	end

	-- Every beat funnels through here, so the variant makes the whole exchange react to the skewer
	function state.speak(category: string)
		local duration = BubbleChat.SayRandom(head, category, state.dialogueVariant)
		if not duration then
			return
		end

		state.bubbleCount += 1
		updateRaise()

		task.delay(duration, function()
			if state.running then
				state.bubbleCount -= 1
				updateRaise()
			end
		end)
	end

	return state
end

-- Runs the Interested/Not Interested flip on `decideFrame`, pacing off the time left so it decelerates onto `decideAt` and lands on the real verdict. Yields.
function NpcBillboard.PlayDecide(state, decideFrame: GuiObject, interested: boolean, decideAt: number)
	local title = decideFrame.Title
	local stroke, scale = title.UIStroke, title.UIScale

	decideFrame.Visible = true
	scale.Scale = PULSE_START_INITIAL -- start small so the first flip springs it up

	local duration = decideAt - workspace:GetServerTimeNow()
	local firstFlip = true
	local showInterested = false

	while state.running do
		local timeLeft = decideAt - workspace:GetServerTimeNow()
		if timeLeft <= 0 then
			break
		end

		showInterested = not showInterested
		applyVerdict(title, stroke, if showInterested then INTERESTED else NOT_INTERESTED)
		pulseScale(scale, if firstFlip then PULSE_START_INITIAL else PULSE_START_SWAP)
		firstFlip = false

		-- The gap grows from INITIAL to MAX off the time left, and never overshoots the landing
		local elapsedFraction = if duration > 0 then math.clamp(1 - timeLeft / duration, 0, 1) else 1
		local waitTime = SellNpc.DECIDE_INITIAL_WAIT
			+ (SellNpc.DECIDE_MAX_WAIT - SellNpc.DECIDE_INITIAL_WAIT) * elapsedFraction
		task.wait(math.min(waitTime, timeLeft))
	end

	if not state.running then
		return
	end

	-- Land on the real verdict with a final pulse
	applyVerdict(title, stroke, if interested then INTERESTED else NOT_INTERESTED)
	pulseScale(scale, PULSE_START_SWAP)
end

return NpcBillboard
