-- Step 16: serve the customer. The Decline button is taken off this one offer, leaving Accept as the only thing to press -- a first-time player turning down the payoff has no idea what they've done.
local RunService = game:GetService("RunService")

local PlayerDataController = require(script.Parent.Parent.Parent.Parent.PlayerDataController)
local SellNpcController = require(script.Parent.Parent.Parent.Parent.SellNpcController)
local SkewerStandController = require(script.Parent.Parent.Parent.Parent.SkewerStandController)

-- Pixels of breathing room left around the lit button
local SPOTLIGHT_PADDING = 14

-- Projects the Accept button into the world for FocusWorld. FocusUI can't be used -- the button lives in a BillboardGui, its own coordinate root, riding a walking customer. Nil while there's nothing to project against.
local function buttonFocusPoint(button: GuiObject): (Vector3?, number?)
	local billboard = button:FindFirstAncestorOfClass("BillboardGui")
	local adornee = billboard and billboard.Adornee :: BasePart?
	local camera = workspace.CurrentCamera
	if not adornee or not camera then
		return nil
	end

	local cameraCFrame = camera.CFrame

	-- StudsOffset is on the camera's axes with Z toward it; StudsOffsetWorldSpace is on the world's
	local studsOffset = billboard.StudsOffset
	local anchor = adornee.Position
		+ billboard.StudsOffsetWorldSpace
		+ cameraCFrame.RightVector * studsOffset.X
		+ cameraCFrame.UpVector * studsOffset.Y
		- cameraCFrame.LookVector * studsOffset.Z

	-- Depth along the look vector, so a customer at the screen edge doesn't measure further and get a smaller hole
	local depth = cameraCFrame.LookVector:Dot(anchor - cameraCFrame.Position)
	if depth <= 0 then
		return nil
	end

	local studsPerPixel = (2 * depth * math.tan(math.rad(camera.FieldOfView) / 2)) / camera.ViewportSize.Y

	-- A difference of two AbsolutePositions, so whatever space the billboard measures in cancels out
	local offset = (button.AbsolutePosition + button.AbsoluteSize / 2)
		- (billboard.AbsolutePosition + billboard.AbsoluteSize / 2)

	-- Along the camera's axes, the plane a billboard faces. Y is negated -- screen space counts down
	local position = anchor
		+ cameraCFrame.RightVector * (offset.X * studsPerPixel)
		- cameraCFrame.UpVector * (offset.Y * studsPerPixel)

	local radius = (math.max(button.AbsoluteSize.X, button.AbsoluteSize.Y) / 2 + SPOTLIGHT_PADDING)
		* studsPerPixel

	return position, radius
end

return function(self)
	local spotlight = self:GetSpotlight()
	spotlight:SetShape("Circle")

	-- Every offer frame this beat hid a Decline on, so they all go back however the sale ends
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

	-- FocusWorld is one-shot, so re-aim per frame: the customer walks and the camera turns
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

	-- Step 15 held this out for the sale. The stand is empty now, so this only ends the hold with the sequence
	SkewerStandController:SetTakeLocked(false)

	spotlight:Hide()

	self:LogStep("AcceptOffer")

	self.SequenceFinish:Fire()
end
