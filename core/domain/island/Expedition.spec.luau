--!strict
-- Specs for Expedition: seed derivation, 24 h rotation with an injected clock,
-- expiry refusal, and DataStore budget sharding.

local Expedition = require("./Expedition")
local Rng = require("../random/Rng")
local serde = require("@lune/serde")

local DAY = 24 * 60 * 60
local card = { routeId = "route-forest-1", templateId = "exp-forest-low-a" }

local function encode(value: any): string
	return serde.encode("json", value)
end

return {
	["open builds the island document with a window-bounded expiry"] = function()
		local now = 3 * DAY + 100
		local island = Expedition.open(card, 77, now)
		assert(island.templateId == "exp-forest-low-a", "template")
		assert(next(island.delta) == nil, "empty delta")
		assert(island.expiresAt == 4 * DAY, "expires at window end")
		assert(island.seed == Expedition.seedFor(77, "route-forest-1", 3), "seed matches derivation")
		local expected = Rng.new(77):fork("expedition"):fork("route-forest-1|3"):nextU32()
		assert(island.seed == expected, "seed goes through Rng fork('expedition')")
	end,

	["seed is stable within a window and rotates across windows"] = function()
		local a = Expedition.open(card, 77, 5 * DAY)
		local b = Expedition.open(card, 77, 5 * DAY + DAY - 1)
		local c = Expedition.open(card, 77, 6 * DAY)
		assert(a.seed == b.seed, "same window, same seed")
		assert(a.seed ~= c.seed, "next window rotates the seed")
		local other = Expedition.open({ routeId = "route-marsh-1", templateId = "x" }, 77, 5 * DAY)
		assert(other.seed ~= a.seed, "route id feeds the seed")
		assert(Expedition.open(card, 78, 5 * DAY).seed ~= a.seed, "world seed feeds the seed")
	end,

	["expired route is refused"] = function()
		local island = Expedition.open(card, 1, 10 * DAY + 5)
		local ok, code = Expedition.canEnter(island, 11 * DAY - 1)
		assert(ok and code == nil, "still open one second before expiry")
		ok, code = Expedition.canEnter(island, 11 * DAY)
		assert(not ok and code == "route_expired", "refused at expiry")
		assert(Expedition.isExpired(island, 12 * DAY), "expired later too")
	end,

	["custom ttl and invalid inputs"] = function()
		local island = Expedition.open(card, 1, 7200, 3600)
		assert(island.expiresAt == 10800, "hourly window")
		assert(not (pcall(Expedition.open, card, 1, -1)), "negative now")
		assert(not (pcall(Expedition.open, { routeId = "", templateId = "t" }, 1, 0)), "empty route id")
		assert(not (pcall(Expedition.open, card, 1, 0, 0)), "zero ttl")
	end,

	["budget is 50 percent of the DataStore key limit"] = function()
		assert(Expedition.DATASTORE_KEY_LIMIT == 4194304, "key limit")
		assert(Expedition.DELTA_BUDGET == 2097152, "half the key limit")
	end,

	["small delta stays in one shard"] = function()
		local plan = Expedition.shardDelta({ z1 = { "a" }, z2 = { "b" } }, encode)
		assert(not plan.sharded and #plan.shards == 1, "one shard")
		assert(plan.shards[1].zones[1] == "z1" and plan.shards[1].zones[2] == "z2", "sorted zones")
	end,

	["over-budget delta is sharded by zone and every shard fits"] = function()
		local chunk = string.rep("x", 900000)
		local delta = { a = chunk, b = chunk, c = chunk, d = chunk, e = chunk }
		assert(#encode(delta) > Expedition.DELTA_BUDGET, "fixture must exceed the budget")
		local plan = Expedition.shardDelta(delta, encode)
		assert(plan.sharded, "must shard")
		assert(#plan.shards == 3, "expected 3 shards, got " .. #plan.shards)
		local seen = {}
		for _, shard in plan.shards do
			assert(shard.size <= Expedition.DELTA_BUDGET, "shard over budget")
			assert(#encode(shard.delta) == shard.size, "size is measured")
			for _, zone in shard.zones do
				assert(not seen[zone], "zone duplicated")
				seen[zone] = true
			end
		end
		for zone in delta do
			assert(seen[zone], "zone lost: " .. zone)
		end
	end,

	["a single zone over budget cannot be stored"] = function()
		local ok, err = pcall(Expedition.shardDelta, { big = string.rep("y", 200) }, encode, 100)
		assert(not ok and string.find(tostring(err), "zone over budget", 1, true), "single zone over budget")
	end,
}
