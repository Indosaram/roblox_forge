--!strict
-- Specs for lock: a matching lock passes; a version mismatch or a genre missing
-- from the lock fails.

local lock = require("./lock")

local EXPECTED: lock.Expected = {
	core = "1.0.0",
	coreFingerprint = "abc123",
	genres = { ["collect-raid"] = "1.0.0" },
	packGenres = { "collect-raid" },
}

return {
	["a matching lock passes"] = function()
		local parsed = lock.fromTable({
			core = "1.0.0",
			coreFingerprint = "abc123",
			genres = { ["collect-raid"] = "1.0.0" },
		})
		local errors = lock.validate(parsed, EXPECTED)
		assert(#errors == 0, "matching lock must report no errors, got: " .. table.concat(errors, "; "))
	end,

	["a version mismatch fails"] = function()
		local parsed = lock.fromTable({
			core = "1.0.0",
			coreFingerprint = "abc123",
			genres = { ["collect-raid"] = "0.9.0" },
		})
		local errors = lock.validate(parsed, EXPECTED)
		assert(#errors == 1, "one drifted genre must report one error")
		assert(string.find(errors[1], "collect-raid", 1, true) ~= nil, "error names the genre")
		assert(string.find(errors[1], "0.9.0", 1, true) ~= nil, "error names the locked version")
	end,

	["a core version mismatch fails"] = function()
		local parsed = lock.fromTable({
			core = "0.9.0",
			coreFingerprint = "abc123",
			genres = { ["collect-raid"] = "1.0.0" },
		})
		local errors = lock.validate(parsed, EXPECTED)
		assert(#errors == 1, "one drifted core must report one error")
		assert(string.find(errors[1], "core", 1, true) ~= nil, "error names core")
	end,

	["a genre missing from the lock fails"] = function()
		local parsed = lock.fromTable({ core = "1.0.0", coreFingerprint = "abc123", genres = {} })
		local errors = lock.validate(parsed, EXPECTED)
		assert(#errors == 1, "a genre listed in game.yml but absent from the lock must fail")
		assert(string.find(errors[1], "collect-raid", 1, true) ~= nil, "error names the genre")
	end,

	["a stale core fingerprint fails even when the version matches"] = function()
		local parsed = lock.fromTable({
			core = "1.0.0",
			coreFingerprint = "stale00",
			genres = { ["collect-raid"] = "1.0.0" },
		})
		local errors = lock.validate(parsed, EXPECTED)
		assert(#errors == 1, "drifted core content must report one error")
		assert(string.find(errors[1], "content changed", 1, true) ~= nil, "error explains the content drift")
		assert(string.find(errors[1], "abc123", 1, true) ~= nil, "error shows the current fingerprint")
	end,

	["a lock without a fingerprint fails so the pin cannot be trusted blindly"] = function()
		local parsed = lock.fromTable({ core = "1.0.0", genres = { ["collect-raid"] = "1.0.0" } })
		local errors = lock.validate(parsed, EXPECTED)
		assert(#errors == 1, "a missing fingerprint must fail")
		assert(string.find(errors[1], "coreFingerprint", 1, true) ~= nil, "error names the missing field")
	end,

	["the fingerprint follows module content, not the version string"] = function()
		local modules = { "core/a.luau", "core/b.luau" }
		local function hashOf(mapping: { [string]: string }): (string) -> string?
			return function(path)
				return mapping[path]
			end
		end
		local base = { ["core/a.luau"] = "h1", ["core/b.luau"] = "h2" }
		local same = lock.fingerprint("1.0.0", modules, hashOf(base))
		assert(lock.fingerprint("1.0.0", modules, hashOf(base)) == same, "fingerprint is deterministic")
		local changed = { ["core/a.luau"] = "h1", ["core/b.luau"] = "DIFFERENT" }
		assert(
			lock.fingerprint("1.0.0", modules, hashOf(changed)) ~= same,
			"content change must change the fingerprint"
		)
		local missing = { ["core/a.luau"] = "h1" }
		assert(
			lock.fingerprint("1.0.0", modules, hashOf(missing)) ~= same,
			"a missing module must change the fingerprint"
		)
	end,
}
