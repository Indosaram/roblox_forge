--!strict
local E = require("./Entitlements")
return {
	["receipt redelivery and conflict preserve durable ownership"] = function()
		local fresh = E.new()
		local staged = assert(E.grant(fresh, "offline", "gold", "gold-trim"))
		assert(not E.owns(fresh, "gold-trim"), "uncommitted grant escaped")
		local durable = assert(E.grant(staged, "offline", "gold", "gold-trim"))
		assert(E.owns(durable, "gold-trim") and durable.receipts.offline == "gold", "redelivery lost grant")
		local count = 0
		for _ in durable.receipts do
			count += 1
		end
		assert(count == 1, "receipt duplicated")
		local conflict, reason = E.grant(durable, "offline", "other", "other-skin")
		assert(not conflict and reason == "RECEIPT_CONFLICT" and not durable.skins["other-skin"], "conflict mutated")
	end,
	["resync replaces pass ownership and subscription access expires"] = function()
		local listings = {
			{ key = "one", grant = { kind = "storageSlots", amount = 10 } },
			{ key = "two", grant = { kind = "storageSlots", amount = 10 } },
		}
		local state = E.new()
		assert(E.bonus(state, listings) == 0, "base bonus")
		state = E.sync(state, { one = true }, false, "monthly", 5)
		assert(E.bonus(state, listings) == 10, "first pass")
		state = E.sync(state, { one = true, two = true }, false, "monthly", 5)
		assert(E.bonus(state, listings) == 20, "second pass")
		state = E.sync(state, state.passes, true, "monthly", 5)
		assert(E.bonus(state, listings) == 25 and E.owns(state, "monthly"), "subscription active")
		state = E.sync(state, state.passes, false, "monthly", 5)
		assert(E.bonus(state, listings) == 20 and not E.owns(state, "monthly"), "expired entitlement retained")
		state = E.sync(state, {}, false, "monthly", 5)
		assert(E.bonus(state, listings) == 0, "revoked pass retained")
	end,
}
