--!strict
local Settlement = require("./Settlement")

local function initial(): Settlement.State
	return Settlement.new({ tribeId = "tribe", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 }, "owner")
end

local function request(id: string, x: number?, z: number?, rotation: number?): Settlement.Request
	return {
		id = id,
		x = x or 4,
		z = z or 4,
		rotation = rotation or 0,
		definition = { id = "bench", footprintX = 2, footprintZ = 3, cost = { { item = "wood", quantity = 5 } } },
	}
end

local function reserve(state: Settlement.State, id: string): Settlement.State
	local result, err = Settlement.reserve(state, "owner", state.version, state.membershipRevision, request(id))
	assert(result, err)
	return result
end

return {
	["restore recomputes occupancy and rejects forged costs roles and overlapping placements"] = function()
		local built = assert(Settlement.commit(reserve(initial(), "a"), "owner", 1, "a"))
		local definitions = { bench = request("a").definition }
		local valid = Settlement.fromSave(Settlement.save(built), built.config, definitions)
		assert(valid.structures["tribe:a"].definition.cost[1].quantity == 5, "valid restore")
		local mutations: { (any) -> () } = {
			function(raw)
				raw.structures["tribe:a"].definition.cost[1].quantity = 999
			end,
			function(raw)
				raw.structures["tribe:a"].cells[1].x = 9
			end,
			function(raw)
				raw.structures["tribe:a"].entry.z = 9
			end,
			function(raw)
				raw.structures["tribe:a"].x = 32
			end,
			function(raw)
				raw.roles.owner = "admin"
			end,
			function(raw)
				raw.roles.other = "owner"
			end,
			function(raw)
				raw.version = 0.5
			end,
			function(raw)
				raw.membershipRevision = 3
			end,
			function(raw)
				raw.usedIds.a = nil
			end,
			function(raw)
				raw.structures["tribe:b"] = Settlement.snapshot(built).structures["tribe:a"]
				raw.structures["tribe:b"].id = "tribe:b"
				raw.usedIds.b = true
			end,
		}
		for _, mutate in mutations do
			local raw = Settlement.save(built)
			mutate(raw)
			assert(not pcall(Settlement.fromSave, raw, built.config, definitions), "forged save rejected")
		end
		local empty = assert(Settlement.membership(built, "owner", 2, 0, "leave", "owner", 0))
		assert(
			next(Settlement.fromSave(Settlement.save(empty), empty.config, definitions).roles) == nil,
			"empty owner retained"
		)
	end,
	["all rotations enumerate exact footprint and rotated entry"] = function()
		local expected = { { 5, 6, 4, 3 }, { 2, 5, 5, 4 }, { 3, 2, 4, 5 }, { 6, 3, 3, 4 } }
		for rotation = 0, 3 do
			local state = initial()
			local result, err = Settlement.reserve(state, "owner", 0, 0, request("r", 4, 4, rotation))
			assert(result, err)
			local placement = result.reservations.r
			local values = expected[rotation + 1]
			assert(#placement.cells == 6, "settlement invariant")
			assert(placement.cells[6].x == values[1] and placement.cells[6].z == values[2], "settlement invariant")
			assert(placement.entry.x == values[3] and placement.entry.z == values[4], "settlement invariant")
			assert(state.version == 0 and next(state.reservations) == nil, "settlement invariant")
		end
	end,

	["collision and concurrent stale versions preserve input"] = function()
		local state = reserve(initial(), "a")
		local result, err = Settlement.reserve(state, "owner", 1, 0, request("b"))
		assert(result == nil and err == "COLLISION", "settlement invariant")
		local stale, staleError = Settlement.reserve(state, "owner", 0, 0, request("c", 12, 12))
		assert(stale == nil and staleError == "STALE_VERSION", "settlement invariant")
		assert(state.version == 1 and state.reservations.a ~= nil and state.usedIds.b == nil, "settlement invariant")
		local built = Settlement.commit(state, "owner", 1, "a")
		assert(built, "settlement invariant")
		result, err = Settlement.reserve(built, "owner", 2, 0, request("d"))
		assert(result == nil and err == "COLLISION", "settlement invariant")
		assert(built.structures["tribe:a"].id == "tribe:a", "settlement invariant")
	end,

	["entry cell must stay walkable in either insertion order"] = function()
		local state = reserve(initial(), "a")
		local r = request("b", 4, 3)
		r.definition.footprintX = 1
		r.definition.footprintZ = 1
		local result, err = Settlement.reserve(state, "owner", 1, 0, r)
		assert(result == nil and err == "COLLISION", "settlement invariant")
		local first = Settlement.reserve(initial(), "owner", 0, 0, r)
		assert(first, "settlement invariant")
		result, err = Settlement.reserve(first, "owner", 1, 0, request("a"))
		assert(result == nil and err == "COLLISION", "settlement invariant")
	end,

	["out of bounds entry footprint and invalid rotation refuse unchanged"] = function()
		local state = initial()
		for _, r in { request("a", 31, 31), request("b", 0, 0), request("c", 0, 4, 1) } do
			local result, err = Settlement.reserve(state, "owner", 0, 0, r)
			assert(result == nil and err == "OUT_OF_BOUNDS", "settlement invariant")
		end
		for _, rotation in { -1, 4, 0.5, math.huge, 0 / 0 } do
			local result, err = Settlement.reserve(state, "owner", 0, 0, request("r", 4, 4, rotation))
			assert(result == nil and err == "INVALID_ROTATION", "settlement invariant")
		end
		assert(state.version == 0 and next(state.usedIds) == nil, "settlement invariant")
	end,

	["cancel releases occupied cells but stable IDs never recycle"] = function()
		local state = reserve(initial(), "a")
		local cancelled = Settlement.cancel(state, "owner", 1, "a")
		assert(cancelled and next(cancelled.reservations) == nil, "settlement invariant")
		local result, err = Settlement.cancel(cancelled, "owner", 2, "a")
		assert(result == nil and err == "NOT_RESERVED", "settlement invariant")
		local reused, reusedError = Settlement.reserve(cancelled, "owner", 2, 0, request("a"))
		assert(reused == nil and reusedError == "RESERVATION_ID_USED", "settlement invariant")
		assert(reserve(cancelled, "b").reservations.b ~= nil, "settlement invariant")
	end,

	["revoked member cannot commit accepted reservation or access tribe"] = function()
		local invited = Settlement.membership(initial(), "owner", 0, 0, "invite", "member", 0)
		assert(invited, "settlement invariant")
		local reserved = Settlement.reserve(invited, "member", 1, 1, request("a"))
		assert(reserved, "settlement invariant")
		local revoked = Settlement.membership(reserved, "owner", 2, 1, "revoke", "member", 0)
		assert(revoked, "settlement invariant")
		local result, err = Settlement.commit(revoked, "member", 3, "a")
		assert(result == nil and err == "FORBIDDEN", "settlement invariant")
		assert(revoked.reservations.a ~= nil and next(revoked.structures) == nil, "settlement invariant")
		result, err = Settlement.reserve(revoked, "outsider", 3, 2, request("b"))
		assert(result == nil and err == "FORBIDDEN", "settlement invariant")
		local reinvited =
			Settlement.membership(revoked, "owner", 3, 2, "invite", "member", Settlement.REJOIN_COOLDOWN_SECONDS)
		assert(reinvited, "settlement invariant")
		local stale, staleError = Settlement.commit(reinvited, "member", 4, "a")
		assert(stale == nil and staleError == "STALE_MEMBERSHIP", "settlement invariant")
		assert(Settlement.cancel(reinvited, "owner", 4, "a"), "settlement invariant")
	end,

	["member limit ownership transfer and empty settlement retention"] = function()
		local state = initial()
		for _, id in { "a", "b", "c" } do
			local added =
				Settlement.membership(state, "owner", state.version, state.membershipRevision, "invite", id, 0)
			assert(added, "settlement invariant")
			state = added
		end
		local result, err = Settlement.membership(state, "owner", 3, 3, "invite", "d", 0)
		assert(result == nil and err == "TRIBE_FULL", "settlement invariant")
		local leaving, leaveError = Settlement.membership(state, "owner", 3, 3, "leave", "owner", 0)
		assert(leaving == nil and leaveError == "OWNER_TRANSFER_REQUIRED", "settlement invariant")
		local forbidden, forbiddenError = Settlement.membership(state, "a", 3, 3, "revoke", "b", 0)
		assert(forbidden == nil and forbiddenError == "FORBIDDEN", "settlement invariant")
		local transferred = Settlement.membership(state, "owner", 3, 3, "transferOwner", "a", 0)
		assert(
			transferred and transferred.roles.owner == "member" and transferred.roles.a == "owner",
			"settlement invariant"
		)
		local left = Settlement.membership(transferred, "owner", 4, 4, "leave", "owner", 0)
		assert(left and left.roles.owner == nil, "settlement invariant")
		local reserved = reserve(initial(), "persistent")
		local built = Settlement.commit(reserved, "owner", 1, "persistent")
		assert(built, "settlement invariant")
		local empty = Settlement.membership(built, "owner", 2, 0, "leave", "owner", 0)
		assert(
			empty and next(empty.roles) == nil and empty.structures["tribe:persistent"] ~= nil,
			"settlement invariant"
		)
		forbidden, forbiddenError = Settlement.demolish(empty, "owner", 3, 1, "tribe:persistent")
		assert(forbidden == nil and forbiddenError == "FORBIDDEN", "settlement invariant")
		forbidden, forbiddenError = Settlement.membership(empty, "stranger", 3, 1, "rejoin", "stranger", 0)
		assert(forbidden == nil and forbiddenError == "FORBIDDEN", "settlement invariant")
		local rejoined = Settlement.membership(empty, "owner", 3, 1, "rejoin", "owner", 0)
		assert(rejoined and rejoined.roles.owner == "owner", "settlement invariant")
	end,

	["pinned costs deep isolation and demolition produce one rounded refund candidate"] = function()
		local original = initial()
		local r = request("a")
		local reserved = Settlement.reserve(original, "owner", 0, 0, r)
		assert(reserved, "settlement invariant")
		r.definition.cost[1].quantity = 999
		local built = Settlement.commit(reserved, "owner", 1, "a")
		assert(built and built.structures["tribe:a"].definition.cost[1].quantity == 5, "settlement invariant")
		local duplicate, err = Settlement.commit(built, "owner", 2, "a")
		assert(duplicate == nil and err == "NOT_RESERVED", "settlement invariant")
		local candidate, refusal, refund = Settlement.demolish(built, "owner", 2, 0, "tribe:a")
		assert(candidate and refusal == nil and refund and refund[1].quantity == 2, "settlement invariant")
		assert(built.structures["tribe:a"] ~= nil, "full-storage transaction can discard candidate without loss")
		local repeated, repeatedError = Settlement.demolish(candidate, "owner", 3, 0, "tribe:a")
		assert(repeated == nil and repeatedError == "NOT_BUILT", "settlement invariant")
		local snapshot = Settlement.snapshot(built)
		snapshot.structures["tribe:a"].cells[1].x = 999
		assert(built.structures["tribe:a"].cells[1].x == 4, "settlement invariant")
		assert(reserved.version == 1 and reserved.reservations.a ~= nil, "settlement invariant")
	end,
	["departed member cannot be re-invited until the rejoin cooldown elapses"] = function()
		local cooldown = Settlement.REJOIN_COOLDOWN_SECONDS
		local invited = assert(Settlement.membership(initial(), "owner", 0, 0, "invite", "alt", 100))
		assert(invited.joinedAt.alt == 100, "join stamped with the caller clock")
		local left = assert(Settlement.membership(invited, "alt", 1, 1, "leave", "alt", 200))
		assert(left.departedAt.alt == 200 and left.joinedAt.alt == nil, "departure stamped")
		local early, earlyError = Settlement.membership(left, "owner", 2, 2, "invite", "alt", 200 + cooldown - 1)
		assert(early == nil and earlyError == "REJOIN_COOLDOWN", "rejoin refused inside cooldown")
		local other = assert(Settlement.membership(left, "owner", 2, 2, "invite", "fresh", 201))
		assert(other.roles.fresh == "member", "cooldown is per account, not per slot")
		local kicked = assert(Settlement.membership(other, "owner", 3, 3, "revoke", "fresh", 300))
		local blocked, blockedError = Settlement.membership(kicked, "owner", 4, 4, "invite", "fresh", 301)
		assert(blocked == nil and blockedError == "REJOIN_COOLDOWN", "revoke also starts the cooldown")
		local back = assert(Settlement.membership(left, "owner", 2, 2, "invite", "alt", 200 + cooldown))
		assert(back.roles.alt == "member" and back.departedAt.alt == nil, "rejoin allowed once elapsed")
		assert(back.joinedAt.alt == 200 + cooldown, "membership duration restarts on rejoin")
		local bad, badError = Settlement.membership(left, "owner", 2, 2, "invite", "alt", -1)
		assert(bad == nil and badError == "INVALID_CLOCK", "clock is validated")
		local restored = Settlement.fromSave(Settlement.save(left), left.config, {})
		local again, againError = Settlement.membership(restored, "owner", 2, 2, "invite", "alt", 300)
		assert(again == nil and againError == "REJOIN_COOLDOWN", "cooldown survives save and restore")
		local forged = Settlement.save(left)
		forged.departedAt.owner = 5
		assert(not pcall(Settlement.fromSave, forged, left.config, {}), "current member cannot carry a departure")
		forged = Settlement.save(left)
		forged.joinedAt.alt = 5
		assert(not pcall(Settlement.fromSave, forged, left.config, {}), "departed member cannot carry a join")
	end,
	["siege league eligibility enforces member account age and membership duration floors"] = function()
		local day = 86400
		local floor = Settlement.LEAGUE_POLICY.minMembershipSeconds
		local state =
			Settlement.new({ tribeId = "tribe", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 }, "owner", 0)
		state = assert(Settlement.membership(state, "owner", 0, 0, "invite", "a", day))
		local ages = { owner = 30, a = 30 }
		local ok, failures = Settlement.leagueEligibility(state, day + floor, ages)
		assert(ok and #failures == 0, "veteran camp eligible")
		ok, failures = Settlement.leagueEligibility(state, day + floor - 1, ages)
		assert(not ok and #failures == 1, "one member too recent")
		assert(failures[1].actorId == "a" and failures[1].reason == "MEMBERSHIP_TOO_SHORT", "names the member")
		ok, failures = Settlement.leagueEligibility(state, day + floor, { owner = 30, a = 6 })
		assert(not ok and failures[1].reason == "ACCOUNT_TOO_NEW", "account age floor")
		ok, failures = Settlement.leagueEligibility(state, day + floor, { owner = 30 })
		assert(not ok and failures[1].reason == "ACCOUNT_AGE_UNKNOWN", "missing age fails closed")
		local legacy = Settlement.save(state)
		legacy.joinedAt = nil
		ok, failures = Settlement.leagueEligibility(Settlement.fromSave(legacy, state.config, {}), day + floor, ages)
		assert(not ok and failures[1].reason == "MEMBERSHIP_UNKNOWN", "legacy saves are not eligible")
	end,
}
