--!strict
-- Subscription: engine-free subscription gating and entitlement rules (plan
-- §8.1/§8.2, ADR-07). The purchase prompt is shown only after PolicyService
-- reports IsEligibleToPurchaseSubscription == true (QA-BM-04); any lookup
-- error, missing field or false value yields no prompt. PolicyService and the
-- prompt are injected so the gate is testable without the engine.
--
-- Cancelling a subscription never deletes items: the subscription storage
-- expansion becomes read-only (withdraw allowed, deposit refused) until the
-- stored count is back within the unsubscribed capacity.

local Subscription = {}

export type PolicyPort = {
	-- Mirrors PolicyService:GetPolicyInfoForPlayerAsync(player); may error.
	getPolicyInfo: (player: any) -> any,
}

export type PromptPort = {
	-- Mirrors MarketplaceService:PromptSubscriptionPurchase(player, subscriptionId).
	prompt: (player: any, subscriptionId: string) -> (),
}

export type PromptResult = "prompted" | "ineligible" | "policyError"

--- Returns true only for a policy table whose IsEligibleToPurchaseSubscription is exactly true.
function Subscription.isEligible(policy: PolicyPort, player: any): (boolean, PromptResult)
	local ok, info = pcall(policy.getPolicyInfo, player)
	if not ok or type(info) ~= "table" then
		return false, "policyError"
	end
	if info.IsEligibleToPurchaseSubscription ~= true then
		return false, "ineligible"
	end
	return true, "prompted"
end

--- Prompts the purchase only for an eligible player; otherwise the prompt is never called.
function Subscription.promptIfEligible(
	policy: PolicyPort,
	prompt: PromptPort,
	player: any,
	subscriptionId: string
): PromptResult
	local eligible, result = Subscription.isEligible(policy, player)
	if not eligible then
		return result
	end
	prompt.prompt(player, subscriptionId)
	return "prompted"
end

export type StorageAccess = {
	capacity: number,
	stored: number,
	canDeposit: boolean,
	canWithdraw: boolean,
	readOnly: boolean,
}

--- Storage access for `stored` items given the base capacity (including any
--- gamepass slots), the subscription's storageSlots and whether it is active.
--- Items are never removed: a cancelled subscription leaves the overflow
--- readable and withdrawable, and only blocks new deposits.
function Subscription.storageAccess(
	stored: number,
	baseCapacity: number,
	subscriptionSlots: number,
	active: boolean
): StorageAccess
	local capacity = baseCapacity + (if active then subscriptionSlots else 0)
	return {
		capacity = capacity,
		stored = stored,
		canDeposit = stored < capacity,
		canWithdraw = stored > 0,
		readOnly = not active and stored > baseCapacity,
	}
end

return Subscription
