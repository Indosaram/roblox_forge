--!strict
-- Specs for IslandDirectory: publish/lookup over the injected MemoryStore fake,
-- TTL expiry and eviction against an injected clock, value-size refusal, and the
-- C25 budget gate (item size x active islands <= 50% of 64KB + 1.2KB x users).

local IslandDirectory = require("./IslandDirectory")
local serde = require("@lune/serde")

local function encode(value: any): string
	return serde.encode("json", value)
end

local function setup(): (IslandDirectory.Directory, IslandDirectory.MemoryMap, (number) -> ())
	local now = 0
	local map = IslandDirectory.memoryMap(function(): number
		return now
	end)
	local directory = IslandDirectory.new(map, { ttlSeconds = 60, encode = encode })
	return directory, map, function(seconds: number)
		now += seconds
	end
end

return {
	["publish then lookup returns access code and population"] = function()
		local directory = setup()
		assert(directory:publish({ islandId = "isl-1", accessCode = "code-a", population = 3 }))
		local record = assert(directory:lookup("isl-1"))
		assert(record.accessCode == "code-a" and record.population == 3, "record round-trips")
		local rows = assert(directory:list(10))
		assert(#rows == 1 and rows[1].islandId == "isl-1", "list sees the entry")
	end,

	["entries expire at ttl and vanish on eviction"] = function()
		local directory, map, advance = setup()
		assert(directory:publish({ islandId = "isl-1", accessCode = "a", population = 1 }))
		assert(directory:publish({ islandId = "isl-2", accessCode = "b", population = 1 }))
		advance(59)
		assert(directory:lookup("isl-1") ~= nil, "alive before ttl")
		map.evict("island:isl-2")
		assert(directory:lookup("isl-2") == nil, "evicted entry is gone")
		advance(1)
		assert(directory:lookup("isl-1") == nil, "expired at ttl")
		assert(#assert(directory:list(10)) == 0, "list skips expired entries")
	end,

	["invalid records and oversized values are refused"] = function()
		local directory = setup()
		local ok, err = directory:publish({ islandId = "bad id!", accessCode = "a", population = 0 })
		assert(not ok and err == "invalid island id", "id validated")
		ok, err = directory:publish({ islandId = "isl-1", accessCode = "a", population = -1 })
		assert(not ok and err == "invalid population", "population validated")
		ok, err = directory:publish({
			islandId = "isl-1",
			accessCode = string.rep("x", IslandDirectory.MAX_VALUE_BYTES),
			population = 0,
		})
		assert(not ok and err == "value too large", "32KB value limit enforced")
		assert(directory:lookup("isl-1") == nil, "refusal published nothing")
	end,

	["budget passes at the 50 percent boundary"] = function()
		-- 100 users: quota = 65536 + 122880 = 188416, limit = 94208.
		local result = IslandDirectory.assertBudget({ itemBytes = 94208 / 128, activeIslands = 128, users = 100 })
		assert(result.ok and result.limitBytes == 94208 and result.usedBytes == 94208, "boundary is inclusive")
	end,

	["budget over 50 percent fails the gate"] = function()
		local input = { itemBytes = 737, activeIslands = 128, users = 100 }
		local result = IslandDirectory.budget(input)
		assert(not result.ok and result.usedBytes > result.limitBytes, "over budget detected")
		local ok, err = pcall(IslandDirectory.assertBudget, input)
		assert(not ok and string.find(tostring(err), "MEMORYSTORE_BUDGET_EXCEEDED", 1, true), "gate errors")
	end,

	["real directory entries fit the budget for a launch-sized server fleet"] = function()
		local directory = setup()
		local itemBytes =
			directory:itemBytes({ islandId = string.rep("i", 40), accessCode = string.rep("c", 64), population = 50 })
		-- 1000 concurrent users spread over islands of ~10 players each.
		local result = IslandDirectory.budget({ itemBytes = itemBytes, activeIslands = 100, users = 1000 })
		assert(result.ok, "measured entry size x 100 islands within 50% budget, used " .. result.usedBytes)
	end,
}
