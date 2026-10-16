--!strict
local Camp = require("./Camp")
local Settlement = require("../../../core/domain/settlement/Settlement")

local DAY = 86400

local function ladder(): Camp.Ladder
	return Camp.ladder({
		{ id = "palisade", rung = 1, cost = { { item = "wood", quantity = 10 } } },
		{ id = "smokehouse", rung = 2, cost = { { item = "stone", quantity = 4 }, { item = "wood", quantity = 2 } } },
	}, {
		{ rung = 1, completions = 1, facility = "shared-storage" },
		{ rung = 2, completions = 2, facility = "camp-forge" },
	}, 2)
end

local function camp(): Settlement.State
	local state =
		Settlement.new({ tribeId = "camp", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 }, "owner", 0)
	for index, id in { "a", "b", "c" } do
		state = assert(Settlement.membership(state, "owner", index - 1, index - 1, "invite", id, 0))
	end
	return state
end

local function build(state: Camp.State, l: Camp.Ladder, s: Settlement.State, id: string): Camp.State
	local project = l.projects[id]
	for index, cost in project.cost do
		local actor = if index % 2 == 1 then "owner" else "a"
		local half = math.floor(cost.quantity / 2)
		state = assert(Camp.contribute(state, l, s, actor, state.version, id, { item = cost.item, quantity = half }))
		state = assert(
			Camp.contribute(state, l, s, "b", state.version, id, { item = cost.item, quantity = cost.quantity - half })
		)
	end
	return assert(Camp.complete(state, l, s, "c", state.version, id))
end

return {
	["camp is capped at four members by the settlement tribe"] = function()
		local s = camp()
		local full, err = Settlement.membership(s, "owner", 3, 3, "invite", "d", 0)
		assert(full == nil and err == "TRIBE_FULL", "fifth member refused")
	end,
	["joint builds climb the ladder and unlock shared facilities then league eligibility"] = function()
		local l, s = ladder(), camp()
		local state = Camp.new("camp")
		assert(Camp.rung(state, l) == 0 and next(state.facilities) == nil, "starts empty")
		local locked, lockedError =
			Camp.contribute(state, l, s, "owner", 0, "smokehouse", { item = "stone", quantity = 1 })
		assert(locked == nil and lockedError == "PROJECT_LOCKED", "rung 2 project locked at rung 0")
		state = build(state, l, s, "palisade")
		assert(Camp.rung(state, l) == 1 and state.facilities["shared-storage"], "first facility")
		assert(not state.facilities["camp-forge"], "second facility still locked")
		local ages = { owner = 30, a = 30, b = 30, c = 30 }
		local ok: boolean, reason: string?, failures: { Settlement.LeagueFailure }?
		ok, reason = Camp.leagueEligible(state, l, s, 30 * DAY, ages)
		assert(not ok and reason == "LADDER_RUNG_REQUIRED", "league needs the top rung")
		state = build(state, l, s, "smokehouse")
		assert(Camp.rung(state, l) == 2 and state.facilities["camp-forge"], "second facility")
		ok, reason = Camp.leagueEligible(state, l, s, 30 * DAY, ages)
		assert(ok and reason == nil, "eligible camp")
		ok, reason, failures = Camp.leagueEligible(state, l, s, DAY, ages)
		assert(not ok and (reason :: string?) == "MEMBER_FLOOR" and failures and #failures == 4, "membership too short")
	end,
	["solo deliveries outsiders and over delivery never count as a joint build"] = function()
		local l, s = ladder(), camp()
		local state = Camp.new("camp")
		local outsider, outsiderError =
			Camp.contribute(state, l, s, "stranger", 0, "palisade", { item = "wood", quantity = 1 })
		assert(outsider == nil and outsiderError == "FORBIDDEN", "non-member refused")
		local wrong, wrongError = Camp.contribute(state, l, s, "owner", 0, "palisade", { item = "stone", quantity = 1 })
		assert(wrong == nil and wrongError == "ITEM_NOT_NEEDED", "unneeded item refused")
		state = assert(Camp.contribute(state, l, s, "owner", 0, "palisade", { item = "wood", quantity = 10 }))
		local over, overError = Camp.contribute(state, l, s, "a", 1, "palisade", { item = "wood", quantity = 1 })
		assert(over == nil and overError == "OVER_DELIVERY", "over delivery refused")
		local stale, staleError = Camp.complete(state, l, s, "owner", 0, "palisade")
		assert(stale == nil and staleError == "STALE_VERSION", "stale version refused")
		local solo, soloError = Camp.complete(state, l, s, "owner", 1, "palisade")
		assert(solo == nil and soloError == "NOT_JOINT", "single contributor is not a joint build")
		assert(Camp.rung(state, l) == 0, "no progress")
	end,
	["restore re-derives facilities and rejects forged progress"] = function()
		local l, s = ladder(), camp()
		local state = build(Camp.new("camp"), l, s, "palisade")
		local restored = Camp.fromSave(Camp.save(state), l)
		assert(restored.facilities["shared-storage"] and Camp.rung(restored, l) == 1, "valid restore")
		local forged = Camp.save(state)
		forged.facilities["camp-forge"] = true
		assert(not Camp.fromSave(forged, l).facilities["camp-forge"], "forged facility dropped")
		local mutations: { (any) -> () } = {
			function(raw)
				raw.completed.unknown = 1
			end,
			function(raw)
				raw.completed.palisade = 0.5
			end,
			function(raw)
				raw.active.palisade = { delivered = { wood = 11 }, contributors = {} }
			end,
			function(raw)
				raw.saveVersion = 2
			end,
		}
		for _, mutate in mutations do
			local raw = Camp.save(state)
			mutate(raw)
			assert(not pcall(Camp.fromSave, raw, l), "forged save rejected")
		end
	end,
	["ladder definitions must be dense and increasing"] = function()
		assert(
			not pcall(
				Camp.ladder,
				{},
				{ { rung = 1, completions = 2, facility = "x" }, { rung = 2, completions = 2, facility = "y" } },
				1
			),
			"non-increasing"
		)
		assert(
			not pcall(Camp.ladder, {}, { { rung = 1, completions = 1, facility = "x" } }, 2),
			"league rung out of range"
		)
	end,
}
