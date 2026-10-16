--!strict
-- Specs for Allocation: QA-SPIKE-02 overfull rebalance, arrival placement,
-- queueing, determinism, and id-free player messages.

local Allocation = require("./Allocation")
local Topology = require("./Topology")

local function players(prefix: string, n: number): { string }
	local out = {}
	for i = 1, n do
		table.insert(out, prefix .. i)
	end
	return out
end

local function everyone(plan: Allocation.Plan): { [string]: number }
	local seen: { [string]: number } = {}
	for _, island in plan.islands do
		for _, p in island.players do
			seen[p] = (seen[p] or 0) + 1
		end
	end
	for _, q in plan.queue do
		seen[q.player] = (seen[q.player] or 0) + 1
	end
	return seen
end

local function assertNoneOverCap(plan: Allocation.Plan, cap: number)
	for _, island in plan.islands do
		assert(#island.players <= cap, island.id .. " over cap: " .. #island.players)
	end
end

local function fingerprint(plan: Allocation.Plan): string
	local parts = {}
	for _, m in plan.moves do
		table.insert(parts, "m:" .. m.player .. ">" .. m.to)
	end
	for _, a in plan.assignments do
		table.insert(parts, "a:" .. a.player .. ">" .. a.island)
	end
	for _, q in plan.queue do
		table.insert(parts, "q:" .. q.player .. "@" .. q.position)
	end
	return table.concat(parts, ",")
end

local function overfullSnapshot(): { Allocation.Island }
	return {
		{ id = "h1", kind = "harbor", players = players("a", 13) },
		{ id = "h2", kind = "harbor", players = players("b", 3) },
		{ id = "h3", kind = "harbor", players = players("c", 11) },
		{ id = "e1", kind = "expedition", players = players("d", 9) },
	}
end

return {
	["QA-SPIKE-02 overfull islands are rebalanced with no island over cap and zero players lost"] = function()
		local snapshot = overfullSnapshot()
		local before = 0
		for _, island in snapshot do
			before += #island.players
		end
		local plan = Allocation.allocate(snapshot, {}, 42)
		assertNoneOverCap(plan, 8)
		assert(Allocation.headcount(plan) == before, "headcount changed")
		local seen = everyone(plan)
		for _, island in snapshot do
			for _, p in island.players do
				assert(seen[p] == 1, p .. " lost or duplicated")
			end
		end
		-- 5 + 3 harbor excess and 1 expedition excess must move.
		assert(#plan.moves == 9, "expected 9 moves, got " .. #plan.moves)
		for _, m in plan.moves do
			assert(m.from ~= m.to, "self move")
		end
		-- harbor excess 8 fits in h2's 5 free seats + one new harbor instance.
		local newHarbor, newExpedition = 0, 0
		for _, island in plan.newInstances do
			if island.kind == "harbor" then
				newHarbor += 1
			else
				newExpedition += 1
			end
		end
		assert(newHarbor == 1 and newExpedition == 1, "new instances " .. newHarbor .. "/" .. newExpedition)
		-- moves never cross kinds.
		local kindOf = {}
		for _, island in plan.islands do
			kindOf[island.id] = island.kind
		end
		for _, m in plan.moves do
			assert(kindOf[m.from] == kindOf[m.to], "move crossed kinds")
		end
	end,

	["rebalance holds even when arrivals may not open instances"] = function()
		local plan = Allocation.allocate(overfullSnapshot(), {}, 7, { maxNewInstances = 0 })
		assertNoneOverCap(plan, 8)
		assert(Allocation.headcount(plan) == 36, "headcount")
	end,

	["rebalance respects a lowered per-kind capacity"] = function()
		local topology = Topology.new({ harbor = 4 })
		local plan = Allocation.allocate({
			{ id = "h1", kind = "harbor", players = players("a", 8) },
		}, {}, 1, { topology = topology })
		assertNoneOverCap(plan, 4)
		assert(#plan.moves == 4 and #plan.newInstances == 1, "moved 4 to one new instance")
	end,

	["arrivals fill the fullest island under the cap before opening new ones"] = function()
		local plan = Allocation.allocate({
			{ id = "h1", kind = "harbor", players = players("a", 6) },
			{ id = "h2", kind = "harbor", players = players("b", 2) },
		}, {
			{ player = "x1", kind = "harbor" },
			{ player = "x2", kind = "harbor" },
			{ player = "x3", kind = "harbor" },
		}, 3)
		assert(plan.assignments[1].island == "h1", "first arrival packs h1")
		assert(plan.assignments[2].island == "h1", "second arrival packs h1")
		assert(plan.assignments[3].island == "h2", "h1 full, then h2")
		assert(#plan.newInstances == 0, "no new instance needed")
		assert(#plan.queue == 0, "no queue")
	end,

	["arrivals beyond the instance budget queue in order with positions"] = function()
		local arrivals = {}
		for i = 1, 10 do
			table.insert(arrivals, { player = "x" .. i, kind = "expedition" })
		end
		local plan = Allocation.allocate({
			{ id = "e1", kind = "expedition", players = players("d", 7) },
		}, arrivals, 9, { maxNewInstances = 0 })
		assert(#plan.assignments == 1, "one free seat")
		assert(#plan.queue == 9, "rest queued")
		for i, q in plan.queue do
			assert(q.position == i and q.player == "x" .. (i + 1), "queue order")
		end
		assertNoneOverCap(plan, 8)
		assert(Allocation.headcount(plan) == 17, "no one lost")
	end,

	["same inputs and seed give the same plan; different seed may differ"] = function()
		local a = fingerprint(Allocation.allocate(overfullSnapshot(), {}, 42))
		local b = fingerprint(Allocation.allocate(overfullSnapshot(), {}, 42))
		assert(a == b, "non-deterministic plan")
		local differs = false
		for seed = 1, 20 do
			if fingerprint(Allocation.allocate(overfullSnapshot(), {}, seed)) ~= a then
				differs = true
				break
			end
		end
		assert(differs, "seed has no effect on tie-breaking")
	end,

	["allocate rejects inconsistent input"] = function()
		assert(not (pcall(Allocation.allocate, {
			{ id = "h1", kind = "harbor", players = { "p" } },
			{ id = "h2", kind = "harbor", players = { "p" } },
		}, {}, 1)), "player on two islands")
		assert(not (pcall(Allocation.allocate, {
			{ id = "h1", kind = "lobby", players = {} },
		}, {}, 1)), "unknown kind")
		assert(not (pcall(Allocation.allocate, {
			{ id = "h1", kind = "harbor", players = { "p" } },
		}, { { player = "p", kind = "harbor" } }, 1)), "arrival already placed")
		assert(not (pcall(Allocation.allocate, {}, {}, 1, { maxNewInstances = -1 })), "negative budget")
	end,

	["queue positions are approximated, never a fixed number"] = function()
		assert(Allocation.approximatePosition(3) == 3, "small exact")
		assert(Allocation.approximatePosition(12) == 15, "bucket of 5")
		assert(Allocation.approximatePosition(51) == 60, "bucket of 10")
		local a = Allocation.playerMessage("queued", 12, 4)
		local b = Allocation.playerMessage("queued", 120, 4)
		assert(a.params.approxPosition ~= b.params.approxPosition, "position must track measurement")
		assert(a.params.approxMinutes == 3, "minutes from measured rate")
		assert(not (pcall(Allocation.approximatePosition, 0)), "position zero")
	end,

	["player messages carry only localization keys and numbers"] = function()
		local plan = Allocation.allocate(overfullSnapshot(), { { player = "x1", kind = "harbor" } }, 5)
		local ids = {}
		for _, island in plan.islands do
			table.insert(ids, island.id)
		end
		for _, code in { "queued", "assigned", "moved", "full", "internal", "SELECT * FROM islands; deadlock" } do
			local message = Allocation.playerMessage(code, 4, 2)
			assert(string.match(message.key, "^island%.[%w_%.]+$"), "key shape: " .. message.key)
			for name, value in message.params do
				assert(type(value) == "number", name .. " must be numeric")
			end
			for _, id in ids do
				assert(not string.find(message.key, id, 1, true), "island id leaked: " .. id)
			end
		end
		local unknown = Allocation.playerMessage("SELECT * FROM islands; deadlock")
		assert(unknown.key == "island.error.generic", "unknown codes collapse to generic")
	end,
}
