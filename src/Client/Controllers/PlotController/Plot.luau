-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

-- Shared
local Shared = ReplicatedStorage.Shared
local Plots = require(Shared.Config.Plots)
local GuiUtil = require(Shared.GuiUtil)

-- Controllers
local Controllers = script.Parent.Parent
local UIController = require(Controllers.UIController)
local ShopController = require(Controllers.ShopController)
local PlayerDataController = require(Controllers.PlayerDataController)

-- Assets
local UI = ReplicatedStorage.Assets.UI

--
local LocalPlayer = Players.LocalPlayer

-- Required lazily to break the cycle: PlotController requires this class.
local PlotController

-- One plot on a base: its buy sign, and the burn that clears its overgrowth when it's bought.

-- The signs' ScreenGui. In PlayerGui adorned back onto the board, which is what makes buttons clickable.
local function getScreenGui(): ScreenGui
	local playerGui = LocalPlayer.PlayerGui
	local screenGui = playerGui:FindFirstChild("PlotSigns")

	if screenGui == nil then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "PlotSigns"
		screenGui.ResetOnSpawn = false
		screenGui.Parent = playerGui
	end

	return screenGui
end

--
local Plot = {}
Plot.__index = Plot

function Plot.new(model: Model, baseId: string)
	local cleaner = Trove.new()

	local self = setmetatable({
		_model = model,
		_plotId = model.Name,
		_baseId = baseId,

		-- The mounted sign UI, if this plot's sign is up and it's ours
		_signUI = nil,

		-- The authored look of everything we've hidden, so a handed-over base restores exactly as authored
		_signLooks = {}, -- [Instance] = { [property] = value }

		-- [id] = true per price already asked for, so an empty lookup isn't retried on every repaint
		_requestedPrices = {},

		_cleaner = cleaner,
	}, Plot)

	-- Follow the model, and descendants not children -- a sign replicates model-first, board last
	cleaner:Connect(model.ChildAdded, function()
		self:RefreshSign()
	end)
	cleaner:Connect(model.DescendantAdded, function(descendant: Instance)
		local sign = model:FindFirstChild(Plots.SIGN_NAME)

		-- Narrowed to the sign: the overgrowth lands here once per part, and only the sign gates mounting
		if sign and descendant:IsDescendantOf(sign) then
			self:RefreshSign()
		end
	end)
	cleaner:Connect(model.ChildRemoved, function()
		self:RefreshSign()
	end)

	-- No first paint: RefreshSign yields on player data, and these are built inside the controller's OnStart

	return self
end

-- Burns the overgrowth back on the server's one-shot effect. Nothing is remembered -- the server pulls the folder.
function Plot:PlayClearBurn()
	local misc = self._model:FindFirstChild(Plots.MISC_FOLDER_NAME)

	-- The effect and the pull are both the server's, and on a slow link they can land in that order
	if not misc then
		return
	end

	local tweenInfo =
		TweenInfo.new(Plots.CLEAR_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, Plots.CLEAR_HOLD)

	for _, part in misc:GetDescendants() do
		if not part:IsA("BasePart") then
			continue
		end

		-- Walkable from the moment it's bought. Locally is enough -- a character is simulated on its own client
		part.CanCollide = false

		-- Authored invisible on purpose, so lighting it would show something never meant to be seen
		if part.Transparency >= 1 then
			continue
		end

		part.Material = Enum.Material.Neon
		part.Color = Plots.CLEAR_COLOR

		TweenService:Create(part, tweenInfo, { Transparency = 1 }):Play()
	end
end

-- Mounts or drops this plot's sign UI. `buttons` maps a Buttons child to its action; unnamed ones are hidden.
function Plot:_syncSignUI(buttons: { [string]: () -> () }): Instance?
	local sign = self._model:FindFirstChild(Plots.SIGN_NAME)

	if not sign then
		if self._signUI then
			self._cleaner:Remove(self._signUI.Cleaner)
			self._signUI = nil
		end

		return nil
	end

	if self._signUI then
		return self._signUI.UI
	end

	-- The sign replicates ahead of its parts; the constructor's DescendantAdded brings us back
	local board = sign:FindFirstChild("Board")
	if not board then
		return nil
	end

	local signCleaner = self._cleaner:Construct(Trove)

	local ui = UI[Plots.SIGN_UI]:Clone()
	ui.Adornee = board
	ui.Active = true
	ui.Parent = getScreenGui()
	signCleaner:Add(ui)

	for _, button in ui.Holder.Buttons:GetChildren() do
		if not button:IsA("GuiButton") then
			continue
		end

		local onClick = buttons[button.Name]
		if onClick then
			local binding = UIController:BindButtonClick(button, onClick, true)
			signCleaner:Add(binding.Disconnect)
		else
			button.Visible = false
		end
	end

	self._signUI = { UI = ui, Cleaner = signCleaner }

	return ui
