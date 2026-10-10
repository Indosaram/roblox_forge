--!strict
-- Specs for Merge: planning merges by rarity, consuming lowest indices, and applying results.

local Merge = require("./Merge")

local RARITIES: { [string]: string } = {
	k1 = "common",
	k2 = "rare",
	k3 = "common",
	k4 = "common",
	k5 = "common",
}

local function rarityOf(id: string): string?
	return RARITIES[id]
end

local function expectIndices(indices: { number }?, expected: { number }, label: string): ()
	assert(indices ~= nil, label .. ": expected indices")
	local actual = indices :: { number }
	assert(#actual == #expected, label .. ": expected " .. #expected .. " indices, got " .. #actual)
	for position, expectedIndex in expected do
		assert(actual[position] == expectedIndex, label .. ": index " .. position)
	end
end

return {
	["exact count merges with lowest indices first"] = function()
		local owned = { "k1", "k2", "k3", "k4" }
		local ok, indices, err = Merge.plan(owned, rarityOf, {
			from = "common",
			to = "rare",
			count = 3,
			resultId = "merged-1",
		})
		assert(ok == true, "plan should succeed")
		assert(err == nil, "no error reason")
		expectIndices(indices, { 1, 3, 4 }, "exact count")
	end,

	["fewer matching entries than count returns not enough"] = function()
		local owned = { "k1", "k2", "k3" }
		local ok, indices, err = Merge.plan(owned, rarityOf, {
			from = "common",
			to = "rare",
			count = 3,
			resultId = "merged-1",
		})
		assert(ok == false, "plan should fail")
		assert(indices == nil, "no indices")
		assert(err == "not enough", "expected 'not enough', got " .. tostring(err))
	end,

	["zero, negative, and fractional count returns invalid rule"] = function()
		local owned = { "k1", "k3", "k4" }
		for _, count in { 0, -2, 1.5 } do
			local ok, indices, err = Merge.plan(owned, rarityOf, {
				from = "common",
				to = "rare",
				count = count,
				resultId = "merged-1",
			})
			assert(ok == false, "count " .. tostring(count) .. " should fail")
			assert(indices == nil, "count " .. tostring(count) .. ": no indices")
			assert(
				err == "invalid rule",
				"count " .. tostring(count) .. ": expected 'invalid rule', got " .. tostring(err)
			)
		end
	end,

	["apply removes exactly the chosen indices without mutating input"] = function()
		local owned = { "k1", "k2", "k3", "k4" }
		local snapshot = { "k1", "k2", "k3", "k4" }
		local result = Merge.apply(owned, { 2, 4 }, "merged-1")
		assert(#result == 3, "result length")
		assert(result[1] == "k1", "kept index 1")
		assert(result[2] == "k3", "kept index 3")
		assert(result[3] == "merged-1", "resultId appended last")
		assert(#owned == #snapshot, "input length unchanged")
		for position, id in snapshot do
			assert(owned[position] == id, "input entry " .. position .. " unchanged")
		end
		assert(result ~= owned, "result is a new list")
	end,

	["entries of other rarities are never consumed"] = function()
		local owned = { "k1", "k2", "k3", "k4", "k5" }
		local ok, indices, err = Merge.plan(owned, rarityOf, {
			from = "common",
			to = "rare",
			count = 4,
			resultId = "merged-1",
		})
		assert(ok == true, "plan should succeed")
		assert(err == nil, "no error reason")
		expectIndices(indices, { 1, 3, 4, 5 }, "other rarities skipped")

		local consumed: { [number]: boolean } = {}
		for _, index in indices :: { number } do
			consumed[index] = true
		end
		for position, id in owned do
			if RARITIES[id] ~= "common" then
				assert(consumed[position] ~= true, "non-common entry " .. position .. " consumed")
			end
		end
	end,
}
