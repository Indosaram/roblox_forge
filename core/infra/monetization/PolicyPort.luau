--!strict
-- PolicyPort: engine port for PolicyService, shaped for Subscription.PolicyPort. The
-- "player" handed to getPolicyInfo is the user id; the Roblox adapter resolves the Player.

local PolicyPort = {}

export type Port = { getPolicyInfo: (userId: any) -> any }

--- Roblox adapter over PolicyService:GetPolicyInfoForPlayerAsync (errors propagate; the
--- Subscription gate turns any error into "no prompt").
function PolicyPort.roblox(service: any, players: any): Port
	return {
		getPolicyInfo = function(userId)
			local player = players:GetPlayerByUserId(userId)
			assert(player ~= nil, "PLAYER_NOT_PRESENT")
			return service:GetPolicyInfoForPlayerAsync(player)
		end,
	}
end

--- Lune fake: `eligible[userId]` decides IsEligibleToPurchaseSubscription; `failing` errors.
function PolicyPort.fake(eligible: { [string]: boolean }, failing: { [string]: boolean }?): Port
	return {
		getPolicyInfo = function(userId)
			local key = tostring(userId)
			if failing and failing[key] then
				error("POLICY_LOOKUP_FAILED")
			end
			return { IsEligibleToPurchaseSubscription = eligible[key] == true }
		end,
	}
end

return PolicyPort
