--!strict
-- Specs for Matchmaking: greedy oldest-first pairing bounded by a rating delta.

local Matchmaking = require("./Matchmaking")

return {
	["remove cancels only the waiting id and is idempotent"] = function()
		local q = Matchmaking.new()
		Matchmaking.enqueue(q, "a", 1000, 0)
		Matchmaking.enqueue(q, "b", 1000, 1)
		assert(Matchmaking.remove(q, "a"), "Matchmaking.spec.luau: invariant failed")
		assert(not Matchmaking.remove(q, "a"), "Matchmaking.spec.luau: invariant failed")
		assert(#Matchmaking.pair(q, 0) == 0 and q.entries[1].id == "b", "Matchmaking.spec.luau: invariant failed")
	end,
	["pair on an empty queue returns nothing"] = function()
		local q = Matchmaking.new()
		assert(#Matchmaking.pair(q, 100) == 0, "no pairs from empty queue")
	end,

	["pairing respects maxDelta"] = function()
		local q = Matchmaking.new()
		Matchmaking.enqueue(q, "a", 1000, 0)
		Matchmaking.enqueue(q, "b", 1100, 1)
		assert(#Matchmaking.pair(q, 50) == 0, "outside delta does not pair")
		assert(#q.entries == 2, "unmatched entries stay queued")

		local q2 = Matchmaking.new()
		Matchmaking.enqueue(q2, "a", 1000, 0)
		Matchmaking.enqueue(q2, "b", 1100, 1)
		local pairs = Matchmaking.pair(q2, 100)
		assert(#pairs == 1, "within delta pairs")
		assert(pairs[1][1] == "a" and pairs[1][2] == "b", "ids returned oldest first")
		assert(#q2.entries == 0, "paired entries removed")
	end,

	["pairing prefers the oldest compatible entry"] = function()
		local q = Matchmaking.new()
		Matchmaking.enqueue(q, "a", 1000, 0)
		Matchmaking.enqueue(q, "b", 1400, 1)
		Matchmaking.enqueue(q, "c", 1010, 2)
		local pairs = Matchmaking.pair(q, 50)
		assert(#pairs == 1, "one pair formed")
		assert(pairs[1][1] == "a" and pairs[1][2] == "c", "oldest pairs with oldest compatible")
		assert(#q.entries == 1, "one entry remains")
		assert(q.entries[1].id == "b", "incompatible entry remains")
	end,

	["pairing leaves entries with no compatible partner"] = function()
		local q = Matchmaking.new()
		Matchmaking.enqueue(q, "lonely", 1000, 0)
		assert(#Matchmaking.pair(q, 10) == 0, "no compatible partner")
		assert(#q.entries == 1, "entry stays queued")
	end,

	["a player queued twice is never paired with themselves"] = function()
		local q = Matchmaking.new()
		Matchmaking.enqueue(q, "alice", 1000, 0)
		Matchmaking.enqueue(q, "alice", 1000, 1)
		local pairs = Matchmaking.pair(q, 50)
		for _, entry in pairs do
			assert(entry[1] ~= entry[2], "a pair must not match an id with itself")
		end
	end,

	["re-enqueue refreshes rating without resetting wait or queue position"] = function()
		local q = Matchmaking.new()
		Matchmaking.enqueue(q, "a", 1400, 10)
		Matchmaking.enqueue(q, "b", 1000, 20)
		Matchmaking.enqueue(q, "c", 1000, 30)
		Matchmaking.enqueue(q, "a", 1000, 40)
		assert(#q.entries == 3, "one entry per id")
		assert(q.entries[1].id == "a" and q.entries[1].now == 10, "first wait and position preserved")
		assert(q.entries[1].rating == 1000, "latest rating replaces original")
		local pairs = Matchmaking.pair(q, 0)
		assert(#pairs == 1 and pairs[1][1] == "a" and pairs[1][2] == "b", "refresh affects pairing")
		assert(#q.entries == 1 and q.entries[1].id == "c", "later compatible player stays queued")
	end,

	["A B A C produces one match and keeps C waiting"] = function()
		local q = Matchmaking.new()
		for _, id in { "A", "B", "A", "C" } do
			Matchmaking.enqueue(q, id, 1000, 0)
		end
		local pairs = Matchmaking.pair(q, 0)
		local seen: { [Matchmaking.Id]: boolean } = {}
		for _, pair in pairs do
			for _, id in pair do
				assert(not seen[id], "an id appears only once across the entire batch")
				seen[id] = true
			end
		end
		assert(#pairs == 1 and pairs[1][1] == "A" and pairs[1][2] == "B", "oldest pair returned")
		assert(#q.entries == 1 and q.entries[1].id == "C", "C remains waiting")
		assert(#Matchmaking.pair(q, 0) == 0, "no duplicate A left for a subsequent batch")
	end,

	["repeated incompatible enqueue keeps one entry with latest rating"] = function()
		local q = Matchmaking.new()
		Matchmaking.enqueue(q, "a", 1000, 0)
		Matchmaking.enqueue(q, "b", 1000, 1)
		Matchmaking.enqueue(q, "a", 1200, 2)
		Matchmaking.enqueue(q, "a", 1400, 3)
		assert(#Matchmaking.pair(q, 100) == 0, "latest rating makes the player incompatible")
		assert(#q.entries == 2, "repeated refreshes do not add entries")
		assert(q.entries[1].rating == 1400 and q.entries[1].now == 0, "latest rating and first wait")
	end,

	["numeric and string ids remain distinct and matched players can requeue"] = function()
		local q = Matchmaking.new()
		Matchmaking.enqueue(q, 1, 1000, 0)
		Matchmaking.enqueue(q, "1", 1000, 1)
		Matchmaking.enqueue(q, 1, 1000, 2)
		local pairs = Matchmaking.pair(q, 0)
		assert(#pairs == 1 and pairs[1][1] == 1 and pairs[1][2] == "1", "typed ids are distinct")
		assert(#q.entries == 0, "both matched entries removed")
		Matchmaking.enqueue(q, 1, 1100, 3)
		Matchmaking.enqueue(q, "1", 1100, 4)
		assert(q.entries[1].now == 3 and q.entries[1].rating == 1100, "requeue starts a fresh wait")
		assert(#Matchmaking.pair(q, 0) == 1, "same players can match in a later batch")
	end,

	["invalid refresh inputs fail without mutating the waiting entry"] = function()
		local q = Matchmaking.new()
		Matchmaking.enqueue(q, "a", 1000, 0)
		assert(not pcall(Matchmaking.enqueue, q, "a", 0 / 0, 1), "NaN rating rejected")
		assert(not pcall(Matchmaking.enqueue, q, "a", 1200, 0 / 0), "NaN time rejected")
		assert(#q.entries == 1 and q.entries[1].rating == 1000 and q.entries[1].now == 0, "unchanged")
	end,
}
