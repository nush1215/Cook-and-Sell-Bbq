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

--[[
    Class for a single plot on some base.

    The server decides which plots wear an unlock sign -- one goes up only while the plot is actually
    buyable, which is what walks a player outwards from the middle of their base. What this class does
    is the half the server can't: mount that sign's UI so its buttons take clicks, and take the sign
    down entirely on a base the local player doesn't own.

    That split is why the models are hidden client-side rather than server-side. The server has one
    world to replicate and can't show a board to one player and not another, but a plot sign is only
    ever its owner's business -- left standing on someone else's base it'd be a blank board in the way.

    Clearing is the other half, and it's only the animation. Which plots are clear is the server's --
    it pulls a bought plot's overgrowth out of the world entirely (see Base:ApplyPlots), so cleared
    ground has nothing standing on it rather than something hidden. What it can't do is animate a folder
    it has already taken away, so it holds the overgrowth for the length of the burn and every client
    plays that burn on the real trees. Nothing here is put back afterwards: the parts these writes land
    on are replicas the server destroys a moment later, and the folder parented back for the next owner
    of this base arrives fresh off the place file.
]]

-- The one ScreenGui the plot signs live under. They sit in PlayerGui adorned back onto the sign's
-- board rather than in the world, because that's what makes their buttons clickable.
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
	--
	local cleaner = Trove.new()

	local self = setmetatable({
		--
		_model = model,
		_plotId = model.Name,
		_baseId = baseId,

		-- The mounted sign UI, if this plot's sign is up and it's ours: { UI, Cleaner }.
		_signUI = nil,

		-- The authored look of every sign instance we've hidden, so a sign on a base we're handed goes
		-- back up exactly as the place file had it. Keyed loosely on purpose: the restore just writes
		-- each pair back, so it never has to work out what a given instance was.
		_signLooks = {}, -- [Instance] = { [property] = value }

		-- [id] = true for every Robux price this plot has already gone and asked for, so a lookup that
		-- came back empty isn't tried again every time the sign is repainted.
		_requestedPrices = {},

		--
		_cleaner = cleaner,
	}, Plot)

	-- The server parents the sign in and out as the plot becomes buyable, so follow the model rather
	-- than any state of our own. Descendants and not just children, because a sign replicates
	-- model-first -- the board its UI adorns arrives after the model does, and that arrival is what
	-- makes the sign mountable.
	cleaner:Connect(model.ChildAdded, function()
		self:RefreshSign()
	end)
	cleaner:Connect(model.DescendantAdded, function(descendant: Instance)
		local sign = model:FindFirstChild(Plots.SIGN_NAME)

		-- Narrowed to the sign, unlike the two either side of it. The overgrowth is parented in and out
		-- as a whole folder (see Base:ApplyPlots), which lands here once per part in it -- and only the
		-- sign's own parts can change whether there's a board to mount.
		if sign and descendant:IsDescendantOf(sign) then
			self:RefreshSign()
		end
	end)
	cleaner:Connect(model.ChildRemoved, function()
		self:RefreshSign()
	end)

	-- No first paint here. There's nothing to render on a plot that isn't its sign: a plot bought before
	-- this client joined arrives with no overgrowth at all. RefreshSign is the one that has to run, and
	-- it reads player data -- which yields until the replica lands, and these are all built inside the
	-- controller's OnStart where a yield would stall every controller loaded after it. The controller
	-- does that first paint off its own thread instead.

	return self
end

-- Burns the overgrowth back: every visible part of it goes neon, holds, then fades out. Driven by the
-- server's one-shot effect, since only the server knows a plot was *just* bought -- so this is what
-- everyone nearby actually watches happen.
--
-- Nothing is remembered and nothing is put back. The server pulls the whole overgrowth folder into the
-- base's storage as this lands, which takes these parts off every client outright, so every write below
-- goes with the instance it was made on -- and what the next owner of this base is given is the folder
-- parented back, fresh off the place file.
function Plot:PlayClearBurn()
	local misc = self._model:FindFirstChild(Plots.MISC_FOLDER_NAME)

	-- The overgrowth is already gone: the effect and the pull that follows it are both the server's, and
	-- on a slow enough connection they can land in that order.
	if not misc then
		return
	end

	local tweenInfo =
		TweenInfo.new(Plots.CLEAR_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, Plots.CLEAR_HOLD)

	for _, part in misc:GetDescendants() do
		if not part:IsA("BasePart") then
			continue
		end

		-- The plot is walkable from the moment it's bought rather than once the burn is over. Locally
		-- only, which is all it has to be: a character is simulated on its owner's client, and the parts
		-- themselves leave the world a moment later anyway.
		part.CanCollide = false

		-- Authored invisible on purpose (a hitbox, a mount). Lighting it up would put something in the
		-- world that was never meant to be seen, so it's left alone.
		if part.Transparency >= 1 then
			continue
		end

		part.Material = Enum.Material.Neon
		part.Color = Plots.CLEAR_COLOR

		TweenService:Create(part, tweenInfo, { Transparency = 1 }):Play()
	end
