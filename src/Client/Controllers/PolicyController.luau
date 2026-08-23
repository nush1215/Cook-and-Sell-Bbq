--[[
    What Roblox says this particular account is allowed to be sold.

    Policy is per player and comes off a web call, so it can't be read synchronously and can't be
    cached across players. Everything here funnels through GetPolicyInfo, which yields until the
    fetch lands and is instant afterwards -- so a caller gating a button on it has to be spawned
    rather than run inline on the loader thread.

    The one gate the game needs today is paid random items: a crate bought for Robux is exactly the
    thing ArePaidRandomItemsRestricted covers, so the shop's crate cards are hidden for an account
    that can't be sold one. A gate that fails open would be a compliance problem rather than a bug,
    which is why the fallback below is the restrictive answer and not the permissive one.
]]

-- Services
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Packages
local Packages = ReplicatedStorage.Packages
local Signal = require(Packages.Signal)

-- Local Player
local LocalPlayer = Players.LocalPlayer

-- The policy dictionary returned by PolicyService:GetPolicyInfoForPlayerAsync.
export type PolicyInfo = {
	AreAdsAllowed: boolean,
	ArePaidRandomItemsRestricted: boolean,
	IsContentSharingAllowed: boolean,
	IsEligibleToPurchaseCommerceProduct: boolean,
	IsEligibleToPurchaseSubscription: boolean,
	IsPaidItemTradingAllowed: boolean,
	IsPhotoToAvatarAllowed: boolean,
	IsSubjectToChinaPolicies: boolean,
	AllowedExternalLinkReferences: { string },
}

-- How many times to retry the (web-backed) policy fetch before giving up.
local MAX_ATTEMPTS = 3
local RETRY_DELAY = 2

-- Used only if every fetch attempt fails. Every field is the restrictive answer, so a lookup that
-- never lands closes the gates it feeds rather than opening them.
local DEFAULTS: PolicyInfo = {
	AreAdsAllowed = false,
	ArePaidRandomItemsRestricted = true,
	IsContentSharingAllowed = false,
	IsEligibleToPurchaseCommerceProduct = false,
	IsEligibleToPurchaseSubscription = false,
	IsPaidItemTradingAllowed = false,
	IsPhotoToAvatarAllowed = false,
	IsSubjectToChinaPolicies = false,
	AllowedExternalLinkReferences = {},
}

--
local PolicyController = {
	-- Fires once with the policy dictionary when it becomes available.
	Loaded = Signal.new(),

	_info = nil :: PolicyInfo?, -- cached dictionary; nil until the first fetch resolves or gives up
}

-- Fetches the local player's policy info, retrying a slow or failed web call, then caches it and
-- announces it to anything already waiting.
function PolicyController:_fetch()
	local info: PolicyInfo?

	for attempt = 1, MAX_ATTEMPTS do
		local success, result = pcall(function()
			return PolicyService:GetPolicyInfoForPlayerAsync(LocalPlayer)
		end)

		if success and result then
			info = result
			break
		end

		warn(`Policy fetch attempt {attempt}/{MAX_ATTEMPTS} failed: {result}`)

		if attempt < MAX_ATTEMPTS then
			task.wait(RETRY_DELAY)
		end
	end

	if not info then
		warn("Policy fetch gave up after every retry, falling back to the restrictive defaults")
		info = DEFAULTS
	end

	self._info = info
	self.Loaded:Fire(info)
end

-- The player's policy dictionary. Yields until the fetch has landed the first time, and returns
-- immediately after that.
function PolicyController:GetPolicyInfo(): PolicyInfo
	if self._info then
		return self._info
	end

	return self.Loaded:Wait()
end

-- Whether this player may be sold paid random items -- crates, in this game. Yields with
-- GetPolicyInfo, so call it from a spawned thread.
function PolicyController:CanPurchaseRandomItems(): boolean
	return not self:GetPolicyInfo().ArePaidRandomItemsRestricted
end

function PolicyController:OnStart()
	-- Spawned so a slow web call doesn't hold up the rest of the Start phase.
	task.spawn(PolicyController._fetch, self)
end

return PolicyController
