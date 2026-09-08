-- What Roblox says this account may be sold. Per-player and off a web call, so GetPolicyInfo yields on the first read -- callers gating a button must be spawned. The fallback is the restrictive answer, since failing open would be a compliance problem.

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

-- Used only if every fetch fails. Every field is restrictive, so a lost lookup closes its gates
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

-- Fetches the player's policy info, retrying, then caches it and announces it to anything waiting.
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

-- The player's policy dictionary. Yields until the first fetch lands, then returns immediately.
function PolicyController:GetPolicyInfo(): PolicyInfo
	if self._info then
		return self._info
	end

	return self.Loaded:Wait()
end

-- Whether this player may be sold paid random items -- crates here. Yields, so call it spawned.
function PolicyController:CanPurchaseRandomItems(): boolean
	return not self:GetPolicyInfo().ArePaidRandomItemsRestricted
end

function PolicyController:OnStart()
	-- Spawned so a slow web call doesn't hold up the rest of the Start phase
	task.spawn(PolicyController._fetch, self)
end

return PolicyController
