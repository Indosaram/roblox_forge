--!strict
-- Specs for lock: a matching lock passes; a version mismatch or a genre missing
-- from the lock fails.

local lock = require("./lock")

local EXPECTED: lock.Expected = {
	core = "1.0.0",
	genres = { ["collect-raid"] = "1.0.0" },
	packGenres = { "collect-raid" },
}

return {
	["a matching lock passes"] = function()
		local parsed = lock.fromTable({
			core = "1.0.0",
			genres = { ["collect-raid"] = "1.0.0" },
		})
		local errors = lock.validate(parsed, EXPECTED)
		assert(#errors == 0, "matching lock must report no errors, got: " .. table.concat(errors, "; "))
	end,

	["a version mismatch fails"] = function()
		local parsed = lock.fromTable({
			core = "1.0.0",
			genres = { ["collect-raid"] = "0.9.0" },
		})
		local errors = lock.validate(parsed, EXPECTED)
		assert(#errors == 1, "one drifted genre must report one error")
		assert(string.find(errors[1], "collect-raid", 1, true) ~= nil, "error names the genre")
		assert(string.find(errors[1], "0.9.0", 1, true) ~= nil, "error names the locked version")
	end,

	["a core version mismatch fails"] = function()
		local parsed = lock.fromTable({ core = "0.9.0", genres = { ["collect-raid"] = "1.0.0" } })
		local errors = lock.validate(parsed, EXPECTED)
		assert(#errors == 1, "one drifted core must report one error")
		assert(string.find(errors[1], "core", 1, true) ~= nil, "error names core")
	end,

	["a genre missing from the lock fails"] = function()
		local parsed = lock.fromTable({ core = "1.0.0", genres = {} })
		local errors = lock.validate(parsed, EXPECTED)
		assert(#errors == 1, "a genre listed in game.yml but absent from the lock must fail")
		assert(string.find(errors[1], "collect-raid", 1, true) ~= nil, "error names the genre")
	end,
}
