--!strict
-- Specs for Rng: golden vector, state round-trip, range bounds, fork, validation.

local Rng = require("./Rng")

local function expectError(fn: () -> (), message: string): ()
	local ok = pcall(fn)
	assert(not ok, "expected error: " .. message)
end

return {
	["seed 42 produces the golden first five nextU32 values"] = function()
		local rng = Rng.new(42)
		local expected = { 3121063093, 160939822, 3445466822, 344117834, 2468871779 }
		for i, value in expected do
			local got = rng:nextU32()
			assert(got == value, `draw {i}: expected {value}, got {got}`)
		end
	end,
	["same seed repeats and different seeds diverge"] = function()
		local a, b, c = Rng.new(7), Rng.new(7), Rng.new(8)
		local differs = false
		for _ = 1, 20 do
			local x = a:nextU32()
			assert(x == b:nextU32(), "same seed must repeat")
			if x ~= c:nextU32() then
				differs = true
			end
		end
		assert(differs, "different seeds must diverge")
		assert(Rng.new(0):nextU32() ~= Rng.new(2 ^ 32):nextU32(), "seeds differing above 2^32 diverge")
		Rng.new(2 ^ 53 - 1):nextU32()
	end,
	["state round-trip continues identically"] = function()
		local rng = Rng.new(99)
		for _ = 1, 13 do
			rng:nextU32()
		end
		local snapshot = rng:state()
		assert(#snapshot == 4, "state has four words")
		local restored = Rng.fromState(snapshot)
		for i = 1, 50 do
			assert(rng:nextU32() == restored:nextU32(), `draw {i} after restore`)
		end
		snapshot[1] = 0 -- mutating the snapshot must not touch the live stream
		local again = Rng.fromState(rng:state())
		assert(again:nextU32() == rng:nextU32(), "state() returns a copy")
	end,
	["nextNumber stays in [0, 1) over 10000 draws"] = function()
		local rng = Rng.new(2024)
		for i = 1, 10000 do
			local v = rng:nextNumber()
			assert(v >= 0 and v < 1, `draw {i} out of range: {v}`)
		end
	end,
	["nextInteger is inclusive and covers the whole range"] = function()
		local rng = Rng.new(5)
		local seen: { [number]: boolean } = {}
		for _ = 1, 2000 do
			local v = rng:nextInteger(-3, 3)
			assert(v >= -3 and v <= 3 and v == math.floor(v), "in range integer")
			seen[v] = true
		end
		for v = -3, 3 do
			assert(seen[v], `value {v} never drawn`)
		end
		assert(rng:nextInteger(4, 4) == 4, "degenerate range")
		local wide = rng:nextInteger(0, 2 ^ 40)
		assert(wide >= 0 and wide <= 2 ^ 40, "wide range")
		expectError(function()
			rng:nextInteger(5, 4)
		end, "min > max")
		expectError(function()
			rng:nextInteger(0.5, 2)
		end, "non-integer bound")
	end,
	["fork streams differ from the parent and from each other, deterministically"] = function()
		local parent = Rng.new(11)
		local a, b = parent:fork("loot"), parent:fork("map")
		local a2 = Rng.new(11):fork("loot")
		local sameAsParent, sameAB = true, true
		local parentCopy = Rng.fromState(parent:state())
		for _ = 1, 20 do
			local x = a:nextU32()
			assert(x == a2:nextU32(), "fork is deterministic")
			if x ~= parentCopy:nextU32() then
				sameAsParent = false
			end
			if x ~= b:nextU32() then
				sameAB = false
			end
		end
		assert(not sameAsParent, "fork differs from parent")
		assert(not sameAB, "different labels differ")
		local before = parent:state()
		parent:fork("x")
		local after = parent:state()
		for i = 1, 4 do
			assert(before[i] == after[i], "fork does not advance the parent")
		end
	end,
	["invalid seeds and states raise"] = function()
		expectError(function()
			Rng.new(-1)
		end, "negative seed")
		expectError(function()
			Rng.new(0.5)
		end, "fractional seed")
		expectError(function()
			Rng.new(2 ^ 53)
		end, "unsafe seed")
		expectError(function()
			Rng.new(0 / 0)
		end, "nan seed")
		expectError(function()
			Rng.new(math.huge)
		end, "infinite seed")
		expectError(function()
			Rng.new("1" :: any)
		end, "string seed")
		expectError(function()
			Rng.fromState({ 0, 0, 0, 0 })
		end, "all-zero state")
		expectError(function()
			Rng.fromState({ 1, 2, 3 })
		end, "short state")
		expectError(function()
			Rng.fromState({ 1, 2, 3, 2 ^ 32 })
		end, "word out of u32")
	end,
}
