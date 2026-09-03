-- Step 12: Serve the customer. Declining is a real part of the game -- it's how a player holds out for
-- a better price -- but not here: the sale is the payoff the whole sequence has been building to, and
-- a first-time player turning it down has no idea what they've just done. So the Decline button is
-- taken off this one offer, leaving Accept as the only thing to press, and the spotlight dims the world
-- down to the customer standing there. The server has already rigged them to arrive quickly and come in
-- interested, so the beat can't stall waiting for one that never makes an offer.
local RunService = game:GetService("RunService")

local HudController = require(script.Parent.Parent.Parent.Parent.HudController)
local PlayerDataController = require(script.Parent.Parent.Parent.Parent.PlayerDataController)
local SellNpcController = require(script.Parent.Parent.Parent.Parent.SellNpcController)
local SkewerStandController = require(script.Parent.Parent.Parent.Parent.SkewerStandController)

-- Pixels of breathing room left around the lit button.
local SPOTLIGHT_PADDING = 14

-- The HUD frame holding the currency total, hidden for the rest of the run.
local CURRENCY_FRAME = "BottomLeft"

-- How long the total stays up once the sale lands. The count springs up to its new value and a floating
-- +$ label rises off it rather than either snapping, so taking the frame away the instant the goal passes
-- would pull the payoff off screen halfway through it.
local CURRENCY_HOLD_DURATION = 2.5

-- Where the Accept button sits in the world, and how wide it is once it gets there, so FocusWorld can be
-- pointed at the button itself rather than at the customer holding it.
--
-- FocusUI is the usual way to light a button and can't be used here. This one lives in a BillboardGui,
-- which is its own coordinate root -- its descendants measure AbsolutePosition against the billboard
-- rather than the screen -- so FocusUI would cut its hole somewhere unrelated. Its offset arguments could
-- correct for that, but the billboard rides a walking customer, and FocusUI captures those offsets once
-- and rebinds its whole follow loop to change them.
--
-- So the button is projected back out into the world and handed to FocusWorld, which already tracks the
-- camera properly. Returns nil while there's nothing to project against.
local function buttonFocusPoint(button: GuiObject): (Vector3?, number?)
	local billboard = button:FindFirstAncestorOfClass("BillboardGui")
	local adornee = billboard and billboard.Adornee :: BasePart?
	local camera = workspace.CurrentCamera
	if not adornee or not camera then
		return nil
	end

	local cameraCFrame = camera.CFrame

	-- StudsOffset is measured against the camera's own orientation, so it goes on along those axes. Its Z
	-- runs toward the camera, which is the opposite of the look vector. StudsOffsetWorldSpace is on the
	-- world axes instead and goes on as-is -- it's what carries the bubble up clear of the head.
	local studsOffset = billboard.StudsOffset
	local anchor = adornee.Position
		+ billboard.StudsOffsetWorldSpace
		+ cameraCFrame.RightVector * studsOffset.X
		+ cameraCFrame.UpVector * studsOffset.Y
		- cameraCFrame.LookVector * studsOffset.Z

	-- Depth along the look vector rather than raw distance to the camera, so a customer off at the edge of
	-- the screen doesn't measure as further away than one dead ahead and get a smaller hole for it.
	local depth = cameraCFrame.LookVector:Dot(anchor - cameraCFrame.Position)
	if depth <= 0 then
		return nil
	end

	local studsPerPixel = (2 * depth * math.tan(math.rad(camera.FieldOfView) / 2)) / camera.ViewportSize.Y

	-- Taken as the difference between two AbsolutePositions rather than off either one alone: whatever
	-- space a billboard's descendants are measured in, both of these are measured in the same one, so the
	-- gap between them is the button's offset from the middle of the bubble either way.
	local offset = (button.AbsolutePosition + button.AbsoluteSize / 2)
		- (billboard.AbsolutePosition + billboard.AbsoluteSize / 2)

	-- Laid along the camera's axes, which is the plane a billboard faces anyway. Y is negated because
	-- screen space counts down from the top and the world counts up.
	local position = anchor
		+ cameraCFrame.RightVector * (offset.X * studsPerPixel)
		- cameraCFrame.UpVector * (offset.Y * studsPerPixel)

	local radius = (math.max(button.AbsoluteSize.X, button.AbsoluteSize.Y) / 2 + SPOTLIGHT_PADDING)
		* studsPerPixel

	return position, radius
end

return function(self)
	-- Dropped just for this beat, out of the run-long claim Start took over the whole HUD. Everything up
	-- to here has been spending -- the stall, the stick, the ingredient -- with the total kept off screen,
	-- so this is the first time the player sees a number for any of it, at the moment it goes up.
	HudController:SetHudFrameHiddenFor(self, CURRENCY_FRAME, false)

	local spotlight = self:GetSpotlight()
	spotlight:SetShape("Circle")

	-- Every offer frame this beat hid a Decline on, so they all go back however the sale ends.
	local hiddenDeclines = {}
	local activeNpc = nil
	local activeButton = nil

	local shownConnection = SellNpcController.OnOfferShown:Connect(function(npc, offerFrame)
		local buttons = offerFrame.Buttons

		buttons.Decline.Visible = false
		hiddenDeclines[buttons.Decline] = true

		activeNpc = npc
		activeButton = buttons.Accept
		spotlight:Show()
	end)

	local endedConnection = SellNpcController.OnOfferEnded:Connect(function()
		activeNpc = nil
		activeButton = nil
		spotlight:Hide()
	end)

	-- FocusWorld is one-shot, so re-aim it every frame: the customer walks, the camera turns, and the
	-- button's size on screen changes with the distance between the two.
	local spotlightConnection = RunService.Heartbeat:Connect(function()
		if not activeButton or not activeButton.Parent then
			return
		end

		local position, radius = buttonFocusPoint(activeButton)
		if position then
			spotlight:FocusWorld(position, radius)
		end
	end)

	local sold = false
	local dataConnection = PlayerDataController:ListenForChange("SalesCompleted", function(newValue, oldValue)
		if newValue > (oldValue or 0) then
			sold = true
		end
	end)

	self:AwaitGoal({
		{
			Description = `Wait for a {self:Emphasize("Customer")}`,
			Check = function()
				return activeNpc ~= nil
			end,
		},
	}, {
		Description = `Click {self:Emphasize("Accept")} to sell it`,
		Wait = function()
			repeat
				task.wait()
			until sold
		end,
	})

	shownConnection:Disconnect()
	endedConnection:Disconnect()
	spotlightConnection:Disconnect()
	if dataConnection then
		dataConnection:Disconnect()
	end

	for decline in hiddenDeclines do
		decline.Visible = true
	end

	-- Step 11 held this from the moment the skewer went out; the sale is what it was holding out for. The
	-- stand is empty by now, so there's nothing for this to put back -- it just means the hold ends with
	-- the sequence rather than outliving it.
	SkewerStandController:SetTakeLocked(false)

	spotlight:Hide()

	-- Put back on a delay rather than by waiting here. Blocking on it held the whole step open while the
	-- count finished climbing, which read as the Accept press not registering: the sale had gone through,
	-- the banner still said to press Accept, and the next beat sat behind the animation. The step ends
	-- now and the total slides away on its own underneath whatever comes next.
	task.delay(CURRENCY_HOLD_DURATION, function()
		HudController:SetHudFrameHiddenFor(self, CURRENCY_FRAME, true)
	end)

	self:LogStep("AcceptOffer")

	self.SequenceFinish:Fire()
end
