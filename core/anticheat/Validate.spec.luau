--!strict
-- Specs for Validate: string, index, and finite-number guards.

local Validate = require("./Validate")

return {
	["isString accepts strings within the limit"] = function()
		assert(Validate.isString("abc", 3), "exact length")
		assert(Validate.isString("ab", 3), "shorter than limit")
		assert(Validate.isString("", 3), "empty string")
	end,

	["isString rejects over-long and non-string values"] = function()
		assert(Validate.isString("abcd", 3) == false, "over the limit")
		assert(Validate.isString(123, 3) == false, "number is not a string")
		assert(Validate.isString(nil, 3) == false, "nil is not a string")
		assert(Validate.isString({}, 3) == false, "table is not a string")
	end,

	["isIndex accepts integers inside the range"] = function()
		assert(Validate.isIndex(1, 1, 5), "lower bound")
		assert(Validate.isIndex(5, 1, 5), "upper bound")
		assert(Validate.isIndex(3, 1, 5), "interior")
	end,

	["isIndex rejects out-of-range and non-integer values"] = function()
		assert(Validate.isIndex(0, 1, 5) == false, "below range")
		assert(Validate.isIndex(6, 1, 5) == false, "above range")
		assert(Validate.isIndex(2.5, 1, 5) == false, "fractional")
		assert(Validate.isIndex("3", 1, 5) == false, "string")
		assert(Validate.isIndex(nil, 1, 5) == false, "nil")
		assert(Validate.isIndex(0 / 0, 1, 5) == false, "NaN")
		assert(Validate.isIndex(math.huge, 1, 5) == false, "infinity")
	end,

	["isFiniteNumber accepts finite numbers"] = function()
		assert(Validate.isFiniteNumber(0), "zero")
		assert(Validate.isFiniteNumber(-3.5), "negative fraction")
		assert(Validate.isFiniteNumber(1e9), "large finite")
	end,

	["isFiniteNumber rejects NaN, infinities, and non-numbers"] = function()
		assert(Validate.isFiniteNumber(0 / 0) == false, "NaN")
		assert(Validate.isFiniteNumber(math.huge) == false, "positive infinity")
		assert(Validate.isFiniteNumber(-math.huge) == false, "negative infinity")
		assert(Validate.isFiniteNumber("1") == false, "string")
		assert(Validate.isFiniteNumber(nil) == false, "nil")
	end,
}
