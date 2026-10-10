--!strict
-- Specs for WeightedRoll: deterministic pick boundaries, odds, and validation.

local WeightedRoll = require("./WeightedRoll")

local function expectError(fn: () -> (), message: string): ()
	local ok = pcall(fn)
	assert(not ok, "expected error: " .. message)
end

return {
	["tiny middle intervals agree with odds at multiple representable interior rolls"] = function()
		for _, weights in { { 1, 1e-12, 1 }, { 3, 1e-12, 7 }, { 1e12, 1, 1e12 }, { 1e-12, 1e-24, 1e-12 } } do
			local entries = {
				{ id = "first", weight = weights[1] },
				{ id = "tiny", weight = weights[2] },
				{ id = "last", weight = weights[3] },
			}
			local total = weights[1] + weights[2] + weights[3]
			local lower = weights[1] / total
			local upper = (weights[1] + weights[2]) / total
			local odds = WeightedRoll.odds(entries)
			assert(odds.tiny == weights[2] / total and odds.tiny > 0, "positive disclosed share")
			for _, fraction in { 0.125, 0.25, 0.5, 0.75, 0.875 } do
				local roll = lower + (upper - lower) * fraction
				assert(roll > lower and roll < upper, "representable interior point")
				assert(WeightedRoll.pick(entries, roll) == "tiny", "interior roll must select disclosed tiny share")
			end
			assert(WeightedRoll.pick(entries, lower - odds.tiny) == "first", "preceding interior")
			assert(WeightedRoll.pick(entries, upper + odds.tiny) == "last", "following interior")
		end
		assert(
			WeightedRoll.pick(
				{ { id = "first", weight = 1 }, { id = "tiny", weight = 1e-12 }, { id = "last", weight = 1 } },
				0.5
			) == "tiny",
			"0.5 is the tiny middle midpoint"
		)
	end,
	["scaled decimal boundaries advance while interior rolls stay in their share"] = function()
		for _, scale in { 1e-12, 1, 1e12 } do
			local entries = {
				{ id = "a", weight = 0.1 * scale },
				{ id = "b", weight = 0.2 * scale },
				{ id = "c", weight = 0.7 * scale },
			}
			assert(WeightedRoll.pick(entries, 0.3) == "c", "scaled decimal boundary")
			assert(WeightedRoll.pick(entries, 0.3 - 1e-14) == "b", "scaled decimal interior")
		end
	end,
	["roll zero picks the first entry"] = function()
		local entries = {
			{ id = "a", weight = 1 },
			{ id = "b", weight = 1 },
			{ id = "c", weight = 1 },
		}
		assert(WeightedRoll.pick(entries, 0) == "a", "roll 0")
	end,

	["roll just under one picks the last entry"] = function()
		local entries = {
			{ id = "a", weight = 1 },
			{ id = "b", weight = 1 },
			{ id = "c", weight = 1 },
		}
		assert(WeightedRoll.pick(entries, 0.9999999) == "c", "roll near 1")
	end,

	["roll exactly on a cumulative boundary picks the next entry"] = function()
		local entries = {
			{ id = "a", weight = 1 },
			{ id = "b", weight = 1 },
			{ id = "c", weight = 1 },
			{ id = "d", weight = 1 },
		}
		assert(WeightedRoll.pick(entries, 0.25) == "b", "boundary 0.25")
		assert(WeightedRoll.pick(entries, 0.5) == "c", "boundary 0.5")
		assert(WeightedRoll.pick(entries, 0.75) == "d", "boundary 0.75")
	end,

	["a roll landing on a decimal boundary still picks the next entry despite float drift"] = function()
		local entries = {
			{ id = "a", weight = 0.1 },
			{ id = "b", weight = 0.2 },
			{ id = "c", weight = 0.7 },
		}
		assert(WeightedRoll.pick(entries, 0.3) == "c", "roll at the 0.1+0.2 boundary should pick the next entry")
	end,

	["weights bias selection"] = function()
		local entries = {
			{ id = "common", weight = 3 },
			{ id = "rare", weight = 1 },
		}
		assert(WeightedRoll.pick(entries, 0.74) == "common", "common region")
		assert(WeightedRoll.pick(entries, 0.75) == "rare", "boundary to rare")
		assert(WeightedRoll.pick(entries, 0.99) == "rare", "rare region")
	end,

	["odds reports probability per id and sums to one"] = function()
		local entries = {
			{ id = "a", weight = 1 },
			{ id = "b", weight = 2 },
			{ id = "c", weight = 1 },
		}
		local odds = WeightedRoll.odds(entries)
		assert(odds["a"] == 0.25, "a odds")
		assert(odds["b"] == 0.5, "b odds")
		assert(odds["c"] == 0.25, "c odds")
		local total = 0
		for _, probability in pairs(odds) do
			total += probability
		end
		assert(math.abs(total - 1) < 1e-12, "odds sum to 1, got " .. tostring(total))
	end,

	["pick rejects empty entries"] = function()
		expectError(function()
			WeightedRoll.pick({}, 0.5)
		end, "empty entries")
	end,

	["pick rejects non-positive and non-finite weights"] = function()
		expectError(function()
			WeightedRoll.pick({ { id = "a", weight = 0 } }, 0.5)
		end, "zero weight")
		expectError(function()
			WeightedRoll.pick({ { id = "a", weight = -1 } }, 0.5)
		end, "negative weight")
		expectError(function()
			WeightedRoll.pick({ { id = "a", weight = math.huge } }, 0.5)
		end, "infinite weight")
		expectError(function()
			WeightedRoll.pick({ { id = "a", weight = 0 / 0 } }, 0.5)
		end, "NaN weight")
	end,

	["pick rejects rolls outside zero inclusive to one exclusive"] = function()
		local entries = { { id = "a", weight = 1 } }
		expectError(function()
			WeightedRoll.pick(entries, -0.1)
		end, "negative roll")
		expectError(function()
			WeightedRoll.pick(entries, 1)
		end, "roll of one")
		expectError(function()
			WeightedRoll.pick(entries, 1.5)
		end, "roll above one")
		expectError(function()
			WeightedRoll.pick(entries, 0 / 0)
		end, "NaN roll")
	end,

	["odds rejects invalid entries"] = function()
		expectError(function()
			WeightedRoll.odds({})
		end, "empty entries")
		expectError(function()
			WeightedRoll.odds({ { id = "a", weight = 0 } })
		end, "zero weight")
	end,

	["a weight sum that overflows to infinity is rejected"] = function()
		local entries = {
			{ id = "a", weight = 1e308 },
			{ id = "b", weight = 1e308 },
		}
		expectError(function()
			WeightedRoll.odds(entries)
		end, "odds with an infinite total")
		expectError(function()
			WeightedRoll.pick(entries, 0.5)
		end, "pick with an infinite total")
	end,

	["a roll just below a boundary picks the entry before it, matching odds"] = function()
		-- 0.5 - 5e-10 is well inside a's [0, 0.5) share; pick must not shift the
		-- boundary by a fixed 1e-9 the way a total-independent epsilon would.
		local entries = { { id = "a", weight = 1 }, { id = "b", weight = 1 } }
		assert(WeightedRoll.pick(entries, 0.5 - 5e-10) == "a", "roll just under the boundary must stay with a")
	end,

	["an entry sharing far less than 1e-9 of total weight is still pickable"] = function()
		local entries = { { id = "rare", weight = 1e-10 }, { id = "common", weight = 1 } }
		assert(WeightedRoll.pick(entries, 5e-11) == "rare", "a roll inside rare's tiny share must pick rare")
	end,

	["an entry sharing 1e-13 of total weight is reachable at roll = 0, matching odds"] = function()
		-- Below the old fixed EPSILON (1e-12), this entry's cumulative boundary
		-- could never clear `cumulative / total - EPSILON > roll` even at roll =
		-- 0, so `pick` could never return it even though `odds` disclosed a
		-- non-zero share for it. The relative tolerance must not have this floor.
		local entries = { { id = "tiny", weight = 1e-13 }, { id = "big", weight = 1 } }
		local odds = WeightedRoll.odds(entries)
		assert(odds.tiny > 0, "odds must disclose a non-zero share for the tiny entry")
		assert(
			WeightedRoll.pick(entries, 0) == "tiny",
			"a roll of 0 must be able to pick the tiny entry, matching the share odds reports"
		)
	end,

	["boost returns a fresh table even when the multiplier is 1"] = function()
		local entries = { { id = "a", weight = 1 }, { id = "b", weight = 1 } }
		local boosted = WeightedRoll.boost(entries, 1)
		assert(boosted ~= entries, "boost must not return the caller's own table")
		boosted[1].weight = 999
		assert(entries[1].weight == 1, "mutating the result must not affect the caller's entries")
	end,

	["boost returns a fresh table even with a single entry"] = function()
		local entries = { { id = "a", weight = 1 } }
		local boosted = WeightedRoll.boost(entries, 3)
		assert(boosted ~= entries, "boost must not return the caller's own table for a single entry")
	end,

	["boost rejects a non-finite multiplier"] = function()
		local entries = { { id = "a", weight = 1 }, { id = "b", weight = 1 } }
		expectError(function()
			WeightedRoll.boost(entries, math.huge)
		end, "infinite luckMultiplier")
		expectError(function()
			WeightedRoll.boost(entries, 0 / 0)
		end, "NaN luckMultiplier")
		expectError(function()
			WeightedRoll.boost(entries, 0)
		end, "zero luckMultiplier")
		expectError(function()
			WeightedRoll.boost(entries, -2)
		end, "negative luckMultiplier")
	end,

	["boost scales every non-first entry by the multiplier and leaves the first entry at base rate"] = function()
		local entries = { { id = "common", weight = 1 }, { id = "rare", weight = 1 } }
		local boosted = WeightedRoll.boost(entries, 4)
		assert(boosted[1].weight == 1, "first entry keeps its base weight")
		assert(boosted[2].weight == 4, "non-first entry is scaled by the multiplier")
	end,
}
