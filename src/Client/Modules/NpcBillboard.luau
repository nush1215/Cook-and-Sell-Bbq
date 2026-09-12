-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
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

-- Controllers
local InputController = require(script.Parent.Parent.Controllers.InputController)

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

-- A pad answers the customer being looked at: right accepts and left declines, the way the buttons sit
local OFFER_ANSWER_ACTION = "NpcOfferAnswer"
local OFFER_ACCEPT_KEY = Enum.KeyCode.DPadRight
local OFFER_DECLINE_KEY = Enum.KeyCode.DPadLeft

-- The glyph floats above its button, square against the button's height
local OFFER_GLYPH_SIZE = UDim2.fromScale(0.6, 0.6)
local OFFER_GLYPH_POSITION = UDim2.fromScale(0.5, 0)
local OFFER_GLYPH_ANCHOR = Vector2.new(0.5, 1)

-- Radians another customer must beat the current one by, so two heads in a queue don't trade the glyphs every frame
local OFFER_TARGET_HYSTERESIS = math.rad(5)

-- Mounts an NPC's billboards and speaks its lines. Shared by every customer, since the mounting is what makes the buttons clickable and getting it wrong is invisible until a touch tap misses. Also how a pad answers an offer, for the same reason.

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

-- The offers a pad can answer right now, by customer, and which of them the camera is on.
local offers = {} -- [npc] = { Head, Row, AcceptButton, DeclineButton, Answer }
local offerTarget: Model? = nil
local offerTargetConnection: RBXScriptConnection? = nil
local acceptGlyph: ImageLabel? = nil
local declineGlyph: ImageLabel? = nil

-- One D-pad glyph, built on first use. Never Active, so the click underneath still lands on the button.
local function createOfferGlyph(): ImageLabel
	local glyph = Instance.new("ImageLabel")
	glyph.Name = "GamepadKey"
	glyph.BackgroundTransparency = 1
	glyph.ScaleType = Enum.ScaleType.Fit
	glyph.Size = OFFER_GLYPH_SIZE
	glyph.SizeConstraint = Enum.SizeConstraint.RelativeYY
	glyph.Position = OFFER_GLYPH_POSITION
	glyph.AnchorPoint = OFFER_GLYPH_ANCHOR
	return glyph
end

-- Moves the glyphs onto `npc`'s buttons, or off everything for nil.
local function setOfferTarget(npc: Model?)
	if npc == offerTarget then
		return
	end
	offerTarget = npc

	acceptGlyph = acceptGlyph or createOfferGlyph()
	declineGlyph = declineGlyph or createOfferGlyph()

	-- Re-read each time, since the glyph set follows whichever pad is in hand
	acceptGlyph.Image = UserInputService:GetImageForKeyCode(OFFER_ACCEPT_KEY)
	declineGlyph.Image = UserInputService:GetImageForKeyCode(OFFER_DECLINE_KEY)

	local entry = npc and offers[npc]
	acceptGlyph.Parent = entry and entry.AcceptButton
	declineGlyph.Parent = entry and entry.DeclineButton
end

-- Targets the customer nearest the middle of the screen, in front of the camera; an exact tie goes to the nearer one.
local function updateOfferTarget()
	local cameraCFrame = workspace.CurrentCamera.CFrame
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	local best: Model? = nil
	local bestAngle = math.huge
	local bestDistance = math.huge

	for npc, entry in offers do
		-- The row is hidden while an employee seller has this customer, and then it isn't the player's to answer
		if not entry.Row.Visible then
			continue
		end

		local toHead = entry.Head.Position - cameraCFrame.Position
		local dot = cameraCFrame.LookVector:Dot(toHead.Unit)
		if dot <= 0 then
			continue
		end

		-- The current target holds on unless beaten by the hysteresis, so a queue doesn't strobe
		local angle = math.acos(math.min(dot, 1))
		if npc == offerTarget then
			angle -= OFFER_TARGET_HYSTERESIS
		end

		local distance = if root then (entry.Head.Position - root.Position).Magnitude else 0

		if angle < bestAngle or (angle == bestAngle and distance < bestDistance) then
			best, bestAngle, bestDistance = npc, angle, distance
		end
	end

	setOfferTarget(best)
end

-- The D-pad press: answers the targeted customer with whichever button the key stands for.
local function onOfferAnswer(_, inputState: Enum.UserInputState, input: InputObject)
	local entry = offerTarget and offers[offerTarget]
	if inputState ~= Enum.UserInputState.Begin or not entry then
		return Enum.ContextActionResult.Pass
	end

	local accepted = input.KeyCode == OFFER_ACCEPT_KEY
	local button = if accepted then entry.AcceptButton else entry.DeclineButton

	-- The tutorial hides Decline on its one offer, and a pad mustn't press what a finger can't
	if not button.Visible then
		return Enum.ContextActionResult.Pass
	end

	entry.Answer(accepted)
	return Enum.ContextActionResult.Sink
end

-- Runs the targeting and the D-pad only while there's an offer up and a pad in hand.
local function refreshOfferTargeting()
	local active = next(offers) ~= nil and InputController:IsGamepad()

	if active and not offerTargetConnection then
		ContextActionService:BindAction(OFFER_ANSWER_ACTION, onOfferAnswer, false, OFFER_ACCEPT_KEY, OFFER_DECLINE_KEY)
		offerTargetConnection = RunService.RenderStepped:Connect(updateOfferTarget)
	elseif not active and offerTargetConnection then
		ContextActionService:UnbindAction(OFFER_ANSWER_ACTION)
		offerTargetConnection:Disconnect()
		offerTargetConnection = nil
		setOfferTarget(nil)
	end
end

InputController.OnPreferredInputChanged:Connect(refreshOfferTargeting)

-- Mounts `templateName`'s billboards on the NPC's head and returns the state a caller drives them through, or nil only if the rig left the world before its head arrived. `billboards` is every BillboardGui the template held, by name.
function NpcBillboard.Attach(npc: Model, templateName: string, dialogueVariant: string?, dialoguePrefix: string)
	-- Held for as long as it takes: under streaming the parts can trail the model by however long the player takes to walk over
	local head = npc:FindFirstChild("Head")
	while not head and npc.Parent do
		task.wait()
		head = npc:FindFirstChild("Head")
	end
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

-- Paints `decideFrame` with a verdict that has already landed and raises it, for a client that reached the customer after its flip was over.
function NpcBillboard.ShowVerdict(decideFrame: GuiObject, interested: boolean)
	local title = decideFrame.Title
	applyVerdict(title, title.UIStroke, if interested then INTERESTED else NOT_INTERESTED)
	decideFrame.Visible = true
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

-- Puts `npc`'s offer on the pad, answered through `answer(accepted)`. Keyed by customer, so a counter-offer re-arming the same buttons replaces its entry.
function NpcBillboard.RegisterOffer(
	npc: Model,
	acceptButton: GuiButton,
	declineButton: GuiButton,
	answer: (boolean) -> ()
)
	offers[npc] = {
		Head = npc.Head,
		Row = acceptButton.Parent,
		AcceptButton = acceptButton,
		DeclineButton = declineButton,
		Answer = answer,
	}

	refreshOfferTargeting()
end

-- Takes `npc`'s offer off the pad. Safe for one never put on, and must run before its billboards go, since the glyphs sit on them.
function NpcBillboard.UnregisterOffer(npc: Model)
	if offerTarget == npc then
		setOfferTarget(nil)
	end

	offers[npc] = nil
	refreshOfferTargeting()
end

return NpcBillboard