end

-- Mounts this plot's sign UI on its board, or takes it down, following the sign model the server
-- parents in and pulls. Returns the mounted UI, or nil when the sign isn't up.
--
-- `buttons` maps a child of the template's Holder.Buttons onto what pressing it does, bound once as
-- the UI goes up. Anything under Buttons the map doesn't name is hidden, which is what lets the Robux
-- button disappear on its own if a plot ever has no dev product behind it.
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

	-- The sign replicates ahead of its own parts, so on a join the board it adorns can still be on the
	-- way. The DescendantAdded connection in the constructor brings us back here once it lands.
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

-- Takes this plot's sign model down on a base the local player doesn't own, and puts it back on the
-- one they do.
function Plot:_setSignShown(shown: boolean)
	if shown then
		for instance, authored in self._signLooks do
			local target = instance :: any
			for property, value in authored do
				target[property] = value
			end
		end

		-- Nothing's hidden any more, so the next hide starts from the world's own values again. This is
		-- also what keeps a sign the server has since pulled from piling up in here.
		table.clear(self._signLooks)

		return
	end

	local sign = self._model:FindFirstChild(Plots.SIGN_NAME)
	if not sign then
		return
	end

	-- A sign replicates model-first, so this runs again for each part as it lands; anything already
	-- hidden is skipped rather than re-read, or the second pass would capture what the first one wrote.
	for _, descendant in sign:GetDescendants() do
		if self._signLooks[descendant] then
			continue
		end

		if descendant:IsA("BasePart") then
			-- The collision goes with the fade: an invisible board is still a wall to walk into.
			self._signLooks[descendant] = {
				Transparency = descendant.Transparency,
				CanCollide = descendant.CanCollide,
			}
			descendant.Transparency = 1
			descendant.CanCollide = false
		elseif descendant:IsA("Decal") then
			-- Texture inherits from Decal, so the one check covers both.
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
			-- Read rather than assumed on, so a piece authored off doesn't light up when the sign returns.
			self._signLooks[descendant] = { Enabled = descendant.Enabled }
			descendant.Enabled = false
		end
	end
end

-- A Robux price as it goes on a buy button, reading "-" until the MarketplaceService lookup lands (or
-- if it failed), matching how ShopController:GetPrice reports one it couldn't get. The lookup yields,
-- so it goes on its own thread and brings the sign back through here once it's cached. Each id is
-- asked for once rather than retried -- a failed lookup would otherwise spin, since nothing caches
-- the failure -- and it's tracked per id because the sign moves through a new product each purchase.
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

-- Puts this plot's sign up on the local player's own base and takes it down otherwise, and paints it
-- with what their next plot costs. Public because buying any plot changes the price on every other
-- sign, so the controller drives the lot of them off one data change.
function Plot:RefreshSign()
	local owned = self._baseId == LocalPlayer:GetAttribute("BaseId")

	self:_setSignShown(owned)

	-- Off our base, drop whatever's mounted -- the model has just gone with the call above, so there's
	-- no board left for a UI to adorn.
	if not owned then
		if self._signUI then
			self._cleaner:Remove(self._signUI.Cleaner)
			self._signUI = nil
		end

		return
	end

	local unlockedCount = Plots.GetUnlockedCount(PlayerDataController:GetKey("Plots") or {})
	local cost = Plots.GetCost(unlockedCount)

	-- Nothing left to sell. The server pulls the sign in the same breath, so this is only the frame
	-- in between.
	if not cost then
		return
	end

	local ui = self:_syncSignUI({
		CurrencyPurchase = function()
			PlotController = PlotController or require(script.Parent)
			PlotController:RequestPurchase(self._plotId)
		end,
		-- Unlike most Robux buttons this one doesn't prompt through ShopController: the server has to
		-- know which plot is being bought, and the product it prompts is priced by how many the player
		-- owns rather than by which one they picked, so its receipt can't say.
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
	-- The sign outlives this class, so put it back the way we found it rather than leaving a base's
	-- board invisible for whoever is handed it next. The overgrowth needs no such thing: the parts a
	-- burn wrote on are ones the server has already taken out of the world.
	self:_setSignShown(true)

	self._cleaner:Destroy()
end

return Plot
