--!strict
local Journal = require("./Journal")

local function sample(): Journal.Journal
	local journal = Journal.new({ seed = 42, genre = "collect-raid", scenario = "smoke" })
	journal:record({ kind = "join", actor = "p1", atMillis = 0 })
	journal:record({
		kind = "command",
		actor = "p1",
		action = "hatch",
		args = { "egg", 3, true, { tier = "rare", weights = { 1, 2.5 } } },
		requestId = "r-1",
		atMillis = 125,
	})
	journal:record({ kind = "advance", atMillis = 1000 })
	journal:record({ kind = "save", atMillis = 1500 })
	journal:record({ kind = "reload", atMillis = 1600 })
	journal:record({ kind = "leave", actor = "p1", atMillis = 2000 })
	journal:finish(Journal.hash({ coins = 10 }))
	return journal
end

local function rejects(fn: () -> (), pattern: string): ()
	local ok, err = pcall(fn)
	assert(not ok, "expected rejection matching " .. pattern)
	assert(string.find(tostring(err), pattern, 1, true), "unexpected error: " .. tostring(err))
end

return {
	["fnv1a64 matches the reference vectors"] = function()
		assert(Journal.fnv1a64("") == "cbf29ce484222325", Journal.fnv1a64(""))
		assert(Journal.fnv1a64("a") == "af63dc4c8601ec8c", Journal.fnv1a64("a"))
		assert(Journal.fnv1a64("foobar") == "85944171f73967e8", Journal.fnv1a64("foobar"))
	end,
	["encode and decode round trip is equal"] = function()
		local journal = sample()
		local text = Journal.encode(journal)
		local decoded = Journal.decode(text)
		assert(Journal.encode(decoded) == text, "re-encoding is byte identical")
		assert(decoded.meta.seed == 42 and decoded.meta.genre == "collect-raid", "meta preserved")
		assert(#decoded.entries == 6, "all entries preserved")
		assert(decoded.entries[2].args ~= nil and (decoded.entries[2].args :: any)[4].weights[2] == 2.5, "args")
		assert(decoded.stateHash == journal.stateHash, "state hash preserved")
		assert(string.find(text, '"schemaVersion":1', 1, true), "versioned")
	end,
	["unfinished journal with control characters round trips"] = function()
		local journal = Journal.new({ seed = -7 })
		journal:record({ kind = "command", action = 'quote"back\\slash\nline', args = {}, atMillis = 1 })
		local text = Journal.encode(journal)
		local decoded = Journal.decode(text)
		assert(decoded.stateHash == nil, "unfinished")
		assert(decoded.entries[1].action == 'quote"back\\slash\nline', "escapes preserved")
		assert(Journal.encode(decoded) == text, "stable")
	end,
	["hash is stable for key order permutations"] = function()
		local a: { [string]: any } = {}
		a.alpha = 1
		a.beta = { x = "y", z = { 1, 2 } }
		a.gamma = true
		local b: { [string]: any } = {}
		b.gamma = true
		b.beta = { z = { 1, 2 }, x = "y" }
		b.alpha = 1
		assert(Journal.hash(a) == Journal.hash(b), "permutation invariant")
		assert(#Journal.hash(a) == 16 and string.match(Journal.hash(a), "^%x+$"), "16 hex digits")
	end,
	["hash changes when a leaf changes"] = function()
		local base = { alpha = 1, beta = { x = "y", z = { 1, 2 } } }
		local changed = { alpha = 1, beta = { x = "y", z = { 1, 3 } } }
		local retyped = { alpha = "1", beta = { x = "y", z = { 1, 2 } } }
		assert(Journal.hash(base) ~= Journal.hash(changed), "leaf value change")
		assert(Journal.hash(base) ~= Journal.hash(retyped), "leaf type change")
	end,
	["invalid entries are rejected"] = function()
		local journal = Journal.new({ seed = 1 })
		local any = journal :: any
		rejects(function()
			any:record({ kind = "teleport", atMillis = 0 })
		end, "invalid entry kind")
		rejects(function()
			any:record({ kind = "command", atMillis = -1 })
		end, "atMillis")
		rejects(function()
			any:record({ kind = "command", atMillis = 0.5 })
		end, "atMillis")
		rejects(function()
			any:record({ kind = "command", atMillis = 0, extra = 1 })
		end, "unknown entry field")
		rejects(function()
			any:record({ kind = "command", atMillis = 0, args = { math.huge } })
		end, "args")
		rejects(function()
			any:record({ kind = "command", atMillis = 0, args = { key = "value" } })
		end, "args")
		rejects(function()
			any:record({ kind = "command", atMillis = 0, args = { function() end } })
		end, "args")
		rejects(function()
			any:record({ kind = "command", atMillis = 0, actor = 5 })
		end, "short strings")
		rejects(function()
			Journal.new({ seed = 0 / 0 } :: any)
		end, "meta.seed")
		assert(#journal.entries == 0, "nothing recorded")
		journal:finish("abc")
		rejects(function()
			journal:record({ kind = "advance", atMillis = 1 })
		end, "after finish")
		rejects(function()
			journal:finish("def")
		end, "already finished")
	end,
	["recorded entries are isolated from caller mutation"] = function()
		local journal = Journal.new({ seed = 1 })
		local args = { 1, 2 }
		journal:record({ kind = "command", args = args, atMillis = 0 })
		args[1] = 99
		assert((journal.entries[1].args :: any)[1] == 1, "cloned")
	end,
	["decode of tampered text errors"] = function()
		local text = Journal.encode(sample())
		local tampered = string.gsub(text, '"action":"hatch"', '"action":"steal"')
		assert(tampered ~= text, "tamper applied")
		rejects(function()
			Journal.decode(tampered)
		end, "hash mismatch")
		local hashSwapped = string.gsub(text, '"hash":"%x+"', '"hash":"0000000000000000"')
		assert(hashSwapped ~= text, "hash swap applied")
		rejects(function()
			Journal.decode(hashSwapped)
		end, "hash mismatch")
		rejects(function()
			Journal.decode((string.gsub(text, '"schemaVersion":1', '"schemaVersion":2')))
		end, "schemaVersion")
		rejects(function()
			Journal.decode(text .. "x")
		end, "trailing text")
		rejects(function()
			Journal.decode("{")
		end, "decode")
	end,
}