end

-- Hides this plot's sign on a base the local player doesn't own, and restores it on the one they do.
function Plot:_setSignShown(shown: boolean)
	if shown then
		for instance, authored in self._signLooks do
			local target = instance :: any
			for property, value in authored do
				target[property] = value
			end
		end

		-- Cleared so the next hide reads the world's own values, and a pulled sign doesn't pile up here
		table.clear(self._signLooks)

		return
	end

	local sign = self._model:FindFirstChild(Plots.SIGN_NAME)
	if not sign then
		return
	end

	-- Runs per part as it lands, so anything already hidden is skipped or the second pass captures the first
	for _, descendant in sign:GetDescendants() do
		if self._signLooks[descendant] then
			continue
		end

		if descendant:IsA("BasePart") then
			-- The collision goes with the fade: an invisible board is still a wall to walk into
			self._signLooks[descendant] = {
				Transparency = descendant.Transparency,
				CanCollide = descendant.CanCollide,
			}
			descendant.Transparency = 1
			descendant.CanCollide = false
		elseif descendant:IsA("Decal") then
			-- Texture inherits from Decal, so the one check covers both
			self._signLooks[descendant] = { Transparency = descendant.Transparency }
			descendant.Transparency = 1
		elseif
			descendant:IsA("SurfaceGui")
			or descendant:IsA("BillboardGui")
			or descendant:IsA("ParticleEmitter")
			or descendant:IsA("Beam")
			or descendant:IsA("Trail")
			or descendant:IsA("Light")
		then
			-- Read rather than assumed on, so a piece authored off doesn't light up when the sign returns
			self._signLooks[descendant] = { Enabled = descendant.Enabled }
			descendant.Enabled = false
		end
	end
end

-- A Robux price for a buy button, "-" until the lookup lands. Asked once per id, on its own thread.
function Plot:_robuxPriceText(id: string): string
	local price = ShopController:GetCachedPrice(id)

	if not price and not self._requestedPrices[id] then
		self._requestedPrices[id] = true

		task.spawn(function()
			ShopController:GetPrice(id)
			self:RefreshSign()
		end)
	end

	return `{GuiUtil.ROBUX_ICON}{price or "-"}`
end

-- Raises this plot's sign on the owner's base and paints the next plot's price. Public -- any buy repaints them all.
function Plot:RefreshSign()
	local owned = self._baseId == LocalPlayer:GetAttribute("BaseId")

	self:_setSignShown(owned)

	-- Off our base, drop whatever's mounted -- there's no board left for a UI to adorn
	if not owned then
		if self._signUI then
			self._cleaner:Remove(self._signUI.Cleaner)
			self._signUI = nil
		end

		return
	end

	local unlockedCount = Plots.GetUnlockedCount(PlayerDataController:GetKey("Plots") or {})
	local cost = Plots.GetCost(unlockedCount)

	-- Nothing left to sell; the server pulls the sign in the same breath, so this is only the frame between
	if not cost then
		return
	end

	local ui = self:_syncSignUI({
		CurrencyPurchase = function()
			PlotController = PlotController or require(script.Parent)
			PlotController:RequestPurchase(self._plotId)
		end,
		-- Not through ShopController: the product is priced by how many they own, so its receipt can't name the plot
		RobuxPurchase = function()
			PlotController = PlotController or require(script.Parent)
			PlotController:RequestPlotProduct(self._plotId)
		end,
	})

	if not ui then
		return
	end

	local holder = ui.Holder
	holder.TextLabel.Text = "Unlock Plot"
	holder.Buttons.CurrencyPurchase.Title.Text = `${GuiUtil.ConvertNumberWithSuffix(cost)}`
	holder.Buttons.RobuxPurchase.Title.Text = self:_robuxPriceText(Plots.GetProductStringId(unlockedCount + 1))
end

function Plot:Destroy()
	-- The sign outlives this class, so restore it. The overgrowth needs none -- the server took those parts away
	self:_setSignShown(true)

	self._cleaner:Destroy()
end

return Plot
