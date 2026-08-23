-- Step 5: Buy a wooden stick. Two taps -- the stick's row, then the buy button that expands underneath
-- it -- so the spotlight walks from one to the other, and back again if the row is collapsed or the
-- player wanders out of the zone and the shop closes behind them.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Sticks = require(ReplicatedStorage.Shared.Config.Sticks)

local StickShopController = require(script.Parent.Parent.Parent.StickShopController)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

-- The one stick the tutorial points at. Cheapest in the shop and stocked every window without fail
-- (RestockChance 100), so it can neither be unaffordable off the starting balance nor sold out.
local TUTORIAL_STICK_ID = "WoodenStick"

local SPOTLIGHT_PADDING = 10
local BEAM_HIDE_DISTANCE = 14

return function(self)
	-- Named in the stick's own label colour, which is what its shop row is written in.
	local stick = Sticks.GetStickFromId(TUTORIAL_STICK_ID)
	local stickName = self:Emphasize(`{stick.Name} Stick`, stick.TextColor)

	local holder = PlayerGui:WaitForChild("StickShopUI").Holder
	local scrollingFrame = holder.Container:WaitForChild("ScrollingFrame")
	local row = scrollingFrame:WaitForChild(TUTORIAL_STICK_ID)
	local buyButton = scrollingFrame:WaitForChild("ButtonChoices"):WaitForChild("CurrencyPurchase")

	local zone = workspace:WaitForChild("Core"):WaitForChild("Zones"):WaitForChild("StickShop")
	local stall = workspace:WaitForChild("Stalls"):WaitForChild("StickStall")

	-- Only the one stick this beat is pointing at will open. The spotlight walks from the row to the buy
	-- button that expands under it, and any other row opening would slide that button out from under the
	-- light and sell them something the beat isn't waiting on.
	StickShopController:SetOnlySelectableStick(TUTORIAL_STICK_ID)

	local function isSelected(): boolean
		return StickShopController:GetSelectedStickId() == TUTORIAL_STICK_ID
	end

	-- Step 4's cues came down when the shop opened, and this beat had none of its own -- so a player who
	-- wandered out was told to go back to the Stick Shop with nothing left pointing at it. Both are put
	-- back whenever the shop is shut, and taken down again the moment it opens: inside it the spotlight
	-- below is the cue, and a beam through the UI would only be in the way of it.
	local highlight = self:CreateBreathingHighlight(function()
		return if holder.Visible then nil else stall
	end)
	local beam = self:CreateBeam(function()
		return if holder.Visible then nil else zone
	end, BEAM_HIDE_DISTANCE)

	local spotlight = self:GetSpotlight()
	-- Rectangle, so the cutout takes the button's width and height. Every other shape squares off the
	-- larger of the two, which over a wide shop row is a hole several times taller than the row.
	spotlight:SetShape("Rectangle")

	-- Re-aimed only when the target actually changes: FocusUI re-locks the ancestor scroll frames and
	-- rebinds its own follow loop each call, so driving it every frame would churn through both.
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

	-- Logged the first time they land on the right row, so the funnel separates "never picked anything"
	-- from "picked it and never bought it".
	task.spawn(function()
		while not isSelected() do
			task.wait()
		end

		self:LogStep("SelectStick")
	end)

	-- The server's own answer to the purchase, rather than watching for the stick to turn up in their
	-- data: it's the one thing that fires exactly when the buy went through.
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

	self:LogStep("BuyStick")

	self.SequenceFinish:Fire()
end
