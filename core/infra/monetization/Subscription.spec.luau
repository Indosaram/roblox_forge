--!strict
-- Specs for Subscription: PolicyService gate (QA-BM-04) and cancel keeps
-- storage read-only without item loss.

local Subscription = require("./Subscription")

local function newPrompt()
	local calls = { count = 0 }
	local port: Subscription.PromptPort = {
		prompt = function(_player: any, _id: string)
			calls.count += 1
		end,
	}
	return port, calls
end

local function policyReturning(info: any): Subscription.PolicyPort
	return {
		getPolicyInfo = function(_player: any): any
			return info
		end,
	}
end

return {
	["an ineligible account is never prompted"] = function()
		local cases: { { label: string, policy: Subscription.PolicyPort, result: string } } = {
			{
				label = "false",
				policy = policyReturning({ IsEligibleToPurchaseSubscription = false }),
				result = "ineligible",
			},
			{ label = "missing", policy = policyReturning({}), result = "ineligible" },
			{
				label = "truthy non-boolean",
				policy = policyReturning({ IsEligibleToPurchaseSubscription = "true" }),
				result = "ineligible",
			},
			{ label = "non-table", policy = policyReturning(nil), result = "policyError" },
			{
				label = "lookup error",
				policy = {
					getPolicyInfo = function(_player: any): any
						error("PolicyService unavailable")
					end,
				},
				result = "policyError",
			},
		}
		for _, case in cases do
			local prompt, calls = newPrompt()
			local result = Subscription.promptIfEligible(case.policy, prompt, {}, "sub-monthly")
			assert(result == case.result, case.label .. ": result " .. tostring(result))
			assert(calls.count == 0, case.label .. ": prompt count must be 0, got " .. calls.count)
		end
	end,

	["an eligible account is prompted exactly once"] = function()
		local prompt, calls = newPrompt()
		local policy = policyReturning({ IsEligibleToPurchaseSubscription = true })
		assert(Subscription.promptIfEligible(policy, prompt, {}, "sub-monthly") == "prompted", "prompted")
		assert(calls.count == 1, "prompt count 1, got " .. calls.count)
	end,

	["cancel makes the expansion read-only without removing items"] = function()
		local active = Subscription.storageAccess(25, 20, 10, true)
		assert(active.capacity == 30 and active.canDeposit and not active.readOnly, "active subscription is writable")

		local cancelled = Subscription.storageAccess(25, 20, 10, false)
		assert(cancelled.stored == 25, "no item loss on cancel")
		assert(cancelled.readOnly and not cancelled.canDeposit, "overflow blocks deposits")
		assert(cancelled.canWithdraw, "overflow stays withdrawable")

		local drained = Subscription.storageAccess(19, 20, 10, false)
		assert(not drained.readOnly and drained.canDeposit, "within base capacity is writable again")
	end,
}
