-- Step 7: buy a wooden stick. Two taps, so the spotlight walks from the row to the buy button and back if either is undone.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Sticks = require(ReplicatedStorage.Shared.Config.Sticks)

local StickShopController = require(script.Parent.Parent.Parent.Parent.StickShopController)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- The one stick pointed at: cheapest, and stocked every window, so it can't be unaffordable or sold out
local TUTORIAL_STICK_ID = "WoodenStick"

local SPOTLIGHT_PADDING = 10
local BEAM_HIDE_DISTANCE = 14

return function(self)
	-- Named in the stick's own label colour, which is what its shop row is written in
	local stick = Sticks.GetStickFromId(TUTORIAL_STICK_ID)
	local stickName = self:Emphasize(`{stick.Name} Stick`, stick.TextColor)

	local holder = PlayerGui:WaitForChild("StickShopUI").Holder
	local scrollingFrame = holder.Container:WaitForChild("ScrollingFrame")
	local row = scrollingFrame:WaitForChild(TUTORIAL_STICK_ID)
	local buyButton = scrollingFrame:WaitForChild("ButtonChoices"):WaitForChild("CurrencyPurchase")

	local zone = workspace:WaitForChild("Core"):WaitForChild("Zones"):WaitForChild("StickShop")
	local stall = workspace:WaitForChild("Stalls"):WaitForChild("StickStall")

	-- Only this stick opens, or another row would slide the buy button out from under the light
	StickShopController:SetOnlySelectableStick(TUTORIAL_STICK_ID)

	local function isSelected(): boolean
		return StickShopController:GetSelectedStickId() == TUTORIAL_STICK_ID
	end

	-- Put back whenever the shop is shut, since inside it the spotlight is the cue and a beam is in the way
	local highlight = self:CreateBreathingHighlight(function()
		return if holder.Visible then nil else stall
	end)
	local beam = self:CreateBeam(function()
		return if holder.Visible then nil else zone
	end, BEAM_HIDE_DISTANCE)

	local spotlight = self:GetSpotlight()
	-- Rectangle, so the cutout takes width and height -- other shapes square off the larger
	spotlight:SetShape("Rectangle")

	-- Re-aimed only on a real change: FocusUI re-locks ancestors and rebinds its loop each call
	local currentTarget
	local function syncSpotlight()
		local target = if not holder.Visible
			then nil
			elseif isSelected() then buyButton
			else row.Button

		if target == currentTarget then
			return
		end
		currentTarget = target

		if target then
			spotlight:FocusUI(target, SPOTLIGHT_PADDING)
			spotlight:Show()
		else
			spotlight:Hide()
		end
	end

	syncSpotlight()
	local spotlightConnection = RunService.Heartbeat:Connect(syncSpotlight)

	-- Logged on the right row, so the funnel separates never picking from picking and never buying
	task.spawn(function()
		while not isSelected() do
			task.wait()
		end

		self:LogStep("SelectStick")
	end)

	-- The server's own answer, being the one thing that fires exactly when the buy went through
	local bought = false
	local purchaseConnection = StickShopController.OnStickPurchased:Connect(function(stickId: string)
		if stickId == TUTORIAL_STICK_ID then
			bought = true
		end
	end)

	self:AwaitGoal({
		{
			Description = `Go to the {self:Emphasize("Stick Shop")}`,
			Check = function()
				return holder.Visible
			end,
		},
		{
			Description = `Click the {stickName}`,
			Check = isSelected,
		},
	}, {
		Description = `Buy the {stickName}`,
		Wait = function()
			repeat
				task.wait()
			until bought
		end,
	})

	spotlightConnection:Disconnect()
	purchaseConnection:Disconnect()
	spotlight:Hide()
	beam.Destroy()
	highlight.Destroy()
	StickShopController:SetOnlySelectableStick(nil)

	-- Shut for them, since on a phone it covers the top bar the next beat points at. After the cues come down, or they'd flash back onto the stall
	StickShopController:Close()

	self:LogStep("BuyStick")

	self.SequenceFinish:Fire()
end
